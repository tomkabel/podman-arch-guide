#!/usr/bin/env bash
#===============================================================================
# ceph-setup.sh - Ceph Storage Cluster Setup for Podman
#===============================================================================
# Description: Initializes Ceph cluster on 3+ nodes, creates pools for podman
#              volumes, sets up RBD block storage, and configures CephFS.
# Author: DevOps Team
# Version: 1.0.0
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"
readonly LOG_DIR="${LOG_DIR:-/var/log/ceph-setup}"
readonly LOG_FILE="${LOG_DIR}/ceph-setup-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

# Ceph Configuration
CEPH_CLUSTER_NAME="${CEPH_CLUSTER_NAME:-ceph}"
CEPH_NETWORK="${CEPH_NETWORK:-10.200.0.0/24}"
CEPH_PUBLIC_NETWORK="${CEPH_PUBLIC_NETWORK:-10.200.0.0/24}"
CEPH_ADMIN_KEYRING="${CEPH_ADMIN_KEYRING:-/etc/ceph/ceph.client.admin.keyring}"
CEPH_CONF="${CEPH_CONF:-/etc/ceph/ceph.conf}"
CEPH_MON_INITIAL_MEMBERS="${CEPH_MON_INITIAL_MEMBERS:-node1,node2,node3}"
CEPH_FSID=""

# Node Configuration
NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
NODE_ROLE="${NODE_ROLE:-all}"  # all, mon, mgr, osd, mds
OSD_DEVICE="${OSD_DEVICE:-}"

# Pool Configuration
CEPH_POOL_NAME="${CEPH_POOL_NAME:-podman-volumes}"
CEPH_POOL_PG="${CEPH_POOL_PG:-128}"
CEPH_POOL_PGP="${CEPH_POOL_PGP:-128}"
CEPH_POOL_REPLICAS="${CEPH_POOL_REPLICAS:-3}"

# Installation
CEPH_REPOSITORY="${CEPH_REPOSITORY:-quay.io/ceph/ceph}"
CEPH_VERSION="${CEPH_VERSION:-v18}"

# Operational
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
SKIP_CREATE_POOL="${SKIP_CREATE_POOL:-false}"
SETUP_CEPHFS="${SETUP_CEPHFS:-false}"

#-------------------------------------------------------------------------------
# Colors
#-------------------------------------------------------------------------------
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r CYAN='\033[0;36m'
declare -r NC='\033[0m'

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$LOG_DIR"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        ERROR)   echo -e "${RED}[$timestamp] [ERROR] $message${NC}" >&2 ;;
        WARN)    echo -e "${YELLOW}[$timestamp] [WARN] $message${NC}" ;;
        SUCCESS) echo -e "${GREEN}[$timestamp] [SUCCESS] $message${NC}" ;;
        INFO)    echo -e "${BLUE}[$timestamp] [INFO] $message${NC}" ;;
        DEBUG)   echo -e "${CYAN}[$timestamp] [DEBUG] $message${NC}" ;;
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_debug() { log "DEBUG" "$@"; }

#-------------------------------------------------------------------------------
# Error Handling
#-------------------------------------------------------------------------------
die() {
    log_error "$@"
    cleanup
    exit 1
}

cleanup() {
    log_info "Performing cleanup..."
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

trap_cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated with exit code $exit_code"
    fi
    cleanup
    exit $exit_code
}

trap trap_cleanup EXIT INT TERM

#-------------------------------------------------------------------------------
# Lock Management
#-------------------------------------------------------------------------------
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
        if ps -p "$pid" > /dev/null 2>&1; then
            die "Another ceph-setup is in progress (PID: ${pid})"
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Acquired setup lock"
}

#-------------------------------------------------------------------------------
# Prerequisites Checking
#-------------------------------------------------------------------------------
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root (required for Ceph)
    if [[ $EUID -ne 0 ]]; then
        die "Ceph setup must be run as root"
    fi
    
    # Check for required commands
    local missing_cmds=()
    for cmd in ceph ceph-volume podman; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done
    
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing_cmds[*]}"
    fi
    
    # Check for OSD device if this node will be OSD
    if [[ "$NODE_ROLE" == *"osd"* ]] || [[ "$NODE_ROLE" == "all" ]]; then
        if [[ -z "$OSD_DEVICE" ]]; then
            log_warn "OSD_DEVICE not set - no OSD will be created on this node"
        elif [[ ! -b "$OSD_DEVICE" ]]; then
            die "OSD device $OSD_DEVICE is not a block device"
        fi
    fi
    
    # Check network
    if ! ip route get "$CEPH_NETWORK" &> /dev/null; then
        log_warn "Network $CEPH_NETWORK not found"
    fi
    
    log_success "Prerequisites check passed"
}

#-------------------------------------------------------------------------------
# Ceph Installation
#-------------------------------------------------------------------------------
install_ceph() {
    log_info "Installing Ceph packages..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would install Ceph packages"
        return 0
    fi
    
    # Detect OS and install
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        
        case "$os_id" in
            rhel|centos|fedora)
                # Install EPEL and Ceph repo
                if [[ "$os_id" == "fedora" ]]; then
                    dnf install -y ceph-common || true
                else
                    # Add Ceph repository
                    cat > /etc/yum.repos.d/ceph.repo << 'EOF'
[Ceph-noarch]
name=Ceph noarch
baseurl=https://download.ceph.com/rpm-18.2.4/el9/$basearch
enabled=1
gpgcheck=0
priority=2
EOF
                    dnf install -y ceph-common
                fi
                ;;
            debian|ubuntu)
                # Add Ceph repository
                wget -q -O- https://download.ceph.com/keys/release.asc | apt-key add -
                echo "deb https://download.ceph.com/debian-18/quicksilver $(lsb_release -sc) main" > /etc/apt/sources.list.d/ceph.list
                apt-get update
                apt-get install -y ceph-common
                ;;
            *)
                log_warn "Unknown OS, attempting generic install"
                ;;
        esac
    fi
    
    # Verify installation
    if command -v ceph &> /dev/null; then
        log_success "Ceph installed: $(ceph version | grep -oP 'v\d+\.\d+')"
    else
        log_warn "Ceph not installed, using containerized Ceph"
    fi
}

#-------------------------------------------------------------------------------
# Generate Ceph Configuration
#-------------------------------------------------------------------------------
generate_ceph_config() {
    log_info "Generating Ceph configuration..."
    
    # Generate FSID
    if [[ -z "$CEPH_FSID" ]]; then
        CEPH_FSID=$(uuidgen)
    fi
    
    mkdir -p /etc/ceph
    
    # Generate ceph.conf
    cat > "$CEPH_CONF" << EOF
[global]
fsid = ${CEPH_FSID}
mon initial members = ${CEPH_MON_INITIAL_MEMBERS}
mon host = ${CEPH_PUBLIC_NETWORK}
public network = ${CEPH_PUBLIC_NETWORK}
cluster network = ${CEPH_NETWORK}

# Authentication
auth cluster required = cephx
auth service required = cephx
auth client required = cephx

# Performance
osd journal size = 5120
osd pool default size = ${CEPH_POOL_REPLICAS}
osd pool default min size = $((CEPH_POOL_REPLICAS - 1))
osd pool default pg num = ${CEPH_POOL_PG}
osd pool default pgp num = ${CEPH_POOL_PGP}

# Logging
log file = /var/log/ceph/ceph.log
mon cluster log file = /var/log/ceph/ceph.log
mon log level = debug

# Management
mgr modules = prometheus

[mon]
mon allow pool delete = true

[mgr]
mgr prometheus server addr = 0.0.0.0:9283
mgr prometheus export heap size = true

[osd]
osd memory target = 2147483648
osd max write size = 256
osd client message size cap = 2147483648
osd deep scrub stride = 131072
osd max push objects = 10
osd recovery max active = 3
osd recovery op priority = 2
EOF
    
    # Generate admin keyring
    if [[ ! -f "$CEPH_ADMIN_KEYRING" ]]; then
        ceph-authtool --create-keyring "$CEPH_ADMIN_KEYRING" --gen-key \
            --name client.admin --set-uid=0 \
            --cap mon 'allow *' \
            --cap osd 'allow *' \
            --cap mds 'allow *' \
            --cap mgr 'allow *'
        chmod 0644 "$CEPH_ADMIN_KEYRING"
    fi
    
    # Generate mon keyring
    local mon_keyring="/etc/ceph/ceph.mon.keyring"
    if [[ ! -f "$mon_keyring" ]]; then
        ceph-authtool --create-keyring "$mon_keyring" --gen-key \
            --name mon. --set-uid=0 \
            --cap mon 'allow *' \
            --cap osd 'allow *' \
            --cap mds 'allow *'
        chmod 0600 "$mon_keyring"
    fi
    
    log_success "Ceph configuration generated"
}

#-------------------------------------------------------------------------------
# Initialize Monitor
#-------------------------------------------------------------------------------
init_monitor() {
    log_info "Initializing Ceph monitor on $NODE_NAME..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would initialize monitor"
        return 0
    fi
    
    local mon_data_dir="/var/lib/ceph/mon/ceph-${NODE_NAME}"
    mkdir -p "$mon_data_dir"
    
    # Check if mon already exists
    if [[ -d "$mon_data_dir" ]] && [[ -f "$mon_data_dir/keyring" ]]; then
        log_info "Monitor already exists, starting..."
        ceph-mon -i "$NODE_NAME" --public-addr "${NODE_IP}:6789"
    else
        # Create new monitor
        ceph-mon --mkfs -i "$NODE_NAME" \
            --keyring "$CEPH_ADMIN_KEYRING" \
            --monmap /etc/ceph/monmap || true
        
        # Start monitor
        ceph-mon -i "$NODE_NAME" --public-addr "${NODE_IP}:6789"
    fi
    
    # Enable and start service (systemd)
    if command -v systemctl &> /dev/null; then
        cat > /etc/systemd/system/ceph-mon@.service << 'EOF'
[Unit]
Description=Ceph Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ceph-mon -i %i --public-addr %H:6789
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "ceph-mon@${NODE_NAME}"
        systemctl start "ceph-mon@${NODE_NAME}"
    fi
    
    log_success "Monitor initialized on $NODE_NAME"
}

#-------------------------------------------------------------------------------
# Initialize Manager
#-------------------------------------------------------------------------------
init_manager() {
    log_info "Initializing Ceph manager on $NODE_NAME..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would initialize manager"
        return 0
    fi
    
    local mgr_data_dir="/var/lib/ceph/mgr/ceph-${NODE_NAME}"
    mkdir -p "$mgr_data_dir"
    
    # Create keyring
    local mgr_keyring="$mgr_data_dir/keyring"
    ceph auth get-or-create mgr."$NODE_NAME" mon 'allow profile mgr' \
        osd 'allow *' mds 'allow *' > "$mgr_keyring"
    chmod 0600 "$mgr_keyring"
    
    # Start manager
    ceph-mgr -i "$NODE_NAME"
    
    # Enable and start systemd service
    if command -v systemctl &> /dev/null; then
        cat > /etc/systemd/system/ceph-mgr@.service << 'EOF'
[Unit]
Description=Ceph Manager
After=network.target ceph-mon@%i.service

[Service]
Type=simple
ExecStart=/usr/bin/ceph-mgr -i %i
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "ceph-mgr@${NODE_NAME}"
        systemctl start "ceph-mgr@${NODE_NAME}"
    fi
    
    log_success "Manager initialized on $NODE_NAME"
}

#-------------------------------------------------------------------------------
# Initialize OSD
#-------------------------------------------------------------------------------
init_osd() {
    log_info "Initializing Ceph OSD on $NODE_NAME with device $OSD_DEVICE..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would initialize OSD on $OSD_DEVICE"
        return 0
    fi
    
    if [[ -z "$OSD_DEVICE" ]]; then
        log_warn "No OSD device specified, skipping OSD creation"
        return 0
    fi
    
    # Check if OSD already exists
    local osd_id
    osd_id=$(ceph osd ls 2>/dev/null | tail -1 || echo "-1")
    
    if [[ "$osd_id" -ge 0 ]]; then
        log_info "OSDs already exist, checking status..."
        ceph osd tree
        return 0
    fi
    
    # Prepare OSD device using ceph-volume
    ceph-volume lvm prepare --data "$OSD_DEVICE" || {
        log_error "Failed to prepare OSD"
        return 1
    }
    
    # Activate OSD
    ceph-volume lvm activate all || {
        log_error "Failed to activate OSD"
        return 1
    }
    
    # Enable systemd service if using лvm
    if command -v systemctl &> /dev/null; then
        systemctl enable ceph-volume@target
    fi
    
    log_success "OSD initialized on $OSD_DEVICE"
    
    # Show OSD tree
    ceph osd tree
}

#-------------------------------------------------------------------------------
# Create Pool
#-------------------------------------------------------------------------------
create_pool() {
    local pool_name="$1"
    local pg_num="$2"
    local pgp_num="$3"
    local replicas="$4"
    
    log_info "Creating pool: $pool_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create pool $pool_name"
        return 0
    fi
    
    # Check if pool exists
    if ceph osd pool ls 2>/dev/null | grep -q "^${pool_name}$"; then
        log_info "Pool $pool_name already exists"
        return 0
    fi
    
    # Create pool
    ceph osd pool create "$pool_name" "$pg_num" "$pgp_num"
    
    # Set pool parameters
    ceph osd pool set "$pool_name" size "$replicas"
    ceph osd pool set "$pool_name" min_size $((replicas - 1))
    ceph osd pool set "$pool_name" crush_rule replicated_rule
    
    # Enable application
    ceph osd pool application enable "$pool_name" rbd
    
    # Initialize RBD
    rbd pool init "$pool_name"
    
    log_success "Pool $pool_name created"
}

#-------------------------------------------------------------------------------
# Setup CephFS
#-------------------------------------------------------------------------------
setup_cephfs() {
    log_info "Setting up CephFS..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would setup CephFS"
        return 0
    fi
    
    # Create metadata pool
    create_pool "cephfs_metadata" 64 64 3
    
    # Create data pool
    create_pool "cephfs_data" 64 64 3
    
    # Create filesystem
    if ! ceph fs ls 2>/dev/null | grep -q "cephfs"; then
        ceph fs new cephfs cephfs_metadata cephfs_data
    else
        log_info "CephFS already exists"
    fi
    
    # Start MDS
    local mds_data_dir="/var/lib/ceph/mds/ceph-${NODE_NAME}"
    mkdir -p "$mds_data_dir"
    
    # Create keyring
    ceph auth get-or-create mds."$NODE_NAME" \
        mon 'profile mds' \
        osd 'allow *' \
        mds 'allow' > "$mds_data_dir/keyring"
    chmod 0600 "$mds_data_dir/keyring"
    
    # Start MDS
    ceph-mds -i "$NODE_NAME"
    
    # Enable MDS service
    if command -v systemctl &> /dev/null; then
        cat > /etc/systemd/system/ceph-mds@.service << 'EOF'
[Unit]
Description=Ceph Metadata Server
After=network.target ceph-mon@.service

[Service]
Type=simple
ExecStart=/usr/bin/ceph-mds -i %i
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "ceph-mds@${NODE_NAME}"
        systemctl start "ceph-mds@${NODE_NAME}"
    fi
    
    log_success "CephFS setup complete"
}

#-------------------------------------------------------------------------------
# Podman Volume Integration
#-------------------------------------------------------------------------------
configure_podman_integration() {
    log_info "Configuring Podman integration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would configure Podman integration"
        return 0
    fi
    
    # Create Ceph RBD helper script
    cat > /usr/local/bin/podman-ceph-rbd << 'EOF'
#!/bin/bash
# Podman volume plugin for Ceph RBD
# Usage: podman volume create --driver ceph-rbd volume_name

set -euo pipefail

VOLUME_NAME="${1:-}"
POOL_NAME="${CEPH_POOL_NAME:-podman-volumes}"

if [[ -z "$VOLUME_NAME" ]]; then
    echo "Usage: $0 <volume_name> [pool_name]"
    exit 1
fi

# Create RBD image
rbd create "${POOL_NAME}/${VOLUME_NAME}" --size 10G

# Map the image (requires root)
if command -v rbd-nbd &> /dev/null; then
    rbd-nbd map "${POOL_NAME}/${VOLUME_NAME}" --id admin
fi

echo "Volume ${VOLUME_NAME} created in pool ${POOL_NAME}"
EOF

    chmod +x /usr/local/bin/podman-ceph-rbd
    
    log_success "Podman integration configured"
}

#-------------------------------------------------------------------------------
# Verify Cluster Health
#-------------------------------------------------------------------------------
verify_cluster() {
    log_info "Verifying cluster health..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would verify cluster"
        return 0
    fi
    
    # Wait for cluster to be healthy
    local attempts=0
    local max_attempts=30
    
    while [[ $attempts -lt $max_attempts ]]; do
        local health
        health=$(ceph health 2>/dev/null || echo "UNKNOWN")
        
        case "$health" in
            HEALTH_OK)
                log_success "Cluster is healthy"
                break
                ;;
            HEALTH_WARN)
                log_warn "Cluster health: $health"
                break
                ;;
            HEALTH_ERR)
                log_error "Cluster health: $health"
                ((attempts++))
                sleep 5
                ;;
            *)
                log_warn "Cluster status: $health"
                ((attempts++))
                sleep 5
                ;;
        esac
    done
    
    if [[ $attempts -ge $max_attempts ]]; then
        log_error "Cluster failed to become healthy"
        return 1
    fi
    
    # Show cluster status
    ceph -s
    ceph osd tree
    
    log_success "Cluster verification complete"
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - Ceph Storage Cluster Setup for Podman

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    --node-name NAME          Node name (default: $(hostname))
    --node-ip IP              Node IP address (default: auto-detect)
    --node-role ROLE          Node role: all, mon, mgr, osd, mds (default: all)
    --osd-device DEVICE       Block device for OSD (e.g., /dev/sdb)
    --cluster-name NAME       Ceph cluster name (default: ceph)
    --network NETWORK         Ceph cluster network (default: 10.200.0.0/24)
    --pool-name NAME          Pool name for podman volumes (default: podman-volumes)
    --pool-pg NUM             Number of placement groups (default: 128)
    --pool-replicas NUM       Number of replicas (default: 3)
    --setup-cephfs            Setup CephFS for shared filesystem
    --skip-pool               Skip pool creation
    --force                   Force setup even with warnings
    --dry-run                 Show what would be done without executing
    -h, --help                Show this help message
    -v, --version             Show version information

ENVIRONMENT VARIABLES:
    NODE_NAME                  Node hostname
    NODE_IP                    Node IP address
    NODE_ROLE                  Node role
    OSD_DEVICE                 Block device for OSD
    CEPH_POOL_NAME             Pool name
    CEPH_POOL_PG               Placement groups
    CEPH_POOL_REPLICAS         Number of replicas
    LOG_DIR                    Log directory

EXAMPLES:
    # Initialize full node (monitor + manager + OSD)
    ${SCRIPT_NAME} --node-name node1 --node-ip 10.200.0.11 --osd-device /dev/sdb

    # Initialize monitor only
    ${SCRIPT_NAME} --node-role mon --node-name node1 --node-ip 10.200.0.11

    # Initialize OSD only
    ${SCRIPT_NAME} --node-role osd --osd-device /dev/sdb

    # Dry run
    ${SCRIPT_NAME} --dry-run --node-name node1

EXIT CODES:
    0   Success
    1   General error
    2   Prerequisites error
    3   Setup failed

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --node-name)
                NODE_NAME="$2"
                shift 2
                ;;
            --node-ip)
                NODE_IP="$2"
                shift 2
                ;;
            --node-role)
                NODE_ROLE="$2"
                shift 2
                ;;
            --osd-device)
                OSD_DEVICE="$2"
                shift 2
                ;;
            --cluster-name)
                CEPH_CLUSTER_NAME="$2"
                shift 2
                ;;
            --network)
                CEPH_NETWORK="$2"
                CEPH_PUBLIC_NETWORK="$2"
                shift 2
                ;;
            --pool-name)
                CEPH_POOL_NAME="$2"
                shift 2
                ;;
            --pool-pg)
                CEPH_POOL_PG="$2"
                shift 2
                ;;
            --pool-replicas)
                CEPH_POOL_REPLICAS="$2"
                shift 2
                ;;
            --setup-cephfs)
                SETUP_CEPHFS="true"
                shift
                ;;
            --skip-pool)
                SKIP_CREATE_POOL="true"
                shift
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} version ${VERSION}"
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Main Setup
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    log_info "========================================"
    log_info "${SCRIPT_NAME} v${VERSION}"
    log_info "========================================"
    log_info "Node: $NODE_NAME ($NODE_IP)"
    log_info "Role: $NODE_ROLE"
    log_info "========================================"
    
    acquire_lock
    check_prerequisites
    
    # Installation phase
    log_info "=== Phase 1: Installation ==="
    install_ceph
    
    # Configuration phase
    log_info "=== Phase 2: Configuration ==="
    generate_ceph_config
    
    # Role-based initialization
    log_info "=== Phase 3: Initialization ==="
    
    if [[ "$NODE_ROLE" == *"mon"* ]] || [[ "$NODE_ROLE" == "all" ]]; then
        init_monitor
    fi
    
    if [[ "$NODE_ROLE" == *"mgr"* ]] || [[ "$NODE_ROLE" == "all" ]]; then
        init_manager
    fi
    
    if [[ "$NODE_ROLE" == *"osd"* ]] || [[ "$NODE_ROLE" == "all" ]]; then
        init_osd
    fi
    
    if [[ "$NODE_ROLE" == *"mds"* ]] || [[ "$NODE_ROLE" == "all" ]] && [[ "$SETUP_CEPHFS" == "true" ]]; then
        setup_cephfs
    fi
    
    # Pool creation (on any mon node)
    if [[ "$SKIP_CREATE_POOL" != "true" ]]; then
        log_info "=== Phase 4: Pool Creation ==="
        create_pool "$CEPH_POOL_NAME" "$CEPH_POOL_PG" "$CEPH_POOL_PGP" "$CEPH_POOL_REPLICAS"
    fi
    
    # Podman integration
    log_info "=== Phase 5: Podman Integration ==="
    configure_podman_integration
    
    # Verification
    log_info "=== Phase 6: Verification ==="
    verify_cluster
    
    log_success "Ceph setup completed successfully!"
    
    cat << 'SUMMARY'

========================================
Ceph Cluster Setup Complete
========================================

Next Steps:
1. Repeat setup on other nodes with appropriate roles
2. Verify cluster health: ceph -s
3. Create additional pools if needed
4. Configure Podman to use Ceph volumes:
   podman volume create --driver ceph-rbd myvolume

Useful Commands:
  ceph -s                    # Show cluster status
  ceph osd tree              # Show OSD tree
  ceph pg dump              # Show placement groups
  rbd ls <pool>             # List RBD images

SUMMARY
}

main "$@"
