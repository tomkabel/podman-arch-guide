#!/bin/bash
# Blue-Green Deployment Switch Script
# Safely switches traffic between blue and green environments

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}"
HAPROXY_SOCKET="/var/lib/haproxy/stats"
ACTIVE_COLOR_FILE="${COMPOSE_DIR}/.active-color"
LOCK_FILE="/tmp/blue-green-switch.lock"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
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

# Get current active color
get_active_color() {
    if [[ -f "$ACTIVE_COLOR_FILE" ]]; then
        cat "$ACTIVE_COLOR_FILE"
    else
        echo "blue"
    fi
}

# Save active color
set_active_color() {
    echo "$1" > "$ACTIVE_COLOR_FILE"
}

# Check if environment is healthy
check_health() {
    local color=$1
    local max_attempts=${2:-30}
    local attempt=0

    log "Checking health of ${color} environment..."

    while [[ $attempt -lt $max_attempts ]]; do
        local status
        status=$(podman exec app-${color} wget -qO- http://localhost:8080/health 2>/dev/null || echo "unhealthy")

        if [[ "$status" == "healthy" ]] || [[ "$status" == *"\"status\":\"healthy\""* ]]; then
            success "${color} environment is healthy!"
            return 0
        fi

        attempt=$((attempt + 1))
        log "Health check ${attempt}/${max_attempts} failed for ${color}, retrying..."
        sleep 2
    done

    error "Health check failed for ${color} after ${max_attempts} attempts"
    return 1
}

# Get container stats
get_stats() {
    local color=$1
    log "Container stats for ${color} environment:"
    podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" app-${color} postgres-${color} redis-${color}
}

# Deploy new version to inactive environment
deploy() {
    local inactive_color=$1
    local image_tag=${2:-latest}

    log "Deploying ${image_tag} to ${inactive_color} environment..."

    # Update environment variable
    export DEPLOYMENT_ID="${inactive_color}-$(date +%s)"
    export ${inactive_color^^}_ACTIVE=true

    # Pull latest image if needed
    if [[ "$image_tag" != "latest" ]]; then
        export APP_IMAGE="${APP_IMAGE}:${image_tag}"
    fi

    # Start/Update inactive environment
    podman-compose -f "${COMPOSE_DIR}/docker-compose-${inactive_color}.yml" up -d

    success "Deployment to ${inactive_color} complete"
}

# Switch traffic between environments
switch() {
    local target_color=$1
    local current_color
    current_color=$(get_active_color)

    if [[ "$target_color" == "$current_color" ]]; then
        warning "${target_color} is already active. No switch needed."
        return 0
    fi

    log "Preparing to switch from ${current_color} to ${target_color}..."

    # Verify target environment is healthy
    if ! check_health "$target_color"; then
        error "Cannot switch: ${target_color} environment is not healthy!"
        return 1
    fi

    # Update HAProxy configuration
    log "Updating HAProxy to route to ${target_color}..."

    # Method 1: Update environment variable and reload
    export ACTIVE_COLOR="${target_color}"

    # Update HAProxy config
    sed -i "s/default_backend %%ACTIVE_COLOR%%_backend/default_backend ${target_color}_backend/g" \
        "${COMPOSE_DIR}/haproxy/haproxy.cfg"

    # Reload HAProxy gracefully
    podman exec blue-green-proxy haproxy -sf $(pgrep -o haproxy) 2>/dev/null || \
        podman-compose -f "${COMPOSE_DIR}/docker-compose-proxy.yml" restart haproxy

    # Save new active color
    set_active_color "$target_color"

    # Verify traffic is flowing
    sleep 2
    local verify_color
    verify_color=$(curl -s http://localhost/health 2>/dev/null | grep -o '"active_color":"[^"]*"' | cut -d'"' -f4)

    if [[ "$verify_color" == "$target_color" ]]; then
        success "Successfully switched to ${target_color}!"
    else
        error "Switch verification failed. Expected ${target_color}, got ${verify_color:-unknown}"
        return 1
    fi
}

# Rollback to previous environment
rollback() {
    local current_color
    current_color=$(get_active_color)
    local previous_color

    if [[ "$current_color" == "blue" ]]; then
        previous_color="green"
    else
        previous_color="blue"
    fi

    warning "Initiating rollback from ${current_color} to ${previous_color}..."

    if check_health "$previous_color" 5; then
        switch "$previous_color"
        success "Rollback complete!"
    else
        error "Rollback failed: ${previous_color} environment is not healthy!"
        return 1
    fi
}

# Status check
status() {
    local active_color
    active_color=$(get_active_color)

    log "Blue-Green Deployment Status"
    log "============================"
    log "Active Environment: ${GREEN}${active_color}${NC}"
    log ""

    # Container status
    log "Container Status:"
    podman ps --filter "name=app-blue\|name=app-green\|name=postgres-blue\|name=postgres-green\|name=redis-blue\|name=redis-green\|name=blue-green-proxy" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    log ""
    log "Health Status:"
    for color in blue green; do
        if podman ps --format "{{.Names}}" | grep -q "app-${color}"; then
            local health
            health=$(podman healthcheck run app-${color} 2>&1 && echo "healthy" || echo "unhealthy")
            if [[ "$health" == "healthy" ]]; then
                log "  app-${color}: ${GREEN}healthy${NC}"
            else
                log "  app-${color}: ${RED}unhealthy${NC}"
            fi
        else
            log "  app-${color}: ${YELLOW}not running${NC}"
        fi
    done

    log ""
    log "Current Traffic Routing:"
    curl -s http://localhost/health 2>/dev/null | grep -o '"active_color":"[^"]*"' | cut -d'"' -f4 || echo "unknown"
}

# Full deployment pipeline
pipeline() {
    local image_tag=${1:-latest}
    local current_color
    current_color=$(get_active_color)
    local inactive_color

    if [[ "$current_color" == "blue" ]]; then
        inactive_color="green"
    else
        inactive_color="blue"
    fi

    log "Starting blue-green deployment pipeline"
    log "Current active: ${current_color}, Target: ${inactive_color}"
    log "Image tag: ${image_tag}"
    log ""

    # Step 1: Deploy to inactive environment
    deploy "$inactive_color" "$image_tag"

    # Step 2: Run health checks
    if ! check_health "$inactive_color"; then
        error "Deployment failed: Health checks failed"
        log "Rolling back deployment..."
        podman-compose -f "${COMPOSE_DIR}/docker-compose-${inactive_color}.yml" down
        return 1
    fi

    # Step 3: Run smoke tests (if available)
    if [[ -f "${COMPOSE_DIR}/scripts/smoke-tests.sh" ]]; then
        log "Running smoke tests..."
        if ! bash "${COMPOSE_DIR}/scripts/smoke-tests.sh" "$inactive_color"; then
            error "Smoke tests failed!"
            return 1
        fi
    fi

    # Step 4: Switch traffic
    if switch "$inactive_color"; then
        success "Deployment complete! ${inactive_color} is now active."

        # Step 5: Scale down old environment after grace period
        log "Waiting 60 seconds before scaling down ${current_color}..."
        sleep 60

        warning "Scaling down ${current_color} environment..."
        podman-compose -f "${COMPOSE_DIR}/docker-compose-${current_color}.yml" stop

        success "Deployment pipeline complete!"
    else
        error "Switch failed! Initiating rollback..."
        rollback
        return 1
    fi
}

# Cleanup old environment
cleanup() {
    local color=$1
    log "Cleaning up ${color} environment..."
    podman-compose -f "${COMPOSE_DIR}/docker-compose-${color}.yml" down -v
    success "Cleanup complete for ${color}"
}

# Main command handler
case "${1:-help}" in
    status)
        status
        ;;
    deploy)
        deploy "${2:-green}" "${3:-latest}"
        ;;
    switch)
        switch "${2:-green}"
        ;;
    rollback)
        rollback
        ;;
    pipeline)
        pipeline "${2:-latest}"
        ;;
    health)
        check_health "${2:-blue}"
        ;;
    stats)
        get_stats "${2:-$(get_active_color)}"
        ;;
    cleanup)
        cleanup "${2}"
        ;;
    setup)
        log "Setting up blue-green deployment..."
        # Create shared network
        podman network create blue-green-shared 2>/dev/null || log "Network already exists"
        # Start proxy
        podman-compose -f "${COMPOSE_DIR}/docker-compose-proxy.yml" up -d
        # Start blue environment
        BLUE_ACTIVE=true podman-compose -f "${COMPOSE_DIR}/docker-compose-blue.yml" up -d
        set_active_color "blue"
        success "Setup complete! Blue environment is now active."
        ;;
    help|*)
        cat << EOF
Blue-Green Deployment Management Script

Usage: $0 <command> [options]

Commands:
    setup                   Initial setup - create network and start blue
    status                  Show current deployment status
    deploy <color> [tag]    Deploy new version to specified color
    switch <color>          Switch traffic to specified color
    rollback                Rollback to previous environment
    pipeline [tag]          Full deployment pipeline to inactive environment
    health [color]          Check health of environment
    stats [color]           Show container statistics
    cleanup <color>         Stop and remove environment
    help                    Show this help message

Examples:
    $0 setup                                    # Initial setup
    $0 status                                   # Check status
    $0 pipeline v2.1.0                          # Deploy v2.1.0
    $0 switch green                             # Switch to green
    $0 rollback                                 # Emergency rollback

Environment Variables:
    APP_IMAGE           Base image name (default: nginx:alpine)
    ACTIVE_COLOR        Currently active color (blue/green)
    POSTGRES_PASSWORD   Database password
    REDIS_PASSWORD      Redis password

EOF
        ;;
esac
