# WireGuard Mesh Network Configuration
# Secure private networking for 3-node cluster

## Overview

WireGuard provides encrypted mesh networking between all nodes in the cluster, enabling:
- Secure Ceph replication traffic
- Private service mesh communication
- Encrypted inter-node communication

## Architecture

```
┌─────────────┐        ┌─────────────┐        ┌─────────────┐
│   Node 1    │◄──────►│   Node 2    │◄──────►│   Node 3    │
│  10.200.0.1 │  WG    │  10.200.0.2 │  WG    │  10.200.0.3 │
│             │ Tunnel │             │ Tunnel │             │
└─────────────┘        └─────────────┘        └─────────────┘
       ▲                      ▲                      ▲
       └──────────────────────┴──────────────────────┘
                     Full Mesh
```

## Quick Start

### 1. Generate Configurations

```bash
cd multi-node
./setup-cluster.sh
```

This creates:
- `wireguard/configs/wg0-node1.conf`
- `wireguard/configs/wg0-node2.conf`
- `wireguard/configs/wg0-node3.conf`

### 2. Deploy to Each Node

**Node 1:**
```bash
scp wireguard/configs/wg0-node1.conf root@node1:/etc/wireguard/wg0.conf
ssh root@node1 "systemctl enable wg-quick@wg0 && systemctl start wg-quick@wg0"
```

**Node 2:**
```bash
scp wireguard/configs/wg0-node2.conf root@node2:/etc/wireguard/wg0.conf
ssh root@node2 "systemctl enable wg-quick@wg0 && systemctl start wg-quick@wg0"
```

**Node 3:**
```bash
scp wireguard/configs/wg0-node3.conf root@node3:/etc/wireguard/wg0.conf
ssh root@node3 "systemctl enable wg-quick@wg0 && systemctl start wg-quick@wg0"
```

Or use the automated deploy script:
```bash
./wireguard/deploy.sh node1
```

### 3. Verify Connectivity

```bash
# On each node
wg show
ping -c 3 10.200.0.2
ping -c 3 10.200.0.3
```

## Configuration Details

### Sample WireGuard Config

```ini
[Interface]
PrivateKey = <private-key>
Address = 10.200.0.1/24
ListenPort = 51820
MTU = 1420

# Enable IP forwarding and NAT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# DNS
DNS = 1.1.1.1, 8.8.8.8

[Peer]
# Node 2
PublicKey = <node2-public-key>
AllowedIPs = 10.200.0.2/32, 10.0.0.0/24
Endpoint = node2.example.com:51820
PersistentKeepalive = 25

[Peer]
# Node 3
PublicKey = <node3-public-key>
AllowedIPs = 10.200.0.3/32, 10.0.0.0/24
Endpoint = node3.example.com:51820
PersistentKeepalive = 25
```

### Security Features

- **Curve25519** for key exchange
- **ChaCha20-Poly1305** for encryption
- **Perfect Forward Secrecy**
- **No stateful connection tracking** (stealthy)
- **Kernel-level implementation** (high performance)

## Troubleshooting

### Check Interface Status
```bash
wg show
ip addr show wg0
```

### Test Connectivity
```bash
# Ping other nodes
ping 10.200.0.2
ping 10.200.0.3

# Check routing
ip route | grep wg0
```

### View Logs
```bash
journalctl -u wg-quick@wg0 -f
dmesg | grep wireguard
```

### Firewall Issues
```bash
# Check if WireGuard port is open
ss -tlnp | grep 51820

# Check iptables rules
iptables -L -v -n | grep wg0
```

## Performance Tuning

### MTU Settings
```ini
# If experiencing packet loss, adjust MTU
MTU = 1380  # For PPPoE connections
MTU = 1420  # Standard
```

### Persistent Keepalive
```ini
# Required for NAT/firewall traversal
PersistentKeepalive = 25
```

### CPU Affinity
```bash
# Pin WireGuard to specific CPU cores
echo 2 > /sys/class/net/wg0/thread_cpu_affinity
```

## Integration with Ceph

Ceph uses the WireGuard network for:
- Monitor replication
- OSD heartbeat
- Manager communication
- Client traffic (optional)

Configure Ceph to use WireGuard IPs:
```ini
[global]
mon host = 10.200.0.1,10.200.0.2,10.200.0.3
public network = 10.200.0.0/24
cluster network = 10.200.0.0/24
```
