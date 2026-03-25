#!/usr/bin/env bash
#===============================================================================
# rollback.sh - Enterprise Podman Rollback Script
#===============================================================================
# Description: Performs graceful rollback to previous working version with
#              connection draining, health validation, and emergency options.
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
readonly LOG_DIR="${LOG_DIR:-/var/log/podman-deploy}"
readonly LOG_FILE="${LOG_DIR}/rollback-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
readonly ROLLBACK_LABEL="previous-version"
readonly DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-60}"
readonly HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-180}"

#-------------------------------------------------------------------------------
# Rollback Configuration
#-------------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
FORCE_ROLLBACK="${FORCE_ROLLBACK:-false}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_DRAIN="${SKIP_DRAIN:-false}"
KEEP_CURRENT="${KEEP_CURRENT:-false}"

#-------------------------------------------------------------------------------
# Colors for terminal output
#-------------------------------------------------------------------------------
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m' # No Color

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
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }

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
        log_error "Rollback failed with exit code $exit_code"
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
            die "Another rollback is in progress (PID: $pid)"
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Acquired rollback lock"
}

#-------------------------------------------------------------------------------
# Version Detection
#-------------------------------------------------------------------------------
find_previous_version() {
    log_info "Searching for previous version..."
    
    # Method 1: Look for containers with rollback label
    local previous_containers
    previous_containers=$(podman ps -a --filter "label=${ROLLBACK_LABEL}=true" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    if [[ -n "$previous_containers" ]]; then
        log_info "Found previous version containers with rollback label"
        echo "$previous_containers"
        return 0
    fi
    
    # Method 2: Look for stopped containers with same project label
    log_info "No labeled containers found, searching stopped containers..."
    previous_containers=$(podman ps -a --filter "label=project=${PROJECT_NAME}" --filter "status=exited" --format '{{.Names}}' 2>/dev/null | head -n 10 || true)
    
    if [[ -n "$previous_containers" ]]; then
        log_info "Found stopped containers that may be previous version"
        echo "$previous_containers"
        return 0
    fi
    
    # Method 3: Check for backed up container configs
    local backup_dir="/var/lib/podman/backups/${PROJECT_NAME}"
    if [[ -d "$backup_dir" ]]; then
        local latest_backup
        latest_backup=$(ls -t "$backup_dir"/*.json 2>/dev/null | head -n1 || true)
        if [[ -n "$latest_backup" ]]; then
            log_info "Found backup configuration: $latest_backup"
            echo "BACKUP:$latest_backup"
            return 0
        fi
    fi
    
    return 1
}

get_container_image() {
    local container_name="$1"
    podman inspect --format='{{.ImageName}}' "$container_name" 2>/dev/null || \
        podman inspect --format='{{.Image}}' "$container_name" 2>/dev/null || \
        echo ""
}

get_container_config() {
    local container_name="$1"
    podman inspect "$container_name" 2>/dev/null | jq -r '.[0] // empty' 2>/dev/null || echo ""
}

#-------------------------------------------------------------------------------
# Connection Draining
#-------------------------------------------------------------------------------
drain_connections() {
    local container_name="$1"
    local timeout="${2:-$DRAIN_TIMEOUT}"
    
    if [[ "$SKIP_DRAIN" == "true" ]] || [[ "$FORCE_ROLLBACK" == "true" ]]; then
        log_warn "Skipping connection draining"
        return 0
    fi
    
    log_info "Draining connections from $container_name (${timeout}s timeout)..."
    
    # Signal container to stop accepting new connections
    # Common patterns: SIGTERM for graceful shutdown
    if ! podman kill --signal SIGTERM "$container_name" 2>/dev/null; then
        log_warn "Could not send SIGTERM to $container_name"
    fi
    
    # Wait for connections to drain
    local elapsed=0
    local interval=5
    
    while [[ $elapsed -lt $timeout ]]; do
        # Check active connections (if ss/netstat available in container)
        local conn_count
        conn_count=$(podman exec "$container_name" ss -tan 2>/dev/null | grep -c ESTAB || echo "0")
        
        if [[ "$conn_count" -eq 0 ]]; then
            log_success "All connections drained from $container_name"
            return 0
        fi
        
        log_info "Waiting for $conn_count connections to close..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_warn "Connection drain timeout reached"
    return 1
}

#-------------------------------------------------------------------------------
# Health Check
#-------------------------------------------------------------------------------
wait_for_healthy() {
    local container_name="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"
    local elapsed=0
    local interval=5
    
    log_info "Waiting for $container_name to become healthy..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(podman inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")
        
        case "$status" in
            running)
                local health_status
                health_status=$(podman inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
                
                if [[ "$health_status" == "healthy" ]] || [[ "$health_status" == "none" ]]; then
                    log_success "Container $container_name is healthy"
                    return 0
                fi
                ;;
            exited|dead)
                log_error "Container $container_name has exited"
                return 1
                ;;
        esac
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Health check timeout for $container_name"
    return 1
}

health_check_all() {
    local containers="$1"
    local failed=0
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        if ! wait_for_healthy "$container"; then
            ((failed++))
        fi
    done <<< "$containers"
    
    return $failed
}

#-------------------------------------------------------------------------------
# Load Balancer/Proxy Updates
#-------------------------------------------------------------------------------
update_proxy() {
    local action="$1"  # rollback or restore
    local container="${2:-}"
    
    log_info "Updating load balancer/proxy configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would update proxy for $action"
        return 0
    fi
    
    # Check for common proxy configurations
    local proxy_updated=false
    
    # Nginx upstream update
    if [[ -d "/etc/nginx/conf.d" ]]; then
        log_info "Detected nginx configuration"
        # Could update upstream here if needed
        if nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null; then
            log_success "Nginx reloaded"
            proxy_updated=true
        fi
    fi
    
    # HAProxy update
    if [[ -f "/etc/haproxy/haproxy.cfg" ]]; then
        log_info "Detected HAProxy configuration"
        if haproxy -c -f /etc/haproxy/haproxy.cfg 2>/dev/null && systemctl reload haproxy 2>/dev/null; then
            log_success "HAProxy reloaded"
            proxy_updated=true
        fi
    fi
    
    # Podman-compose proxy labels
    if ! $proxy_updated; then
        log_info "No external proxy detected, using podman labels"
    fi
}

#-------------------------------------------------------------------------------
# Rollback Execution
#-------------------------------------------------------------------------------
rollback_containers() {
    local previous_containers="$1"
    local current_containers
    current_containers=$(podman ps --filter "label=project=${PROJECT_NAME}" --filter "status=running" --format '{{.Names}}' 2>/dev/null || true)
    
    log_info "Starting rollback process..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would rollback the following:"
        echo "$previous_containers" | while read -r c; do
            [[ -n "$c" ]] && log_info "  - Restart: $c"
        done
        return 0
    fi
    
    # Step 1: Drain connections from current containers
    if [[ -n "$current_containers" ]]; then
        log_info "Draining connections from current containers..."
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            drain_connections "$container" || true
        done <<< "$current_containers"
    fi
    
    # Step 2: Stop current containers (unless keeping them)
    if [[ "$KEEP_CURRENT" != "true" ]]; then
        log_info "Stopping current containers..."
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            
            local timeout=30
            if [[ "$FORCE_ROLLBACK" == "true" ]]; then
                timeout=5
            fi
            
            log_info "Stopping $container..."
            if ! podman stop -t "$timeout" "$container" 2>/dev/null; then
                if [[ "$FORCE_ROLLBACK" == "true" ]]; then
                    log_warn "Force killing $container"
                    podman kill "$container" 2>/dev/null || true
                fi
            fi
            
            # Rename for potential later analysis
            podman rename "$container" "${container}-failed-$(date +%s)" 2>/dev/null || true
        done <<< "$current_containers"
    fi
    
    # Step 3: Start previous version containers
    log_info "Starting previous version containers..."
    local started_containers=""
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        
        log_info "Starting container: $container"
        
        if podman start "$container" 2>/dev/null; then
            started_containers="${started_containers}${container}\n"
            # Remove rollback label as it's now current
            podman container update --label="${ROLLBACK_LABEL}=false" "$container" 2>/dev/null || true
        else
            # Try to recreate from saved config
            local image
            image=$(get_container_image "$container")
            
            if [[ -n "$image" ]]; then
                log_info "Attempting to recreate $container from image $image..."
                
                # Extract original config and recreate
                local old_name="${container}-old"
                podman rename "$container" "$old_name" 2>/dev/null || true
                
                # Start with basic run (config would be more complex in real scenario)
                if podman run -d --name "$container" --label "project=${PROJECT_NAME}" "$image" 2>/dev/null; then
                    started_containers="${started_containers}${container}\n"
                else
                    log_error "Failed to start $container"
                fi
            fi
        fi
    done <<< "$previous_containers"
    
    # Step 4: Health check
    if [[ -n "$started_containers" ]]; then
        log_info "Performing health checks on rolled back containers..."
        if ! health_check_all "$started_containers"; then
            if [[ "$FORCE_ROLLBACK" != "true" ]]; then
                die "Health check failed after rollback"
            else
                log_warn "Health check failed but continuing due to --force"
            fi
        fi
    fi
    
    # Step 5: Update proxy
    update_proxy "rollback"
    
    # Step 6: Cleanup old failed containers
    if [[ "$KEEP_CURRENT" != "true" ]]; then
        log_info "Cleaning up failed containers..."
        podman ps -a --filter "name=.*-failed-[0-9]+" --format '{{.Names}}' 2>/dev/null | while read -r c; do
            [[ -n "$c" ]] && podman rm "$c" 2>/dev/null || true
        done
    fi
    
    log_success "Rollback completed successfully!"
}

rollback_from_backup() {
    local backup_file="$1"
    
    log_info "Restoring from backup: $backup_file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would restore from $backup_file"
        return 0
    fi
    
    # Parse backup and recreate containers
    if [[ -f "$backup_file" ]]; then
        # This would contain logic to restore from backup JSON
        log_info "Backup restoration would be implemented here"
        log_warn "Backup-based rollback not fully implemented"
    fi
}

#-------------------------------------------------------------------------------
# Main Rollback
#-------------------------------------------------------------------------------
run_rollback() {
    log_info "========================================"
    log_info "Starting Rollback Process"
    log_info "Project: $PROJECT_NAME"
    log_info "Environment: $ENVIRONMENT"
    log_info "Force: $FORCE_ROLLBACK"
    log_info "========================================"
    
    # Find previous version
    local previous_version
    if ! previous_version=$(find_previous_version); then
        die "Could not find previous version to rollback to"
    fi
    
    log_info "Found previous version:"
    echo "$previous_version" | while read -r line; do
        [[ -n "$line" ]] && log_info "  - $line"
    done
    
    # Check if it's a backup-based rollback
    if [[ "$previous_version" == BACKUP:* ]]; then
        local backup_file="${previous_version#BACKUP:}"
        rollback_from_backup "$backup_file"
    else
        rollback_containers "$previous_version"
    fi
    
    # Output rollback summary
    log_info "========================================"
    log_info "Rollback Summary"
    log_info "========================================"
    log_info "Timestamp: $(date -Iseconds)"
    log_info "Current containers:"
    podman ps --filter "label=project=${PROJECT_NAME}" --format '  - {{.Names}} ({{.Status}})' 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - Enterprise Podman Rollback Script

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -p, --project NAME          Project name (default: app)
    -e, --environment ENV       Environment name (default: production)
    -f, --file FILE             Compose file for configuration reference
    --force                     Force rollback without draining connections
    --skip-drain                Skip connection draining phase
    --keep-current              Keep current containers (don't remove)
    --dry-run                   Show what would be done without executing
    -h, --help                  Show this help message
    -v, --version               Show version information

DESCRIPTION:
    Performs graceful rollback to the previous working version of containers.
    Identifies previous version through container labels, stopped containers,
    or backup configurations.

ROLLBACK PROCESS:
    1. Find previous version containers
    2. Drain connections from current containers
    3. Stop current containers
    4. Start previous version containers
    5. Perform health checks
    6. Update load balancer/proxy configuration
    7. Cleanup old containers

EXIT CODES:
    0   Success
    1   General error
    2   No previous version found
    3   Rollback failed

EXAMPLES:
    # Standard rollback
    ${SCRIPT_NAME}

    # Force immediate rollback (no draining)
    ${SCRIPT_NAME} --force

    # Dry run to preview rollback
    ${SCRIPT_NAME} --dry-run

    # Rollback and keep current containers for debugging
    ${SCRIPT_NAME} --keep-current

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -f|--file)
                COMPOSE_FILE="$2"
                shift 2
                ;;
            --force)
                FORCE_ROLLBACK="true"
                shift
                ;;
            --skip-drain)
                SKIP_DRAIN="true"
                shift
                ;;
            --keep-current)
                KEEP_CURRENT="true"
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
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    if [[ "$FORCE_ROLLBACK" == "true" ]]; then
        log_warn "FORCE ROLLBACK MODE - Connections will be terminated immediately"
    fi
    
    acquire_lock
    run_rollback
    
    exit 0
}

main "$@"
