#!/usr/bin/env bash
#===============================================================================
# blue-green-deploy.sh - Blue-Green Deployment Orchestrator
#===============================================================================
# Description: Manages blue/green environment switching with traffic cutover,
#              instant rollback capability, and canary traffic splitting.
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
readonly LOG_FILE="${LOG_DIR}/blue-green-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"

#-------------------------------------------------------------------------------
# Deployment Configuration
#-------------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
ACTIVE_COLOR="${ACTIVE_COLOR:-}"  # blue or green
TRAFFIC_SPLIT="${TRAFFIC_SPLIT:-0}"  # 0 = all to active, 100 = all to new
VERIFICATION_TIMEOUT="${VERIFICATION_TIMEOUT:-300}"
CANARY_DURATION="${CANARY_DURATION:-300}"
CLEANUP_DELAY="${CLEANUP_DELAY:-3600}"  # Keep old version for 1 hour
DRY_RUN="${DRY_RUN:-false}"
SKIP_VERIFICATION="${SKIP_VERIFICATION:-false}"

#-------------------------------------------------------------------------------
# Colors for terminal output
#-------------------------------------------------------------------------------
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r CYAN='\033[0;36m'
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
        CANARY)  echo -e "${CYAN}[$timestamp] [CANARY] $message${NC}" ;;
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_success() { log "SUCCESS" "$@"; }
log_canary() { log "CANARY" "$@"; }

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
        log_error "Blue-green deployment failed with exit code $exit_code"
        if [[ "${SWITCH_STARTED:-false}" == "true" ]]; then
            log_warn "Traffic switch was in progress - consider manual intervention"
        fi
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
            die "Another blue-green deployment is in progress (PID: $pid)"
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Acquired deployment lock"
}

#-------------------------------------------------------------------------------
# Color Detection
#-------------------------------------------------------------------------------
detect_active_color() {
    log_info "Detecting active color environment..."
    
    # Check for running containers with color labels
    local blue_count
    blue_count=$(podman ps --filter "label=color=blue" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null | wc -l)
    
    local green_count
    green_count=$(podman ps --filter "label=color=green" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null | wc -l)
    
    # Check which has the active traffic label
    local active_from_label
    active_from_label=$(podman ps --filter "label=traffic=active" --filter "label=project=${PROJECT_NAME}" --format '{{.Labels}}' 2>/dev/null | grep -oE 'color=(blue|green)' | cut -d= -f2 | head -n1 || true)
    
    if [[ -n "$active_from_label" ]]; then
        ACTIVE_COLOR="$active_from_label"
    elif [[ $blue_count -gt 0 ]] && [[ $green_count -eq 0 ]]; then
        ACTIVE_COLOR="blue"
    elif [[ $green_count -gt 0 ]] && [[ $blue_count -eq 0 ]]; then
        ACTIVE_COLOR="green"
    elif [[ $blue_count -gt 0 ]] && [[ $green_count -gt 0 ]]; then
        log_warn "Both blue and green environments are running"
        ACTIVE_COLOR="blue"  # Default to blue
    else
        log_info "No existing deployment found, starting with blue"
        ACTIVE_COLOR="blue"
    fi
    
    log_info "Active color environment: $ACTIVE_COLOR"
}

get_inactive_color() {
    if [[ "$ACTIVE_COLOR" == "blue" ]]; then
        echo "green"
    else
        echo "blue"
    fi
}

#-------------------------------------------------------------------------------
# Environment Management
#-------------------------------------------------------------------------------
start_new_environment() {
    local new_color="$1"
    
    log_info "Starting new environment: $new_color"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would start $new_color environment"
        return 0
    fi
    
    # Create environment-specific compose override
    local override_file="/tmp/compose-${new_color}.yml"
    
    cat > "$override_file" << EOF
version: '3.8'
services:
  app:
    labels:
      - "color=${new_color}"
      - "project=${PROJECT_NAME}"
      - "traffic=standby"
      - "deployment-time=$(date -Iseconds)"
    networks:
      - ${PROJECT_NAME}-${new_color}

networks:
  ${PROJECT_NAME}-${new_color}:
    driver: bridge
    labels:
      - "color=${new_color}"
      - "project=${PROJECT_NAME}"
EOF
    
    # Start containers with color labels
    local project_name="${PROJECT_NAME}-${new_color}"
    
    if ! podman-compose -f "$COMPOSE_FILE" -f "$override_file" -p "$project_name" up -d; then
        die "Failed to start $new_color environment"
    fi
    
    # Label all containers
    local containers
    containers=$(podman ps --filter "label=io.podman.compose.project=${project_name}" --format '{{.Names}}' 2>/dev/null || true)
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        podman container update \
            --label "color=${new_color}" \
            --label "project=${PROJECT_NAME}" \
            --label "traffic=standby" \
            "$container" 2>/dev/null || true
    done <<< "$containers"
    
    log_success "$new_color environment started"
    rm -f "$override_file"
}

stop_environment() {
    local color="$1"
    local force="${2:-false}"
    
    log_info "Stopping $color environment..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would stop $color environment"
        return 0
    fi
    
    local containers
    containers=$(podman ps -a --filter "label=color=${color}" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    if [[ -z "$containers" ]]; then
        log_info "No containers found for $color environment"
        return 0
    fi
    
    # Graceful shutdown
    local timeout=30
    if [[ "$force" == "true" ]]; then
        timeout=5
    fi
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        log_info "Stopping $container..."
        podman stop -t "$timeout" "$container" 2>/dev/null || podman kill "$container" 2>/dev/null || true
        podman rm "$container" 2>/dev/null || true
    done <<< "$containers"
    
    # Remove networks
    local networks
    networks=$(podman network ls --filter "label=color=${color}" --filter "label=project=${PROJECT_NAME}" --format '{{.Name}}' 2>/dev/null || true)
    
    while IFS= read -r network; do
        [[ -z "$network" ]] && continue
        podman network rm "$network" 2>/dev/null || true
    done <<< "$networks"
    
    log_success "$color environment stopped"
}

#-------------------------------------------------------------------------------
# Health Verification
#-------------------------------------------------------------------------------
verify_environment() {
    local color="$1"
    local timeout="${2:-$VERIFICATION_TIMEOUT}"
    
    log_info "Verifying $color environment health..."
    
    local containers
    containers=$(podman ps --filter "label=color=${color}" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    if [[ -z "$containers" ]]; then
        die "No containers found for $color environment"
    fi
    
    local elapsed=0
    local interval=5
    local all_healthy=true
    
    while [[ $elapsed -lt $timeout ]]; do
        all_healthy=true
        
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            
            local status
            status=$(podman inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
            local health
            health=$(podman inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
            
            if [[ "$status" != "running" ]]; then
                log_error "Container $container is not running (status: $status)"
                all_healthy=false
                break
            fi
            
            if [[ "$health" == "unhealthy" ]]; then
                log_error "Container $container is unhealthy"
                all_healthy=false
                break
            fi
        done <<< "$containers"
        
        if $all_healthy; then
            log_success "$color environment is healthy"
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Waiting for $color environment to be healthy... (${elapsed}s/${timeout}s)"
    done
    
    return 1
}

#-------------------------------------------------------------------------------
# Traffic Management
#-------------------------------------------------------------------------------
update_traffic_proxy() {
    local active_color="$1"
    local new_color="$2"
    local split_percent="${3:-0}"
    
    log_info "Updating traffic routing: active=$active_color, new=$new_color, split=${split_percent}%"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would update traffic proxy"
        return 0
    fi
    
    # Method 1: Update podman labels for service discovery
    local old_containers
    old_containers=$(podman ps --filter "label=color=${active_color}" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    local new_containers
    new_containers=$(podman ps --filter "label=color=${new_color}" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    # Update labels for traffic routing
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        podman container update --label "traffic=standby" "$container" 2>/dev/null || true
    done <<< "$old_containers"
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        if [[ "$split_percent" -eq 0 ]] || [[ "$split_percent" -eq 100 ]]; then
            podman container update --label "traffic=active" "$container" 2>/dev/null || true
        else
            podman container update --label "traffic=canary" "$container" 2>/dev/null || true
        fi
    done <<< "$new_containers"
    
    # Method 2: Update external proxy if available (nginx, haproxy, etc.)
    update_external_proxy "$active_color" "$new_color" "$split_percent"
    
    log_success "Traffic routing updated"
}

update_external_proxy() {
    local active_color="$1"
    local new_color="$2"
    local split_percent="$3"
    
    # This is a placeholder for external proxy updates
    # In production, this would update nginx upstreams, HAProxy backends, etc.
    
    if [[ -f "/etc/nginx/conf.d/${PROJECT_NAME}.conf" ]]; then
        log_info "Updating nginx configuration..."
        # Template nginx config update would go here
        # nginx -s reload
        :  # Placeholder
    fi
}

#-------------------------------------------------------------------------------
# Canary Deployment
#-------------------------------------------------------------------------------
run_canary() {
    local active_color="$1"
    local new_color="$2"
    local duration="${3:-$CANARY_DURATION}"
    local start_percent="${4:-10}"
    local end_percent="${5:-100}"
    local step="${6:-10}"
    
    log_canary "Starting canary deployment: $active_color -> $new_color"
    log_canary "Duration: ${duration}s, Start: ${start_percent}%, End: ${end_percent}%"
    
    local current_percent=$start_percent
    local step_duration=$((duration / ((end_percent - start_percent) / step)))
    
    while [[ $current_percent -le $end_percent ]]; do
        log_canary "Setting traffic split: ${current_percent}% to $new_color"
        
        if [[ "$DRY_RUN" != "true" ]]; then
            update_traffic_proxy "$active_color" "$new_color" "$current_percent"
        fi
        
        # Monitor during canary window
        log_canary "Monitoring for ${step_duration}s..."
        
        if [[ "$DRY_RUN" != "true" ]]; then
            sleep "$step_duration"
            
            # Quick health check
            if ! verify_environment "$new_color" 30; then
                log_error "Canary health check failed at ${current_percent}%"
                log_info "Initiating automatic rollback..."
                rollback_traffic "$active_color" "$new_color"
                return 1
            fi
        fi
        
        current_percent=$((current_percent + step))
    done
    
    # Final switch to 100%
    log_canary "Completing canary: 100% traffic to $new_color"
    update_traffic_proxy "$active_color" "$new_color" 100
    
    log_success "Canary deployment completed successfully"
    return 0
}

rollback_traffic() {
    local rollback_to="$1"
    local rollback_from="$2"
    
    log_warn "Rolling back traffic to $rollback_to"
    
    update_traffic_proxy "$rollback_from" "$rollback_to" 0
    
    # Mark rollback containers
    local rollback_containers
    rollback_containers=$(podman ps --filter "label=color=${rollback_to}" --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        podman container update --label "traffic=active" --label "canary-failed=true" "$container" 2>/dev/null || true
    done <<< "$rollback_containers"
}

#-------------------------------------------------------------------------------
# Cleanup
#-------------------------------------------------------------------------------
schedule_cleanup() {
    local old_color="$1"
    local delay="${2:-$CLEANUP_DELAY}"
    
    log_info "Scheduling cleanup of $old_color environment in ${delay}s"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would schedule cleanup"
        return 0
    fi
    
    # Create cleanup script
    local cleanup_script="/tmp/cleanup-${old_color}-$$.sh"
    cat > "$cleanup_script" << EOF
#!/bin/bash
sleep $delay
${SCRIPT_DIR}/blue-green-deploy.sh --cleanup-only --color $old_color --project $PROJECT_NAME
rm -f "$cleanup_script"
EOF
    chmod +x "$cleanup_script"
    
    # Run in background
    nohup "$cleanup_script" > /dev/null 2>&1 &
    
    log_info "Cleanup scheduled (PID: $!)"
}

cleanup_environment() {
    local color="$1"
    
    log_info "Cleaning up $color environment..."
    stop_environment "$color" "true"
}

#-------------------------------------------------------------------------------
# Main Blue-Green Deployment
#-------------------------------------------------------------------------------
run_blue_green_deployment() {
    log_info "========================================"
    log_info "Blue-Green Deployment Starting"
    log_info "Project: $PROJECT_NAME"
    log_info "Environment: $ENVIRONMENT"
    log_info "========================================"
    
    # Detect current active color
    if [[ -z "$ACTIVE_COLOR" ]]; then
        detect_active_color
    fi
    
    local new_color
    new_color=$(get_inactive_color)
    
    log_info "Active: $ACTIVE_COLOR, New: $new_color"
    
    # Start new environment
    start_new_environment "$new_color"
    
    # Verify new environment
    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        if ! verify_environment "$new_color" "$VERIFICATION_TIMEOUT"; then
            log_error "New environment health check failed"
            log_info "Stopping failed environment..."
            stop_environment "$new_color" "true"
            die "Deployment failed - $ACTIVE_COLOR remains active"
        fi
    fi
    
    SWITCH_STARTED=true
    
    # Perform traffic switch
    if [[ "$TRAFFIC_SPLIT" -gt 0 ]] && [[ "$TRAFFIC_SPLIT" -lt 100 ]]; then
        # Canary deployment
        if ! run_canary "$ACTIVE_COLOR" "$new_color" "$CANARY_DURATION" "$TRAFFIC_SPLIT" 100 10; then
            die "Canary deployment failed"
        fi
    else
        # Direct cutover
        log_info "Performing immediate traffic cutover..."
        update_traffic_proxy "$ACTIVE_COLOR" "$new_color" 100
    fi
    
    # Wait a moment for traffic to settle
    log_info "Waiting for traffic to settle..."
    sleep 10
    
    # Quick verification of active environment
    if [[ "$SKIP_VERIFICATION" != "true" ]]; then
        if ! verify_environment "$new_color" 60; then
            log_error "New environment failed after traffic switch"
            log_warn "Initiating emergency rollback..."
            rollback_traffic "$ACTIVE_COLOR" "$new_color"
            die "Emergency rollback initiated"
        fi
    fi
    
    # Schedule cleanup of old environment
    if [[ "$DRY_RUN" != "true" ]]; then
        schedule_cleanup "$ACTIVE_COLOR" "$CLEANUP_DELAY"
    fi
    
    log_success "========================================"
    log_success "Blue-Green Deployment Complete!"
    log_success "Active Environment: $new_color"
    log_success "Previous Environment: $ACTIVE_COLOR (scheduled for cleanup)"
    log_success "========================================"
    
    # Output final status
    log_info "Active Containers:"
    podman ps --filter "label=color=${new_color}" --filter "label=project=${PROJECT_NAME}" --format '  - {{.Names}} ({{.Status}})' 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - Blue-Green Deployment Orchestrator

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -p, --project NAME          Project name (default: app)
    -e, --environment ENV       Environment name (default: production)
    -f, --file FILE             Compose file path (default: docker-compose.yml)
    -c, --color COLOR           Force active color (blue/green)
    --traffic-split PERCENT     Start with canary at PERCENT (default: 0)
    --canary-duration SECONDS   Canary ramp-up duration (default: 300)
    --verification-timeout SEC  Health check timeout (default: 300)
    --cleanup-delay SECONDS     Delay before cleanup (default: 3600)
    --cleanup-only              Only cleanup specified color
    --skip-verification         Skip health verification
    --dry-run                   Show what would be done without executing
    -h, --help                  Show this help message
    -v, --version               Show version information

DESCRIPTION:
    Manages blue-green deployments with zero-downtime traffic switching.
    Automatically detects active environment, starts new environment,
    verifies health, switches traffic, and schedules cleanup.

CANARY DEPLOYMENT:
    Use --traffic-split to start with a percentage of traffic to the new
    environment. The deployment will gradually increase traffic and monitor
    for issues, automatically rolling back if problems are detected.

TRAFFIC MANAGEMENT:
    The script uses container labels for traffic routing:
    - color=blue|green      Environment color
    - traffic=active|standby|canary  Traffic routing status

EXAMPLES:
    # Standard blue-green deployment
    ${SCRIPT_NAME}

    # Canary deployment starting at 10%
    ${SCRIPT_NAME} --traffic-split 10

    # Cleanup old green environment
    ${SCRIPT_NAME} --cleanup-only --color green

    # Dry run
    ${SCRIPT_NAME} --dry-run

EXIT CODES:
    0   Success
    1   General error
    2   Health verification failed
    3   Traffic switch failed

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    local cleanup_only=false
    local cleanup_color=""
    
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
            -c|--color)
                ACTIVE_COLOR="$2"
                shift 2
                ;;
            --traffic-split)
                TRAFFIC_SPLIT="$2"
                shift 2
                ;;
            --canary-duration)
                CANARY_DURATION="$2"
                shift 2
                ;;
            --verification-timeout)
                VERIFICATION_TIMEOUT="$2"
                shift 2
                ;;
            --cleanup-delay)
                CLEANUP_DELAY="$2"
                shift 2
                ;;
            --cleanup-only)
                cleanup_only=true
                shift
                ;;
            --skip-verification)
                SKIP_VERIFICATION="true"
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
    
    if [[ "$cleanup_only" == "true" ]]; then
        if [[ -z "$cleanup_color" ]]; then
            cleanup_color="${ACTIVE_COLOR:-$(get_inactive_color)}"
        fi
        cleanup_environment "$cleanup_color"
        exit 0
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    acquire_lock
    run_blue_green_deployment
    exit 0
}

main "$@"
