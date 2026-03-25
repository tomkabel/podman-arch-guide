#!/usr/bin/env bash
#===============================================================================
# network-mesh.sh - WireGuard Mesh Network Setup for Multi-Node Podman
#===============================================================================
# Description: Generates WireGuard configs for each node, distributes public
#              keys, establishes full mesh connectivity, tests mesh health,
#              and handles node addition/removal.
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
readonly LOG_DIR="${LOG_DIR:-/var/log/podman-mesh}"
readonly LOG_FILE="${LOG_DIR}/mesh-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

#-------------------------------------------------------------------------------
# Mesh Configuration
#-------------------------------------------------------------------------------
MESH_NAME="${MESH_NAME:-podman-mesh}"
NETWORK_CIDR="${NETWORK_CIDR:-10.200.0.0/16}"
WG_PORT="${WG_PORT:-51820}"
CONFIG_DIR="${CONFIG_DIR:-/etc/wireguard/${MESH_NAME}}"
NODES_FILE="${NODES_FILE:-${CONFIG_DIR}/nodes.conf}"
PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-${CONFIG_DIR}/privatekey}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-${CONFIG_DIR}/publickey}"
DRY_RUN="${DRY_RUN:-false}"

# Node configuration
declare -A NODES
CURRENT_NODE="${CURRENT_NODE:-$(hostname -s)}"

#-------------------------------------------------------------------------------
# Colors for terminal output
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
        MESH)    echo -e "${CYAN}[$timestamp] [MESH] $message${NC}" ;;
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

log_info()  { log "INFO" "$*"; }
log_warn()  { log "WARN" "$*"; }
log_error() { log "ERROR" "$*"; }
log_success(){ log "SUCCESS" "$*"; }
log_mesh()  { log "MESH" "$*"; }

#-------------------------------------------------------------------------------
# Error Handling
#-------------------------------------------------------------------------------
die() {
    log_error "$@"
    cleanup
    exit 1
}

cleanup() {
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

trap_cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Mesh operation failed with exit code $exit_code"
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
            die "Another mesh operation is in progress (PID: ${pid})"
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Acquired mesh lock"
}

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_environment() {
    log_info "Validating environment..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
    
    # Check for WireGuard
    if ! command -v wg &> /dev/null; then
        die "WireGuard (wg) is not installed. Install with: apt install wireguard-tools"
    fi
    
    if ! command -v wg-quick &> /dev/null; then
        die "wg-quick is not installed"
    fi
    
    # Create config directory
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    
    log_success "Environment validation passed"
}

#-------------------------------------------------------------------------------
# IP Address Management
#-------------------------------------------------------------------------------
get_node_ip() {
    local node_name="$1"
    local node_index
    
    # Generate deterministic IP based on node name hash
    node_index=$(echo -n "$node_name" | cksum | cut -d' ' -f1)
    node_index=$((node_index % 254 + 1))
    
    # Extract network base
    local network_base
    network_base=$(echo "$NETWORK_CIDR" | cut -d'/' -f1 | sed 's/\.0$//')
    
    echo "${network_base}.${node_index}"
}

#-------------------------------------------------------------------------------
# Key Management
#-------------------------------------------------------------------------------
generate_keys() {
    local node_name="$1"
    local node_config_dir="${CONFIG_DIR}/nodes/${node_name}"
    
    if [[ -f "${node_config_dir}/privatekey" ]] && [[ -f "${node_config_dir}/publickey" ]]; then
        log_info "Keys already exist for ${node_name}"
        return 0
    fi
    
    log_mesh "Generating WireGuard keys for ${node_name}..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would generate keys for ${node_name}"
        return 0
    fi
    
    mkdir -p "$node_config_dir"
    chmod 700 "$node_config_dir"
    
    # Generate private key
    wg genkey | tee "${node_config_dir}/privatekey" > /dev/null
    chmod 600 "${node_config_dir}/privatekey"
    
    # Generate public key
    wg pubkey < "${node_config_dir}/privatekey" > "${node_config_dir}/publickey"
    chmod 644 "${node_config_dir}/publickey"
    
    log_success "Keys generated for ${node_name}"
}

get_public_key() {
    local node_name="$1"
    local key_file="${CONFIG_DIR}/nodes/${node_name}/publickey"
    
    if [[ -f "$key_file" ]]; then
        cat "$key_file"
    else
        echo ""
    fi
}

get_private_key() {
    local node_name="$1"
    local key_file="${CONFIG_DIR}/nodes/${node_name}/privatekey"
    
    if [[ -f "$key_file" ]]; then
        cat "$key_file"
    else
        echo ""
    fi
}

#-------------------------------------------------------------------------------
# Node Management
#-------------------------------------------------------------------------------
load_nodes() {
    if [[ -f "$NODES_FILE" ]]; then
        log_info "Loading node configuration from ${NODES_FILE}..."
        
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            [[ "$key" =~ ^# ]] && continue
            
            case "$key" in
                node.*.name)
                    local node_id
                    node_id=$(echo "$key" | cut -d'.' -f2)
                    NODES["${node_id}_name"]="$value"
                    ;;
                node.*.endpoint)
                    local node_id
                    node_id=$(echo "$key" | cut -d'.' -f2)
                    NODES["${node_id}_endpoint"]="$value"
                    ;;
                node.*.ip)
                    local node_id
                    node_id=$(echo "$key" | cut -d'.' -f2)
                    NODES["${node_id}_ip"]="$value"
                    ;;
            esac
        done < "$NODES_FILE"
        
        log_info "Loaded ${#NODES[@]} node configurations"
    fi
}

save_node() {
    local node_id="$1"
    local node_name="$2"
    local node_endpoint="$3"
    local node_ip="$4"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would save node ${node_name}"
        return 0
    fi
    
    # Create nodes file if it doesn't exist
    if [[ ! -f "$NODES_FILE" ]]; then
        cat > "$NODES_FILE" << EOF
# Podman Mesh Network Node Configuration
# Generated: $(date -Iseconds)
# Mesh: ${MESH_NAME}

EOF
    fi
    
    # Remove existing entry for this node
    sed -i "/^node\\.${node_id}\\./d" "$NODES_FILE"
    
    # Add new entry
    cat >> "$NODES_FILE" << EOF
node.${node_id}.name=${node_name}
node.${node_id}.endpoint=${node_endpoint}
node.${node_id}.ip=${node_ip}
EOF
    
    log_info "Node ${node_name} saved to configuration"
}

add_node() {
    local node_name="$1"
    local node_endpoint="$2"
    local node_ip="${3:-}"
    
    log_mesh "Adding node: ${node_name}"
    
    # Generate node IP if not provided
    if [[ -z "$node_ip" ]]; then
        node_ip=$(get_node_ip "$node_name")
    fi
    
    # Generate keys
    generate_keys "$node_name"
    
    # Get next node ID
    local node_id=0
    if [[ -f "$NODES_FILE" ]]; then
        node_id=$(grep -c "^node\\." "$NODES_FILE" 2>/dev/null || echo "0")
    fi
    
    # Save node configuration
    save_node "$node_id" "$node_name" "$node_endpoint" "$node_ip"
    
    log_success "Node ${node_name} added with IP ${node_ip}"
    
    # Generate config for this node
    generate_node_config "$node_name" "$node_ip"
}

remove_node() {
    local node_name="$1"
    
    log_mesh "Removing node: ${node_name}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would remove node ${node_name}"
        return 0
    fi
    
    # Find and remove from nodes file
    local node_id
    node_id=$(grep "node\\..*\\.name=${node_name}$" "$NODES_FILE" | head -1 | cut -d'.' -f2 || true)
    
    if [[ -n "$node_id" ]]; then
        sed -i "/^node\\.${node_id}\\./d" "$NODES_FILE"
    fi
    
    # Remove node configuration directory
    if [[ -d "${CONFIG_DIR}/nodes/${node_name}" ]]; then
        rm -rf "${CONFIG_DIR}/nodes/${node_name}"
    fi
    
    # Remove node config file
    rm -f "${CONFIG_DIR}/${MESH_NAME}-${node_name}.conf"
    
    log_success "Node ${node_name} removed"
}

#-------------------------------------------------------------------------------
# Configuration Generation
#-------------------------------------------------------------------------------
generate_node_config() {
    local node_name="$1"
    local node_ip="$2"
    
    log_mesh "Generating WireGuard config for ${node_name}..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would generate config for ${node_name}"
        return 0
    fi
    
    local private_key
    private_key=$(get_private_key "$node_name")
    
    if [[ -z "$private_key" ]]; then
        die "Private key not found for ${node_name}"
    fi
    
    local config_file="${CONFIG_DIR}/${MESH_NAME}-${node_name}.conf"
    
    cat > "$config_file" << EOF
# WireGuard Configuration for ${node_name}
# Mesh: ${MESH_NAME}
# Generated: $(date -Iseconds)

[Interface]
PrivateKey = ${private_key}
Address = ${node_ip}/32
ListenPort = ${WG_PORT}
MTU = 1420

# Traffic rules for Podman mesh
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE

EOF

    # Add peer entries for all other nodes
    local node_count=0
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue
        
        if [[ "$key" =~ ^node\\.([0-9]+)\\.name$ ]]; then
            local peer_id="${BASH_REMATCH[1]}"
            local peer_name="$value"
            
            # Skip self
            if [[ "$peer_name" == "$node_name" ]]; then
                continue
            fi
            
            local peer_endpoint
            peer_endpoint=$(grep "^node\\.${peer_id}\\.endpoint=" "$NODES_FILE" | cut -d'=' -f2 || true)
            local peer_ip
            peer_ip=$(grep "^node\\.${peer_id}\\.ip=" "$NODES_FILE" | cut -d'=' -f2 || true)
            local peer_pubkey
            peer_pubkey=$(get_public_key "$peer_name")
            
            if [[ -z "$peer_pubkey" ]]; then
                log_warn "Public key not found for peer ${peer_name}, skipping"
                continue
            fi
            
            cat >> "$config_file" << EOF
[Peer]
# ${peer_name}
PublicKey = ${peer_pubkey}
Endpoint = ${peer_endpoint}:${WG_PORT}
AllowedIPs = ${peer_ip}/32,${NETWORK_CIDR}
PersistentKeepalive = 25

EOF
            ((node_count++))
        fi
    done < "$NODES_FILE"
    
    chmod 600 "$config_file"
    log_success "Configuration generated for ${node_name} with ${node_count} peers"
}

generate_all_configs() {
    log_mesh "Generating configurations for all nodes..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would generate all configs"
        return 0
    fi
    
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue
        
        if [[ "$key" =~ ^node\\.([0-9]+)\\.name$ ]]; then
            local node_name="$value"
            local node_id="${BASH_REMATCH[1]}"
            local node_ip
            node_ip=$(grep "^node\\.${node_id}\\.ip=" "$NODES_FILE" | cut -d'=' -f2 || true)
            
            generate_node_config "$node_name" "$node_ip"
        fi
    done < "$NODES_FILE"
    
    log_success "All configurations generated"
}

#-------------------------------------------------------------------------------
# Mesh Operations
#-------------------------------------------------------------------------------
start_mesh() {
    log_mesh "Starting WireGuard mesh..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would start mesh interface"
        return 0
    fi
    
    # Find and start interface for current node
    local current_config="${CONFIG_DIR}/${MESH_NAME}-${CURRENT_NODE}.conf"
    
    if [[ ! -f "$current_config" ]]; then
        die "Configuration not found for current node: ${CURRENT_NODE}"
    fi
    
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    # Create symlink for wg-quick
    local wg_interface="${MESH_NAME}-${CURRENT_NODE}"
    local wg_config="/etc/wireguard/${wg_interface}.conf"
    
    ln -sf "$current_config" "$wg_config"
    
    # Start interface
    if wg-quick up "$wg_interface" 2>/dev/null; then
        log_success "Mesh interface ${wg_interface} started"
    else
        log_warn "Interface may already be running, trying restart..."
        wg-quick down "$wg_interface" 2>/dev/null || true
        wg-quick up "$wg_interface"
    fi
    
    # Enable at boot
    systemctl enable "wg-quick@${wg_interface}" 2>/dev/null || true
}

stop_mesh() {
    log_mesh "Stopping WireGuard mesh..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would stop mesh interface"
        return 0
    fi
    
    local wg_interface="${MESH_NAME}-${CURRENT_NODE}"
    
    if wg-quick down "$wg_interface" 2>/dev/null; then
        log_success "Mesh interface ${wg_interface} stopped"
    else
        log_warn "Interface ${wg_interface} was not running"
    fi
}

#-------------------------------------------------------------------------------
# Health Checks
#-------------------------------------------------------------------------------
test_mesh() {
    log_mesh "Testing mesh connectivity..."
    
    local passed=0
    local failed=0
    
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue
        
        if [[ "$key" =~ ^node\\.([0-9]+)\\.name$ ]]; then
            local peer_name="$value"
            local peer_id="${BASH_REMATCH[1]}"
            local peer_ip
            peer_ip=$(grep "^node\\.${peer_id}\\.ip=" "$NODES_FILE" | cut -d'=' -f2 || true)
            
            # Skip self
            if [[ "$peer_name" == "$CURRENT_NODE" ]]; then
                continue
            fi
            
            log_info "Testing connectivity to ${peer_name} (${peer_ip})..."
            
            if ping -c 3 -W 5 "$peer_ip" > /dev/null 2>&1; then
                log_success "${peer_name} is reachable"
                ((passed++))
            else
                log_error "${peer_name} is not reachable"
                ((failed++))
            fi
        fi
    done < "$NODES_FILE"
    
    log_mesh "Mesh test complete: ${passed} passed, ${failed} failed"
    
    return $failed
}

show_status() {
    log_mesh "Mesh Network Status"
    log_mesh "==================="
    
    echo ""
    echo "Nodes:"
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue
        
        if [[ "$key" =~ ^node\\.([0-9]+)\\.name$ ]]; then
            local peer_id="${BASH_REMATCH[1]}"
            local peer_name="$value"
            local peer_ip
            peer_ip=$(grep "^node\\.${peer_id}\\.ip=" "$NODES_FILE" | cut -d'=' -f2 || true)
            
            if [[ "$peer_name" == "$CURRENT_NODE" ]]; then
                echo "  * ${peer_name} (${peer_ip}) [CURRENT]"
            else
                echo "    ${peer_name} (${peer_ip})"
            fi
        fi
    done < "$NODES_FILE"
    
    echo ""
    echo "WireGuard Status:"
    wg show "${MESH_NAME}-${CURRENT_NODE}" 2>/dev/null || echo "  Interface not running"
}

#-------------------------------------------------------------------------------
# Distribution
#-------------------------------------------------------------------------------
distribute_keys() {
    log_mesh "Distributing public keys to all nodes..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would distribute keys"
        return 0
    fi
    
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue
        
        if [[ "$key" =~ ^node\\.([0-9]+)\\.name$ ]]; then
            local peer_name="$value"
            
            # Skip self
            if [[ "$peer_name" == "$CURRENT_NODE" ]]; then
                continue
            fi
            
            local peer_endpoint
            peer_endpoint=$(grep "^node\\.${BASH_REMATCH[1]}\\.endpoint=" "$NODES_FILE" | cut -d'=' -f2 || true)
            
            log_info "Distributing keys to ${peer_name}..."
            
            # Distribute via SSH
            if command -v ssh &> /dev/null; then
                # Copy public keys
                scp -r "${CONFIG_DIR}/nodes" "root@${peer_endpoint}:${CONFIG_DIR}/" 2>/dev/null || \
                    log_warn "Could not distribute keys to ${peer_name}"
            else
                log_warn "SSH not available, manual key distribution required"
            fi
        fi
    done < "$NODES_FILE"
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - WireGuard Mesh Network Setup

USAGE:
    ${SCRIPT_NAME} COMMAND [OPTIONS]

COMMANDS:
    init                        Initialize mesh network
    add-node NAME ENDPOINT [IP] Add a new node to the mesh
    remove-node NAME            Remove a node from the mesh
    generate                    Generate all node configurations
    start                       Start the mesh interface
    stop                        Stop the mesh interface
    restart                     Restart the mesh interface
    test                        Test mesh connectivity
    status                      Show mesh status
    distribute                  Distribute keys to all nodes

OPTIONS:
    -n, --name NAME             Mesh network name (default: podman-mesh)
    -c, --cidr CIDR             Network CIDR (default: 10.200.0.0/16)
    -p, --port PORT             WireGuard port (default: 51820)
    -d, --config-dir PATH       Configuration directory
    --current-node NAME         Current node name (default: hostname)
    --dry-run                   Show what would be done without executing
    -h, --help                  Show this help message
    -v, --version               Show version information

EXAMPLES:
    # Initialize mesh
    ${SCRIPT_NAME} init

    # Add nodes
    ${SCRIPT_NAME} add-node server1 192.168.1.10
    ${SCRIPT_NAME} add-node server2 192.168.1.11

    # Generate and start mesh
    ${SCRIPT_NAME} generate
    ${SCRIPT_NAME} start

    # Test connectivity
    ${SCRIPT_NAME} test

    # Remove node
    ${SCRIPT_NAME} remove-node server2

DESCRIPTION:
    Sets up a full-mesh WireGuard VPN network for multi-node Podman clusters.
    Each node connects to every other node, providing secure overlay networking.

NETWORK ARCHITECTURE:
    - Full mesh: Every node connects to every other node
    - CIDR: Configurable private network range
    - Port: 51820/UDP (configurable)
    - Key exchange: Manual or SSH-based distribution

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    COMMAND=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            init|add-node|remove-node|generate|start|stop|restart|test|status|distribute)
                COMMAND="$1"
                shift
                ;;
            -n|--name)
                MESH_NAME="$2"
                shift 2
                ;;
            -c|--cidr)
                NETWORK_CIDR="$2"
                shift 2
                ;;
            -p|--port)
                WG_PORT="$2"
                shift 2
                ;;
            -d|--config-dir)
                CONFIG_DIR="$2"
                shift 2
                ;;
            --current-node)
                CURRENT_NODE="$2"
                shift 2
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
                # Store remaining args for commands
                if [[ -z "$COMMAND" ]]; then
                    COMMAND="$1"
                else
                    COMMAND_ARGS+=("$1")
                fi
                shift
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    acquire_lock
    validate_environment
    load_nodes
    
    case "$COMMAND" in
        init)
            log_info "Initializing mesh: ${MESH_NAME}"
            mkdir -p "${CONFIG_DIR}/nodes"
            log_success "Mesh initialized. Add nodes with: ${SCRIPT_NAME} add-node"
            ;;
        add-node)
            if [[ ${#COMMAND_ARGS[@]} -lt 2 ]]; then
                die "Usage: ${SCRIPT_NAME} add-node NAME ENDPOINT [IP]"
            fi
            add_node "${COMMAND_ARGS[0]}" "${COMMAND_ARGS[1]}" "${COMMAND_ARGS[2]:-}"
            ;;
        remove-node)
            if [[ ${#COMMAND_ARGS[@]} -lt 1 ]]; then
                die "Usage: ${SCRIPT_NAME} remove-node NAME"
            fi
            remove_node "${COMMAND_ARGS[0]}"
            ;;
        generate)
            generate_all_configs
            ;;
        start)
            start_mesh
            ;;
        stop)
            stop_mesh
            ;;
        restart)
            stop_mesh
            sleep 2
            start_mesh
            ;;
        test)
            test_mesh
            ;;
        status)
            show_status
            ;;
        distribute)
            distribute_keys
            ;;
        *)
            usage
            exit 1
            ;;
    esac
    
    exit 0
}

main "$@"
