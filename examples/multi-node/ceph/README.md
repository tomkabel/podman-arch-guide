# Ceph Cluster Configuration
# Distributed storage for 3-node HA cluster

## Overview

Ceph provides distributed, scalable storage for the multi-node cluster with:
- **High Availability**: No single point of failure
- **Self-Healing**: Automatic data recovery
- **Scalability**: Add nodes without downtime
- **Unified Storage**: Block, file, and object storage

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Ceph Cluster (3 Nodes)                   │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │   MON    │  │   MON    │  │   MON    │  (Monitor)        │
│  │   :6789  │  │   :6789  │  │   :6789  │                   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                   │
│       └─────────────┴─────────────┘                          │
│                         │                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │   MGR    │  │   MGR    │  │          │  (Manager)        │
│  │  Active  │  │ Standby  │  │          │                   │
│  └──────────┘  └──────────┘  └──────────┘                   │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │   OSD    │  │   OSD    │  │   OSD    │  (Object Storage) │
│  │  Node 1  │  │  Node 2  │  │  Node 3  │                   │
│  └──────────┘  └──────────┘  └──────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Prerequisites

Each node needs:
- Dedicated disk for OSD (e.g., `/dev/sdb`)
- 4GB+ RAM for Ceph services
- Network connectivity on WireGuard mesh

### 2. Generate Configuration

```bash
cd multi-node
./setup-cluster.sh
```

### 3. Deploy Ceph

**On Node 1 (bootstrap):**
```bash
# Copy configuration
mkdir -p /etc/ceph
scp ceph/* node1:/etc/ceph/

# Create initial monitor
ceph-mon --mkfs -i node1 --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring
systemctl enable ceph-mon@node1
systemctl start ceph-mon@node1

# Create manager
ceph-mgr -i node1
systemctl enable ceph-mgr@node1
systemctl start ceph-mgr@node1

# Create OSD
ceph-volume lvm create --data /dev/sdb
```

**On Node 2 & 3:**
```bash
scp ceph/* node2:/etc/ceph/
scp ceph/* node3:/etc/ceph/

# On each node:
ceph-mon --mkfs -i nodeX --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring
systemctl enable ceph-mon@nodeX ceph-mgr@nodeX
systemctl start ceph-mon@nodeX ceph-mgr@nodeX

# Create OSD
ceph-volume lvm create --data /dev/sdb
```

### 4. Verify Cluster

```bash
# Check cluster health
ceph status
ceph health detail

# View OSD tree
ceph osd tree

# View monitor status
ceph mon stat
```

## Configuration

### ceph.conf

```ini
[global]
fsid = <cluster-uuid>
mon initial members = node1,node2,node3
mon host = 10.200.0.1,10.200.0.2,10.200.0.3
public network = 10.200.0.0/24
cluster network = 10.200.0.0/24

auth cluster required = cephx
auth service required = cephx
auth client required = cephx

# Performance tuning
osd pool default size = 3
osd pool default min size = 2
osd pool default pg num = 128
osd pool default pgp num = 128

# Logging
log file = /var/log/ceph/ceph.log
mon cluster log file = /var/log/ceph/ceph.log

[mon]
mon allow pool delete = true

[osd]
osd memory target = 2147483648
```

### Keyring Files

**ceph.client.admin.keyring:**
```ini
[client.admin]
    key = AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==
    caps mds = "allow *"
    caps mgr = "allow *"
    caps mon = "allow *"
    caps osd = "allow *"
```

## Pool Management

### Create Pools

```bash
# Create a pool for Podman volumes
ceph osd pool create podman-volumes 128 128 replicated

# Enable RBD application
ceph osd pool application enable podman-volumes rbd

# Initialize RBD
rbd pool init podman-volumes
```

### Configure CRUSH Map

```bash
# View current CRUSH map
ceph osd getcrushmap -o crush.map
crushtool -d crush.map -o crush.txt

# Edit crush.txt for your topology
crushtool -c crush.txt -o crush-new.map
ceph osd setcrushmap -i crush-new.map
```

## Podman Integration

### Using Ceph RBD Volumes

```yaml
# docker-compose.yml
volumes:
  app_data:
    driver: local
    driver_opts:
      type: rbd
      o: name=admin,secret=<base64-encoded-key>
      device: rbd/podman-volumes/app_data
```

### Using CephFS

```yaml
# Mount CephFS in container
volumes:
  - type: volume
    source: cephfs_data
    target: /data
    volume:
      nocopy: true
```

## Monitoring

### Enable Prometheus Exporter

```bash
# Enable prometheus module
ceph mgr module enable prometheus

# Verify
curl http://localhost:9283/metrics
```

### Ceph Dashboard

```bash
# Enable dashboard
ceph mgr module enable dashboard

# Set credentials
ceph dashboard ac-user-create admin -i /tmp/password.txt administrator

# Access
https://<node-ip>:8443
```

## Maintenance

### Add New OSD

```bash
# Prepare disk
ceph-volume lvm create --data /dev/sdc

# Check rebalancing
ceph -w
```

### Remove OSD

```bash
# Mark OSD out
ceph osd out osd.<id>

# Wait for rebalancing
ceph -w

# Stop OSD service
systemctl stop ceph-osd@<id>
ceph osd crush remove osd.<id>
ceph auth del osd.<id>
ceph osd rm <id>
```

### Replace Failed Disk

```bash
# Remove old OSD
ceph osd out osd.<id>
ceph osd crush remove osd.<id>
ceph auth del osd.<id>
ceph osd rm <id>

# Create new OSD
ceph-volume lvm create --data /dev/sdX
```

## Troubleshooting

### Health Warnings

```bash
# View detailed health
ceph health detail

# Common fixes
ceph config set mon mon_allow_pool_delete true
ceph osd crush tunables optimal
```

### Slow Performance

```bash
# Check OSD performance
ceph tell osd.* bench

# View PG status
ceph pg stat

# Check for slow requests
ceph osd dump | grep -i slow
```

### Recovery Operations

```bash
# Set recovery priority
ceph tell osd.<id> injectargs '--osd-recovery-max-active=10'

# Pause recovery
ceph osd set norecover

# Resume recovery
ceph osd unset norecover
```

## Backup & Recovery

### Backup Configuration

```bash
# Backup ceph.conf and keyrings
tar czf ceph-backup-$(date +%Y%m%d).tar.gz /etc/ceph/

# Backup monitor store
ceph-monstore-tool /var/lib/ceph/mon/ceph-<id> get-monmap -o monmap-backup
```

### Disaster Recovery

```bash
# Recover from monitor failure
ceph-monstore-tool /var/lib/ceph/mon/ceph-<new-id> rebuild -- --keyring /etc/ceph/ceph.client.admin.keyring

# Recover PGs
ceph pg force_create_pg <pgid>
```
