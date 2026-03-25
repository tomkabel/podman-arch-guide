#!/bin/bash
# Multi-Node Cluster Setup Script
# Configures 3-node HA cluster with WireGuard, Ceph, and Keepalived

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Node configuration
NODE_IPS=()
NODE_NAMES=()
NODE_ROLES=()
VIP_ADDRESS=""
CEPH_NETWORK=""

# Generate WireGuard keys
generate_wg_keys() {
    local private_key=$(wg genkey)
    local public_key=$(echo "$private_key" | wg pubkey)
    echo "${private_key}:${public_key}"
}

# Setup WireGuard mesh network
setup_wireguard() {
    log "Setting up WireGuard mesh network..."

    local num_nodes=${#NODE_IPS[@]}
    local wg_port=51820
    local wg_network="10.200.0"

    # Create WireGuard config directory
    mkdir -p "${CONFIG_DIR}/wireguard/configs"

    # Generate keys for all nodes
    declare -a WG_PRIVATE_KEYS
    declare -a WG_PUBLIC_KEYS

    for i in $(seq 0 $((num_nodes - 1))); do
        local keys=$(generate_wg_keys)
        WG_PRIVATE_KEYS[$i]=$(echo "$keys" | cut -d: -f1)
        WG_PUBLIC_KEYS[$i]=$(echo "$keys" | cut -d: -f2)
    done

    # Generate config for each node
    for i in $(seq 0 $((num_nodes - 1))); do
        local node_name="${NODE_NAMES[$i]}"
        local node_ip="${NODE_IPS[$i]}"
        local wg_ip="${wg_network}.$((i + 1))"

        log "Generating WireGuard config for ${node_name}..."

        cat > "${CONFIG_DIR}/wireguard/configs/wg0-${node_name}.conf" << EOF
# WireGuard Configuration for ${node_name}
# Generated on $(date)

[Interface]
PrivateKey = ${WG_PRIVATE_KEYS[$i]}
Address = ${wg_ip}/24
ListenPort = ${wg_port}
MTU = 1420

# IP forwarding and NAT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# DNS
DNS = 1.1.1.1, 8.8.8.8

# Peers
EOF

        # Add all other nodes as peers
        for j in $(seq 0 $((num_nodes - 1))); do
            if [[ $i -ne $j ]]; then
                local peer_name="${NODE_NAMES[$j]}"
                local peer_ip="${NODE_IPS[$j]}"
                local peer_wg_ip="${wg_network}.$((j + 1))"

                cat >> "${CONFIG_DIR}/wireguard/configs/wg0-${node_name}.conf" << EOF
[Peer]
# ${peer_name}
PublicKey = ${WG_PUBLIC_KEYS[$j]}
AllowedIPs = ${peer_wg_ip}/32, ${CEPH_NETWORK}
Endpoint = ${peer_ip}:${wg_port}
PersistentKeepalive = 25

EOF
            fi
        done

        success "Created WireGuard config for ${node_name}"
    done

    # Create deployment script
    cat > "${CONFIG_DIR}/wireguard/deploy.sh" << 'DEPLOY_SCRIPT'
#!/bin/bash
# Deploy WireGuard configuration to nodes

NODE_NAME=${1:-$(hostname)}
CONFIG_FILE="configs/wg0-${NODE_NAME}.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE"
    exit 1
fi

# Install WireGuard if needed
if ! command -v wg &> /dev/null; then
    echo "Installing WireGuard..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y wireguard wireguard-tools
    elif command -v dnf &> /dev/null; then
        dnf install -y wireguard-tools
    elif command -v yum &> /dev/null; then
        yum install -y wireguard-tools
    fi
fi

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.forwarding=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# Copy config
cp "$CONFIG_FILE" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "WireGuard deployed on ${NODE_NAME}"
wg show
DEPLOY_SCRIPT

    chmod +x "${CONFIG_DIR}/wireguard/deploy.sh"
    success "WireGuard configuration complete"
}

# Setup Ceph cluster
setup_ceph() {
    log "Setting up Ceph cluster configuration..."

    local num_nodes=${#NODE_IPS[@]}

    mkdir -p "${CONFIG_DIR}/ceph/configs"

    # Generate Ceph admin keyring
    local admin_key=$(ceph-authtool --gen-print-key)
    local mon_key=$(ceph-authtool --gen-print-key)
    local mgr_key=$(ceph-authtool --gen-print-key)
    local client_key=$(ceph-authtool --gen-print-key)

    # Create admin keyring
    cat > "${CONFIG_DIR}/ceph/ceph.client.admin.keyring" << EOF
[client.admin]
    key = ${admin_key}
    caps mds = "allow *"
    caps mgr = "allow *"
    caps mon = "allow *"
    caps osd = "allow *"
EOF

    chmod 600 "${CONFIG_DIR}/ceph/ceph.client.admin.keyring"

    # Create monitor keyring
    cat > "${CONFIG_DIR}/ceph/ceph.mon.keyring" << EOF
[mon.]
    key = ${mon_key}
    caps mon = "allow *"

[client.admin]
    key = ${admin_key}
    caps mds = "allow *"
    caps mgr = "allow *"
    caps mon = "allow *"
    caps osd = "allow *"
EOF

    # Create Ceph configuration
    cat > "${CONFIG_DIR}/ceph/ceph.conf" << EOF
# Ceph Cluster Configuration
# Generated on $(date)

[global]
fsid = $(uuidgen)
mon initial members = $(IFS=,; echo "${NODE_NAMES[*]}")
mon host = $(IFS=,; echo "${NODE_IPS[*]}")
public network = ${CEPH_NETWORK}
cluster network = ${CEPH_NETWORK}

# Authentication
auth cluster required = cephx
auth service required = cephx
auth client required = cephx

# Performance tuning
osd journal size = 5120
osd pool default size = 3
osd pool default min size = 2
osd pool default pg num = 128
osd pool default pgp num = 128

# Logging
log file = /var/log/ceph/ceph.log
mon cluster log file = /var/log/ceph/ceph.log

# Enable Prometheus exporter
mgr modules = prometheus
mgr prometheus server port = 9283

[mon]
mon allow pool delete = true

[mgr]
mgr prometheus server addr = 0.0.0.0

[osd]
osd memory target = 2147483648
osd max write size = 256
EOF

    # Generate monmap
    local mon_map_cmd="monmaptool --create --clobber"
    for i in $(seq 0 $((num_nodes - 1))); do
        mon_map_cmd="${mon_map_cmd} --add ${NODE_NAMES[$i]} ${NODE_IPS[$i]}:6789"
    done
    mon_map_cmd="${mon_map_cmd} ${CONFIG_DIR}/ceph/monmap"

    eval "$mon_map_cmd"

    success "Ceph configuration generated"
}

# Setup Keepalived
setup_keepalived() {
    log "Setting up Keepalived for VIP management..."

    local num_nodes=${#NODE_IPS[@]}
    local priority=100

    mkdir -p "${CONFIG_DIR}/keepalived/configs"

    for i in $(seq 0 $((num_nodes - 1))); do
        local node_name="${NODE_NAMES[$i]}"
        local node_ip="${NODE_IPS[$i]}"
        local state="BACKUP"

        # First node is MASTER
        if [[ $i -eq 0 ]]; then
            state="MASTER"
            priority=101
        else
            priority=$((100 - i))
        fi

        log "Creating Keepalived config for ${node_name}..."

        cat > "${CONFIG_DIR}/keepalived/configs/keepalived-${node_name}.conf" << EOF
# Keepalived Configuration for ${node_name}
# Generated on $(date)

global_defs {
    router_id LVS_${node_name}
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

# VRRP Instance for VIP
vrrp_instance VI_1 {
    state ${state}
    interface eth0
    virtual_router_id 51
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS:-ceph1234}
    }
    virtual_ipaddress {
        ${VIP_ADDRESS}/24
    }
    track_script {
        check_haproxy
    }
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault "/etc/keepalived/notify.sh fault"
}
EOF

        success "Created Keepalived config for ${node_name}"
    done

    # Create health check script
    cat > "${CONFIG_DIR}/keepalived/check_haproxy.sh" << 'HEALTH_SCRIPT'
#!/bin/bash
# HAProxy health check script for Keepalived

if systemctl is-active --quiet haproxy; then
    exit 0
else
    exit 1
fi
HEALTH_SCRIPT

    chmod +x "${CONFIG_DIR}/keepalived/check_haproxy.sh"

    # Create notification script
    cat > "${CONFIG_DIR}/keepalived/notify.sh" << 'NOTIFY_SCRIPT'
#!/bin/bash
# Keepalived state notification script

TYPE=$1
HOST=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="/var/log/keepalived.log"

echo "[$DATE] $HOST transitioned to $TYPE state" >> $LOG_FILE

# Send notification (customize as needed)
# echo "Keepalived: $HOST is now $TYPE" | mail -s "Keepalived State Change" admin@example.com

exit 0
NOTIFY_SCRIPT

    chmod +x "${CONFIG_DIR}/keepalived/notify.sh"

    # Create deployment script
    cat > "${CONFIG_DIR}/keepalived/deploy.sh" << 'DEPLOY_SCRIPT'
#!/bin/bash
# Deploy Keepalived configuration

NODE_NAME=${1:-$(hostname)}
CONFIG_FILE="configs/keepalived-${NODE_NAME}.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE"
    exit 1
fi

# Install Keepalived if needed
if ! command -v keepalived &> /dev/null; then
    echo "Installing Keepalived..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y keepalived
    elif command -v dnf &> /dev/null; then
        dnf install -y keepalived
    elif command -v yum &> /dev/null; then
        yum install -y keepalived
    fi
fi

# Copy config
cp "$CONFIG_FILE" /etc/keepalived/keepalived.conf
cp check_haproxy.sh /etc/keepalived/
cp notify.sh /etc/keepalived/
chmod +x /etc/keepalived/*.sh

# Start Keepalived
systemctl enable keepalived
systemctl restart keepalived

echo "Keepalived deployed on ${NODE_NAME}"
ip addr show | grep -A2 "inet "
DEPLOY_SCRIPT

    chmod +x "${CONFIG_DIR}/keepalived/deploy.sh"
    success "Keepalived configuration complete"
}

# Setup HAProxy
setup_haproxy() {
    log "Setting up HAProxy configuration..."

    mkdir -p "${CONFIG_DIR}/haproxy/services"

    # Create main HAProxy config
    cat > "${CONFIG_DIR}/haproxy/haproxy.cfg" << EOF
# HAProxy Configuration for Multi-Node Cluster
# Generated on $(date)

global
    log stdout local0 info
    maxconn 4096
    user haproxy
    group haproxy
    daemon

    # Performance
    nbthread 4
    cpu-map auto:1/1-4 0-3

    # SSL
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
    ssl-dh-param-file /etc/ssl/certs/dhparam.pem

defaults
    log global
    mode http
    option httplog
    option dontlognull
    option log-health-checks

    timeout connect 5s
    timeout client 30s
    timeout server 30s
    timeout http-request 10s
    timeout http-keep-alive 10s

    # Error pages
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 503 /etc/haproxy/errors/503.http

    # Stats
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE

# Frontend - HTTP
frontend http_in
    bind *:80
    redirect scheme https if !{ ssl_fc }

# Frontend - HTTPS
frontend https_in
    bind *:443 ssl crt /etc/ssl/certs/combined.pem alpn h2,http/1.1

    # Security headers
    http-response set-header X-Frame-Options SAMEORIGIN
    http-response set-header X-Content-Type-Options nosniff
    http-response set-header X-XSS-Protection "1; mode=block"
    http-response set-header Strict-Transport-Security "max-age=63072000"

    # ACLs
    acl is_health_check path /health

    # Health check endpoint
    use_backend health_backend if is_health_check

    # Default backend
    default_backend app_backend

# Backend - Application Servers
backend app_backend
    balance roundrobin
    option httpchk GET /health
    http-check expect status 200

    # Server template for Consul SD
    # Servers will be dynamically added by Consul
    server-template app 3 _app._tcp.service.consul:8080 check inter 5s rise 2 fall 3

    # Manual fallback servers (used if Consul is unavailable)
EOF

    # Add fallback servers
    for i in $(seq 0 $((${#NODE_IPS[@]} - 1))); do
        local node_name="${NODE_NAMES[$i]}"
        local node_ip="${NODE_IPS[$i]}"
        echo "    server ${node_name}-backup ${node_ip}:8080 check backup" >> "${CONFIG_DIR}/haproxy/haproxy.cfg"
    done

    cat >> "${CONFIG_DIR}/haproxy/haproxy.cfg" << 'EOF'

    # Connection limits
    fullconn 100

# Backend - Health Check
backend health_backend
    mode http
    http-request return status 200 content-type "application/json" lf-string '{"status":"healthy","cluster":"multi-node"}'

# Stats Frontend
frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if TRUE
    stats show-desc "Multi-Node Cluster Stats"
EOF

    success "HAProxy configuration generated"
}

# Setup Consul
setup_consul() {
    log "Setting up Consul service discovery..."

    mkdir -p "${CONFIG_DIR}/consul"

    # Server configuration
    cat > "${CONFIG_DIR}/consul/server-config.hcl" << 'EOF'
# Consul Server Configuration

datacenter = "dc1"
data_dir = "/consul/data"
server = true
bootstrap_expect = 3
ui = true

# Performance
performance {
    raft_multiplier = 1
}

# Telemetry
telemetry {
    prometheus_retention_time = "30s"
    disable_hostname = true
}

# ACL (enable for production)
# acl {
#     enabled = true
#     default_policy = "deny"
#     enable_token_persistence = true
# }

# Encryption (generate with: consul keygen)
# encrypt = "your-encryption-key-here"

# Connect service mesh
connect {
    enabled = true
}
EOF

    # Agent configuration
    cat > "${CONFIG_DIR}/consul/agent-config.hcl" << 'EOF'
# Consul Agent Configuration

datacenter = "dc1"
data_dir = "/consul/data"
server = false
ui = false

# Client settings
client_addr = "0.0.0.0"
bind_addr = "{{ GetInterfaceIP \"eth0\" }}"

# DNS
ports {
    dns = 8600
}
dns_config {
    enable_truncate = true
    only_passing = true
}

# Performance
performance {
    raft_multiplier = 1
}

# Service registration
service {
    name = "haproxy"
    port = 80
    check {
        id = "haproxy-check"
        name = "HAProxy Health"
        http = "http://localhost:8404/stats"
        interval = "10s"
        timeout = "5s"
    }
}

# Connect service mesh
connect {
    enabled = true
}
EOF

    success "Consul configuration generated"
}

# Main setup function
main() {
    cat << 'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║          Multi-Node HA Cluster Setup                          ║
║          Podman + WireGuard + Ceph + Keepalived              ║
╚═══════════════════════════════════════════════════════════════╝
BANNER

    log "Starting multi-node cluster setup..."

    # Check if config exists
    if [[ -f "${CONFIG_DIR}/cluster.conf" ]]; then
        log "Loading existing configuration..."
        source "${CONFIG_DIR}/cluster.conf"
    else
        # Interactive configuration
        log "Enter cluster configuration..."

        read -p "Number of nodes [3]: " num_nodes
        num_nodes=${num_nodes:-3}

        for i in $(seq 1 $num_nodes); do
            read -p "Node $i name: " name
            read -p "Node $i IP: " ip
            read -p "Node $i role [mon,mgr,osd]: " role

            NODE_NAMES+=("$name")
            NODE_IPS+=("$ip")
            NODE_ROLES+=("$role")
        done

        read -p "Virtual IP (VIP): " VIP_ADDRESS
        read -p "Ceph Network (e.g., 10.0.0.0/24): " CEPH_NETWORK

        # Save configuration
        cat > "${CONFIG_DIR}/cluster.conf" << EOF
# Cluster Configuration
# Generated on $(date)

NODE_NAMES=(${NODE_NAMES[@]})
NODE_IPS=(${NODE_IPS[@]})
NODE_ROLES=(${NODE_ROLES[@]})
VIP_ADDRESS=${VIP_ADDRESS}
CEPH_NETWORK=${CEPH_NETWORK}
EOF
    fi

    # Create directory structure
    mkdir -p "${CONFIG_DIR}"/{wireguard,ceph,keepalived,haproxy,consul,scripts}

    # Generate all configurations
    setup_wireguard
    setup_ceph
    setup_keepalived
    setup_haproxy
    setup_consul

    # Create deployment scripts
    cat > "${CONFIG_DIR}/deploy-all.sh" << 'EOF'
#!/bin/bash
# Deploy all configurations to cluster nodes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cluster.conf"

for i in "${!NODE_NAMES[@]}"; do
    node="${NODE_NAMES[$i]}"
    ip="${NODE_IPS[$i]}"

    echo "Deploying to ${node} (${ip})..."

    # Copy WireGuard config
    scp "${SCRIPT_DIR}/wireguard/configs/wg0-${node}.conf" "root@${ip}:/etc/wireguard/wg0.conf"

    # Copy Keepalived config
    scp "${SCRIPT_DIR}/keepalived/configs/keepalived-${node}.conf" "root@${ip}:/etc/keepalived/keepalived.conf"
    scp "${SCRIPT_DIR}/keepalived/check_haproxy.sh" "root@${ip}:/etc/keepalived/"
    scp "${SCRIPT_DIR}/keepalived/notify.sh" "root@${ip}:/etc/keepalived/"

    # Copy Ceph configs
    scp -r "${SCRIPT_DIR}/ceph/"* "root@${ip}:/etc/ceph/"

    # Restart services
    ssh "root@${ip}" "systemctl restart wg-quick@wg0 keepalived"

done

echo "Deployment complete!"
EOF

    chmod +x "${CONFIG_DIR}/deploy-all.sh"

    success "Multi-node cluster setup complete!"
    log "Configuration files created in:"
    log "  - wireguard/configs/"
    log "  - ceph/"
    log "  - keepalived/configs/"
    log "  - haproxy/"
    log "  - consul/"
    log ""
    log "Next steps:"
    log "  1. Review configurations"
    log "  2. Run ./deploy-all.sh to deploy to nodes"
    log "  3. Start Podman services with: podman-compose up -d"
}

# Run main function
main "$@"
