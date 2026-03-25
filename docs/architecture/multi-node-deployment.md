# Multi-Node HA Deployment

Production-tested 3-node HA deployment with Ceph storage and WireGuard mesh networking.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Global Load Balancer                     │
│              (Cloudflare / AWS Route 53 / HAProxy)          │
└──────────────────────┬──────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
┌───────▼──────┐ ┌────▼──────┐ ┌──────▼──────┐
│    Node 1    │ │   Node 2  │ │    Node 3   │
│  10.200.0.1  │ │ 10.200.0.2│ │  10.200.0.3 │
├──────────────┤ ├───────────┤ ├─────────────┤
│ ┌──────────┐ │ │ ┌────────┐│ │ ┌──────────┐│
│ │ Podman   │ │ │ │Podman  ││ │ │ Podman   ││
│ │Web App   │ │ │ │Web App ││ │ │ Web App  ││
│ └────┬─────┘ │ │ └────┬───┘│ │ └────┬─────┘│
│      │       │ │      │    │ │      │      │
│ ┌────▼─────┐ │ │ ┌────▼──┐ │ │ ┌────▼────┐ │
│ │ Ceph OSD │ │ │ │CephOSD│ │ │ │Ceph OSD │ │
│ │  (100GB) │ │ │ │(100GB)│ │ │ │ (100GB) │ │
│ └──────────┘ │ │ └───────┘ │ │ └─────────┘ │
└──────────────┘ └───────────┘ └─────────────┘
       │                │              │
       └────────────────┼──────────────┘
                        │
               ┌────────▼────────┐
               │   Ceph MON      │
               │  (Distributed)  │
               └─────────────────┘
```

## Prerequisites

### Hardware Requirements (Per Node)

| Component | Minimum | Recommended | Purpose |
|-----------|---------|-------------|---------|
| CPU | 4 cores | 8+ cores | Containers + Ceph OSD |
| RAM | 8 GB | 16+ GB | Podman + Ceph cache |
| Disk (OS) | 50 GB SSD | 100 GB NVMe | Operating system |
| Disk (Ceph) | 100 GB | 500 GB+ SSD | Ceph OSD storage |
| Network | 1 Gbps | 10 Gbps | Inter-node + storage |

### Network Requirements

- **Public IPs**: 3 (one per node) for ingress
- **Private Network**: 10.200.0.0/24 for WireGuard mesh
- **Ceph Cluster Network**: 10.201.0.0/24 (optional, for replication)
- **Firewall Rules**:
  - TCP 22 (SSH)
  - TCP 80, 443 (HTTP/HTTPS)
  - TCP 51820 (WireGuard)
  - TCP 6789 (Ceph MON)
  - TCP 6800-7300 (Ceph OSD/MGR)

## Step 1: WireGuard Mesh Network

### On Each Node

```bash
# Install WireGuard
sudo pacman -S wireguard-tools

# Generate keypair
wg genkey | sudo tee /etc/wireguard/privatekey | wg pubkey | sudo tee /etc/wireguard/publickey

# Create WireGuard configuration
sudo tee /etc/wireguard/wg0.conf << 'EOF'
[Interface]
PrivateKey = <NODE_PRIVATE_KEY>
Address = 10.200.0.X/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# Node 2 Peer
[Peer]
PublicKey = <NODE2_PUBLIC_KEY>
AllowedIPs = 10.200.0.2/32
Endpoint = node2.example.com:51820
PersistentKeepalive = 25

# Node 3 Peer
[Peer]
PublicKey = <NODE3_PUBLIC_KEY>
AllowedIPs = 10.200.0.3/32
Endpoint = node3.example.com:51820
PersistentKeepalive = 25
EOF

# Replace placeholders
sudo sed -i "s|<NODE_PRIVATE_KEY>|$(sudo cat /etc/wireguard/privatekey)|g" /etc/wireguard/wg0.conf
sudo sed -i "s|10.200.0.X|10.200.0.1|g" /etc/wireguard/wg0.conf  # Change X per node

# Enable and start
sudo systemctl enable --now wg-quick@wg0

# Verify connectivity
ping -c 3 10.200.0.2
ping -c 3 10.200.0.3
```

### WireGuard Configuration Matrix

| Node | Private IP | Endpoint |
|------|------------|----------|
| Node 1 | 10.200.0.1 | node1.example.com:51820 |
| Node 2 | 10.200.0.2 | node2.example.com:51820 |
| Node 3 | 10.200.0.3 | node3.example.com:51820 |

## Step 2: Ceph Cluster Deployment

### Option A: Cephadm (Recommended)

```bash
# On Node 1 (Bootstrap node)

# Install Cephadm
sudo pacman -S ceph cephadm

# Bootstrap cluster
sudo cephadm bootstrap \
    --mon-ip 10.200.0.1 \
    --initial-dashboard-user admin \
    --initial-dashboard-password $(openssl rand -base64 12) \
    --allow-fqdn-hostname \
    --cluster-network 10.201.0.0/24

# Copy SSH key to other nodes
ssh-copy-id root@node2
ssh-copy-id root@node3

# Add hosts to cluster
sudo ceph orch host add node1 10.200.0.1
sudo ceph orch host add node2 10.200.0.2
sudo ceph orch host add node3 10.200.0.3

# Label nodes
sudo ceph orch host label add node1 mon
sudo ceph orch host label add node1 mgr
sudo ceph orch host label add node1 osd
sudo ceph orch host label add node2 mon
sudo ceph orch host label add node2 osd
sudo ceph orch host label add node3 mon
sudo ceph orch host label add node3 osd

# Deploy MONs (3 for quorum)
sudo ceph orch apply mon 3

# Deploy MGRs
sudo ceph orch apply mgr 2

# Deploy OSDs (one per node)
sudo ceph orch daemon add osd node1:/dev/sdb  # Dedicated disk
sudo ceph orch daemon add osd node2:/dev/sdb
sudo ceph orch daemon add osd node3:/dev/sdb

# Or use directory (if no dedicated disk)
sudo mkdir -p /var/lib/ceph/osd
sudo ceph orch daemon add osd node1:/var/lib/ceph/osd

# Create CephFS for containers
sudo ceph fs volume create container-storage

# Verify cluster health
sudo ceph -s
sudo ceph health detail
```

### Option B: Manual Ceph Deployment

```bash
# On all nodes
sudo pacman -S ceph

# Create Ceph configuration directory
sudo mkdir -p /etc/ceph

# Generate FSID
FSID=$(uuidgen)
echo $FSID | sudo tee /etc/ceph/fsid

# Create ceph.conf
sudo tee /etc/ceph/ceph.conf << EOF
[global]
fsid = $FSID
mon_host = 10.200.0.1,10.200.0.2,10.200.0.3
public_network = 10.200.0.0/24
cluster_network = 10.201.0.0/24
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
osd_pool_default_size = 3
osd_pool_default_min_size = 2
mon_allow_pool_delete = true
EOF

# Deploy MONs (run on each node)
sudo ceph-mon --cluster ceph --id $(hostname) --mkfs
sudo systemctl enable --now ceph-mon@$(hostname)

# Deploy OSDs
# Wipe disk first
sudo ceph-volume lvm zap /dev/sdb --destroy

# Create OSD
sudo ceph-volume lvm create --data /dev/sdb
sudo systemctl enable --now ceph-osd@0  # ID from output

# Create MDS for CephFS
sudo ceph-mds --cluster ceph --id $(hostname) --mkfs
sudo systemctl enable --now ceph-mds@$(hostname)

# Create CephFS
sudo ceph osd pool create cephfs_data 128
sudo ceph osd pool create cephfs_metadata 64
sudo ceph fs new container-storage cephfs_metadata cephfs_data
```

### Ceph Cluster Validation

```bash
# Check cluster status
sudo ceph -s
# Expected: HEALTH_OK, 3 OSDs up

# Check OSD tree
sudo ceph osd tree
# Expected: 3 OSDs, each on different host

# Check CephFS
sudo ceph fs ls
sudo ceph mds stat

# Test CephFS mount
sudo mkdir -p /mnt/cephfs
sudo mount -t ceph \
    10.200.0.1:6789,10.200.0.2:6789,10.200.0.3:6789:/ \
    /mnt/cephfs \
    -o name=admin,secret=$(sudo ceph auth get-key client.admin)

# Test write
echo "test" | sudo tee /mnt/cephfs/test.txt
sudo cat /mnt/cephfs/test.txt
```

## Step 3: Podman Configuration for Ceph

```bash
# On all nodes

# Install Ceph client
sudo pacman -S ceph ceph-common

# Copy Ceph config and keyring
sudo cp /etc/ceph/ceph.conf /etc/ceph/ceph.client.admin.keyring \
    /var/lib/containers/storage/ceph-config/

# Create mount helper script
sudo tee /usr/local/bin/mount-cephfs.sh << 'EOF'
#!/bin/bash
# Mount CephFS for container storage

MONITOR_IPS="10.200.0.1:6789,10.200.0.2:6789,10.200.0.3:6789"
CEPHFS_NAME="container-storage"
MOUNT_POINT="/var/lib/containers/storage/volumes-shared"
KEYRING="/etc/ceph/ceph.client.admin.keyring"

# Create mount point
mkdir -p "$MOUNT_POINT"

# Mount with HA failover
mount -t ceph "$MONITOR_IPS:/$CEPHFS_NAME" "$MOUNT_POINT" \
    -o name=admin,secretfile=/etc/ceph/admin.secret,\
mount_timeout=10,\
retry=3
EOF
sudo chmod +x /usr/local/bin/mount-cephfs.sh

# Add to fstab for auto-mount
echo "10.200.0.1:6789,10.200.0.2:6789,10.200.0.3:6789:/container-storage /var/lib/containers/storage/volumes-shared ceph name=admin,secretfile=/etc/ceph/admin.secret,_netdev,noatime 0 2" | \
    sudo tee -a /etc/fstab

# Mount
sudo systemctl daemon-reload
sudo mount -a
```

## Step 4: Podman Pod Network Across Nodes

```bash
# Create overlay network using CNI plugins

# Install CNI plugins
sudo pacman -S cni-plugins

# Create CNI configuration for cross-node networking
sudo mkdir -p /etc/cni/net.d
sudo tee /etc/cni/net.d/10-ceph-net.conflist << 'EOF'
{
  "cniVersion": "0.4.0",
  "name": "ceph-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "subnet": "10.244.0.0/16",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true},
      "snat": true
    },
    {
      "type": "firewall",
      "backend": "iptables"
    }
  ]
}
EOF

# Configure Podman to use CNI network
echo "[network]" >> ~/.config/containers/containers.conf
echo "network_backend = \"cni\"" >> ~/.config/containers/containers.conf
```

## Step 5: Deploy Application Across Nodes

### Quadlet with Ceph Volume

```ini
# ~/.config/containers/systemd/webapp/webapp.container
[Container]
ContainerName=webapp
Image=ghcr.io/myorg/webapp:v1.2.3

# Use CephFS for shared storage
Volume=/var/lib/containers/storage/volumes-shared/webapp:/app/data:Z

# Port binding (unique per node or use load balancer)
PublishPort=8080:8080

[Service]
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

### Deploy Script with Node Awareness

```bash
#!/bin/bash
# deploy-multi-node.sh

set -euo pipefail

NODES=("$@")
APP="${APP:-webapp}"
VERSION="${VERSION:-latest}"

echo "=== Deploying $APP v$VERSION to ${#NODES[@]} nodes ==="

for node in "${NODES[@]}"; do
    echo "Deploying to $node..."
    
    # Copy quadlet files
    rsync -avz ~/.config/containers/systemd/$APP/ $node:~/.config/containers/systemd/$APP/
    
    # Deploy on remote node
    ssh $node "
        systemctl --user daemon-reload
        systemctl --user start $APP-pod.service || true
        systemctl --user start $APP.service
        sleep 5
        systemctl --user is-active $APP.service
    " || echo "WARNING: Deploy to $node failed"
done

echo "=== Deployment Complete ==="
echo "Verify on each node: ssh <node> 'podman ps'"
```

## Step 6: Load Balancer Configuration

### HAProxy Configuration

```bash
# On load balancer node (or separate instance)
sudo pacman -S haproxy

sudo tee /etc/haproxy/haproxy.cfg << 'EOF'
global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy

defaults
    mode http
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    option httpchk GET /health

frontend webapp_frontend
    bind *:80
    bind *:443 ssl crt /etc/ssl/certs/webapp.pem
    default_backend webapp_backend

backend webapp_backend
    balance roundrobin
    option httpchk GET /health
    server node1 10.200.0.1:8080 check
    server node2 10.200.0.2:8080 check
    server node3 10.200.0.3:8080 check
EOF

sudo systemctl enable --now haproxy
```

## Monitoring & Alerting

### Ceph Health Alerts

```yaml
# monitoring/prometheus/ceph-alerts.yml
groups:
  - name: ceph
    rules:
      - alert: CephUnhealthy
        expr: ceph_health_status != 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Ceph cluster is unhealthy"
          
      - alert: CephOSDDown
        expr: ceph_osd_up == 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Ceph OSD is down"
          
      - alert: CephHighLatency
        expr: ceph_osd_apply_latency_ms > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Ceph OSD latency is high"
```

## Troubleshooting

### Ceph HEALTH_WARN

```bash
# Check detailed health
sudo ceph health detail

# Common issues:
# 1. Clock skew
sudo timedatectl set-ntp true

# 2. Low space
sudo ceph osd df

# 3. Slow requests
sudo ceph osd dump | grep -i "slow"
```

### WireGuard Connectivity Issues

```bash
# Check WireGuard status
sudo wg show

# Test mesh connectivity
for node in 10.200.0.1 10.200.0.2 10.200.0.3; do
    ping -c 1 $node && echo "$node: OK" || echo "$node: FAIL"
done

# Check firewall
sudo iptables -L -n | grep 51820
```

## Validation Checklist

- [ ] WireGuard mesh: All nodes can ping each other
- [ ] Ceph cluster: HEALTH_OK status
- [ ] CephFS: Mounted on all nodes
- [ ] Podman: Can create containers on all nodes
- [ ] Load Balancer: Health checks passing
- [ ] Data replication: Write on node1, readable on node2
- [ ] Failover: Stop node1, service still available

---

**Next**: [Capacity Planning](../capacity-planning/README.md) | [Chaos Engineering](../chaos-engineering/game-days.md)
