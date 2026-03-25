# Multi-Node HA Cluster Deployment Guide

Complete 3-node High Availability cluster with Podman, WireGuard, Ceph, Keepalived, and HAProxy.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Multi-Node HA Cluster                            │
│                                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐               │
│  │    Node 1    │◄──►│    Node 2    │◄──►│    Node 3    │               │
│  │   (Master)   │ WG │   (Backup)   │ WG │   (Backup)   │               │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘               │
│         │                    │                    │                      │
│  ┌──────▼───────┐    ┌──────▼───────┐    ┌──────▼───────┐               │
│  │  Keepalived  │    │  Keepalived  │    │  Keepalived  │               │
│  │  VIP Master  │◄──►│ VIP Backup   │◄──►│ VIP Backup   │               │
│  └──────┬───────┘    └──────────────┘    └──────────────┘               │
│         │                                                                │
│  ┌──────▼───────┐                                                       │
│  │    VIP       │  192.168.1.100 (Floating)                             │
│  └──────┬───────┘                                                       │
│         │                                                                │
│  ┌──────▼───────┐                                                       │
│  │   HAProxy    │  Load Balancer                                        │
│  └──────┬───────┘                                                       │
│         │                                                                │
│  ┌──────┴───────┬────────────────┐                                      │
│  │              │                │                                      │
│  ▼              ▼                ▼                                      │
│ ┌─────┐     ┌─────┐      ┌───────────┐                                │
│ │ App │     │ App │      │   Ceph    │                                │
│ │ :80 │     │ :80 │      │  Storage  │                                │
│ └──┬──┘     └──┬──┘      └─────┬─────┘                                │
│    │           │               │                                       │
│    └───────────┴───────────────┘                                       │
│                │                                                       │
│           Consul SD                                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Hardware Requirements

Per node:
- **CPU**: 4+ cores
- **RAM**: 8GB+ (16GB recommended)
- **Storage**: 
  - 50GB system disk
  - 100GB+ Ceph OSD disk (per node)
- **Network**: 2x NICs (management + storage)

### Software Requirements

All nodes:
- RHEL 8/9, CentOS Stream 8/9, Ubuntu 20.04/22.04, or Fedora 38+
- Podman 4.0+
- WireGuard kernel module
- Systemd

## Network Topology

### IP Plan

| Node | Public IP | WireGuard IP | Role |
|------|-----------|--------------|------|
| node1 | 192.168.1.11 | 10.200.0.1 | Master (VIP holder) |
| node2 | 192.168.1.12 | 10.200.0.2 | Backup |
| node3 | 192.168.1.13 | 10.200.0.3 | Backup |
| VIP | 192.168.1.100 | - | Floating |

### Network Layout

```
Internet
    │
    ▼
┌───────────┐     ┌───────────┐
│  Router   │────►│  Firewall │
└───────────┘     └─────┬─────┘
                        │
           ┌────────────┼────────────┐
           │            │            │
     ┌─────▼─────┐ ┌────▼────┐ ┌────▼────┐
     │  Node 1   │ │ Node 2  │ │ Node 3  │
     │ 192.168.1.11  192.168.1.12  192.168.1.13
     └─────┬─────┘ └────┬────┘ └────┬────┘
           │            │            │
           └────────────┴────────────┘
                        │
                  WireGuard Mesh
                   (10.200.0.x)
```

## Deployment Steps

### Phase 1: Initial Setup

1. **Prepare all nodes:**
```bash
# On each node
hostnamectl set-hostname node1  # node2, node3 on others

# Update system
dnf update -y

# Install required packages
dnf install -y podman podman-compose wireguard-tools keepalived haproxy

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
```

2. **Generate cluster configuration:**
```bash
# On your admin workstation
cd multi-node

# Create cluster.conf
cat > cluster.conf << 'EOF'
NODE_NAMES=(node1 node2 node3)
NODE_IPS=(192.168.1.11 192.168.1.12 192.168.1.13)
NODE_ROLES=(mon,mgr,osd mon,mgr,osd mon,mgr,osd)
VIP_ADDRESS=192.168.1.100
CEPH_NETWORK=10.200.0.0/24
KEEPALIVED_AUTH_PASS=SecurePass123
EOF

# Generate all configurations
./setup-cluster.sh
```

### Phase 2: WireGuard Mesh

1. **Deploy WireGuard on all nodes:**
```bash
# Deploy configurations
for node in node1 node2 node3; do
    scp wireguard/configs/wg0-${node}.conf root@${node}:/etc/wireguard/wg0.conf
done

# Start WireGuard
for node in node1 node2 node3; do
    ssh root@${node} "systemctl enable wg-quick@wg0 && systemctl start wg-quick@wg0"
done
```

2. **Verify connectivity:**
```bash
# From node1
ping -c 3 10.200.0.2
ping -c 3 10.200.0.3

# Check WireGuard status
wg show
```

### Phase 3: Ceph Storage

1. **Prepare OSD disks:**
```bash
# On each node - identify your OSD disk
lsblk

# Create partition if needed
parted /dev/sdb mklabel gpt
parted -a optimal /dev/sdb mkpart primary 0% 100%
```

2. **Deploy Ceph:**
```bash
# Copy Ceph configuration to all nodes
for node in node1 node2 node3; do
    scp ceph/* root@${node}:/etc/ceph/
done

# Bootstrap Ceph on node1
ssh root@node1 "
    ceph-mon --mkfs -i node1 --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring
    systemctl enable ceph-mon@node1 ceph-mgr@node1
    systemctl start ceph-mon@node1 ceph-mgr@node1
    ceph-volume lvm create --data /dev/sdb
"

# Deploy on node2 and node3
for node in node2 node3; do
    ssh root@${node} "
        ceph-mon --mkfs -i ${node} --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring
        systemctl enable ceph-mon@${node} ceph-mgr@${node}
        systemctl start ceph-mon@${node} ceph-mgr@${node}
        ceph-volume lvm create --data /dev/sdb
    "
done
```

3. **Verify Ceph:**
```bash
ssh root@node1 "ceph status"
ssh root@node1 "ceph health detail"
```

### Phase 4: Keepalived VIP

1. **Deploy Keepalived:**
```bash
# Deploy to all nodes
for node in node1 node2 node3; do
    scp keepalived/configs/keepalived-${node}.conf root@${node}:/etc/keepalived/keepalived.conf
    scp keepalived/*.sh root@${node}:/etc/keepalived/
    ssh root@${node} "chmod +x /etc/keepalived/*.sh"
done

# Start Keepalived
for node in node1 node2 node3; do
    ssh root@${node} "systemctl enable keepalived && systemctl start keepalived"
done
```

2. **Verify VIP:**
```bash
# Check VIP is on node1
ssh root@node1 "ip addr show | grep 192.168.1.100"

# Test failover
ssh root@node1 "systemctl stop keepalived"
ssh root@node2 "ip addr show | grep 192.168.1.100"

# Restore
ssh root@node1 "systemctl start keepalived"
```

### Phase 5: Podman Services

1. **Deploy Consul:**
```bash
# On node1
podman-compose up -d consul-server

# On all nodes
podman-compose up -d consul-agent
```

2. **Deploy HAProxy:**
```bash
# On all nodes
podman-compose up -d haproxy
```

3. **Deploy Applications:**
```bash
# Deploy application containers
podman-compose up -d app
```

4. **Deploy Monitoring:**
```bash
# On node1 (or designated monitoring node)
podman-compose up -d prometheus grafana
```

## Service Management

### Starting the Cluster

```bash
# On each node (in order)
systemctl start wg-quick@wg0
systemctl start keepalived
systemctl start haproxy

# Podman services
podman-compose up -d
```

### Stopping the Cluster

```bash
# Podman services
podman-compose down

# System services
systemctl stop haproxy keepalived wg-quick@wg0
```

### Checking Status

```bash
# Overall cluster health
./scripts/cluster-status.sh

# Individual components
systemctl status keepalived haproxy wg-quick@wg0
podman-compose ps
ceph status
```

## Maintenance

### Adding a Node

1. Prepare new node with WireGuard
2. Add to Ceph cluster
3. Update HAProxy backend
4. Add to Consul cluster

### Removing a Node

1. Migrate Ceph OSDs
2. Remove from HAProxy
3. Stop services
4. Remove from Consul

### Backup

```bash
# Ceph configuration
tar czf ceph-backup.tar.gz /etc/ceph/

# Consul data
podman exec consul-server consul snapshot save backup.snap

# Podman volumes
./scripts/backup-volumes.sh
```

## Troubleshooting

### Node Not Joining Cluster

```bash
# Check WireGuard
wg show
ping <other-node-wg-ip>

# Check Ceph
ceph status
ceph health detail

# Check logs
journalctl -u ceph-mon@node1 -f
```

### VIP Not Failing Over

```bash
# Check Keepalived logs
journalctl -u keepalived -f

# Verify VRRP is working
tcpdump -i eth0 vrrp

# Check priority settings
grep priority /etc/keepalived/keepalived.conf
```

### Ceph Health Issues

```bash
# Common fixes
ceph config set mon mon_allow_pool_delete true
ceph osd crush tunables optimal

# View detailed health
ceph health detail

# Check PG status
ceph pg stat
```

## Monitoring

### Consul UI
- URL: `http://<any-node>:8500`
- Shows all registered services and health status

### HAProxy Stats
- URL: `http://<vip>:8404/stats`
- Shows load balancing statistics

### Grafana Dashboard
- URL: `http://<vip>:3000`
- Default credentials: admin/admin
- Import dashboards from `grafana/dashboards/`

### Ceph Dashboard
- URL: `https://<any-node>:8443`
- Shows Ceph cluster status and performance

## Security Considerations

1. **WireGuard**: All inter-node traffic encrypted
2. **Firewall**: Restrict access to management ports
3. **SELinux**: Enable on all nodes
4. **Secrets**: Use Podman secrets for passwords
5. **Certificates**: Use valid SSL certificates
6. **Updates**: Regular security updates

## Resources

- [Podman Documentation](https://docs.podman.io/)
- [Ceph Documentation](https://docs.ceph.com/)
- [HAProxy Documentation](https://www.haproxy.org/)
- [Keepalived Documentation](https://www.keepalived.org/)
- [Consul Documentation](https://www.consul.io/)

## Support

For issues and questions:
1. Check logs: `journalctl -f -u <service>`
2. Review component READMEs in respective directories
3. Verify network connectivity between nodes
4. Check resource utilization
