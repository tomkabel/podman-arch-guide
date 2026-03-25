# Keepalived Configuration
# Virtual IP (VIP) management for high availability

## Overview

Keepalived provides:
- **Virtual IP Failover**: Automatic VIP migration on node failure
- **Health Checking**: Monitors service health
- **Load Balancing**: VRRP protocol for redundancy
- **Notification**: Alerts on state changes

## Architecture

```
        Internet
           │
           ▼
    ┌─────────────┐
    │  Virtual IP │  192.168.1.100 (Floating)
    │  (VIP)      │
    └──────┬──────┘
           │
    ┌──────┴──────┐
    │             │
┌───▼───┐   ┌────▼────┐   ┌─────────┐
│ Node 1│   │ Node 2  │   │ Node 3  │
│MASTER │   │ BACKUP  │   │ BACKUP  │
│PRI:101│   │ PRI:100 │   │ PRI:99  │
└───────┘   └─────────┘   └─────────┘
   ▲                            ▲
   └────────── Failover ────────┘
```

## Quick Start

### 1. Generate Configuration

```bash
cd multi-node
./setup-cluster.sh
```

### 2. Deploy Keepalived

**Node 1 (Master):**
```bash
scp keepalived/configs/keepalived-node1.conf root@node1:/etc/keepalived/keepalived.conf
scp keepalived/*.sh root@node1:/etc/keepalived/

ssh root@node1 "chmod +x /etc/keepalived/*.sh && systemctl enable keepalived && systemctl start keepalived"
```

**Node 2 & 3 (Backup):**
```bash
scp keepalived/configs/keepalived-node2.conf root@node2:/etc/keepalived/keepalived.conf
scp keepalived/*.sh root@node2:/etc/keepalived/

ssh root@node2 "chmod +x /etc/keepalived/*.sh && systemctl enable keepalived && systemctl start keepalived"
```

Or use the automated script:
```bash
./keepalived/deploy.sh node1
```

### 3. Verify VIP

```bash
# On master node
ip addr show | grep 192.168.1.100

# Test failover
ssh root@node1 "systemctl stop keepalived"

# Check VIP moved to backup
ssh root@node2 "ip addr show | grep 192.168.1.100"

# Restore master
ssh root@node1 "systemctl start keepalived"
```

## Configuration

### keepalived.conf (Master)

```conf
global_defs {
    router_id LVS_node1
    script_user root
    enable_script_security
}

# Health check script
vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass SecurePass123
    }
    
    virtual_ipaddress {
        192.168.1.100/24
    }
    
    track_script {
        check_haproxy
    }
    
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault "/etc/keepalived/notify.sh fault"
}
```

### keepalived.conf (Backup)

```conf
global_defs {
    router_id LVS_node2
}

vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 2
    weight 2
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass SecurePass123
    }
    
    virtual_ipaddress {
        192.168.1.100/24
    }
    
    track_script {
        check_haproxy
    }
    
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault "/etc/keepalived/notify.sh fault"
}
```

### Health Check Script

```bash
#!/bin/bash
# /etc/keepalived/check_haproxy.sh

# Check if HAProxy is running
if systemctl is-active --quiet haproxy; then
    # Additional check: test HAProxy stats endpoint
    if wget -qO- http://localhost:8404/stats > /dev/null 2>&1; then
        exit 0
    fi
fi

exit 1
```

### Notification Script

```bash
#!/bin/bash
# /etc/keepalived/notify.sh

TYPE=$1
HOST=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Log to file
echo "[$DATE] $HOST transitioned to $TYPE state" >> /var/log/keepalived.log

# Send email notification (optional)
# echo "Keepalived: $HOST is now $TYPE" | mail -s "Keepalived State Change" admin@example.com

# Send to Slack (optional)
# curl -X POST -H 'Content-type: application/json' \
#   --data '{"text":"Keepalived: '$HOST' is now '$TYPE'"}' \
#   https://hooks.slack.com/services/YOUR/WEBHOOK/URL

exit 0
```

## VRRP Protocol Details

### State Machine

```
┌─────────┐    init     ┌─────────┐
│  INIT   │────────────►│ BACKUP  │
└─────────┘             └────┬────┘
                             │
                    higher    │  master
                    priority  │  down
                        │     │
                        ▼     ▼
                   ┌──────────────┐
                   │    MASTER    │
                   └──────┬───────┘
                          │
                    lower │  higher
                    priority  priority
                       │      │
                       ▼      ▼
                   ┌──────────────┐
                   │    FAULT     │
                   └──────────────┘
```

### Priority Calculation

- **Base Priority**: 100 (backup), 101+ (master)
- **Track Script**: +/- weight based on health check
- **Preempt**: Higher priority node takes over (default: yes)

## Advanced Configuration

### Multiple VIPs

```conf
vrrp_instance VI_1 {
    # ... basic config ...
    
    virtual_ipaddress {
        192.168.1.100/24
        192.168.1.101/24
        192.168.1.102/24
    }
}
```

### Multiple VRRP Instances

```conf
# Internal VIP
vrrp_instance VI_INTERNAL {
    state MASTER
    interface eth1
    virtual_router_id 52
    priority 101
    virtual_ipaddress {
        10.0.0.100/24
    }
}

# External VIP
vrrp_instance VI_EXTERNAL {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    virtual_ipaddress {
        203.0.113.100/24
    }
}
```

### Sync Groups

```conf
# Keep multiple VRRP instances in sync
vrrp_sync_group VG1 {
    group {
        VI_INTERNAL
        VI_EXTERNAL
    }
    
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault "/etc/keepalived/notify.sh fault"
}
```

## Load Balancing (LVS)

Keepalived can also configure Linux Virtual Server (LVS):

```conf
# Virtual Server for HTTP
virtual_server 192.168.1.100 80 {
    delay_loop 6
    lb_algo wlc
    lb_kind DR
    persistence_timeout 50
    protocol TCP

    real_server 192.168.1.11 80 {
        weight 1
        TCP_CHECK {
            connect_timeout 3
        }
    }

    real_server 192.168.1.12 80 {
        weight 1
        TCP_CHECK {
            connect_timeout 3
        }
    }
}
```

## Troubleshooting

### Check Status
```bash
# View VRRP status
cat /var/log/messages | grep Keepalived

# Check VIP assignment
ip addr show eth0

# View keepalived processes
ps aux | grep keepalived
```

### Debug Mode
```bash
# Run in foreground with debug
keepalived -n -l -D
```

### Common Issues

**1. Split Brain (Multiple Masters)**
```bash
# Check network connectivity between nodes
ping <other-node-ip>

# Verify firewall allows VRRP (protocol 112)
iptables -L -n | grep 112
```

**2. VIP Not Assigned**
```bash
# Check if track_script is failing
/etc/keepalived/check_haproxy.sh
echo $?

# Verify interface name
ip link show
```

**3. Failover Not Working**
```bash
# Check priority values
grep priority /etc/keepalived/keepalived.conf

# Verify virtual_router_id is same on all nodes
grep virtual_router_id /etc/keepalived/keepalived.conf
```

### Log Analysis

```bash
# View recent logs
journalctl -u keepalived -n 100

# Follow logs
journalctl -u keepalived -f

# Filter for state changes
grep "Entering" /var/log/keepalived.log
```
