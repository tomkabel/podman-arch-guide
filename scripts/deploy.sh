#!/usr/bin/env bash
#===============================================================================
# deploy.sh - Enterprise Podman Deployment Script
#===============================================================================
# Description: Main deployment script with validation, retry logic, health
#              checks, and support for blue-green and rolling deployment strategies.
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
readonly LOG_FILE="${LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
readonly RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
readonly RETRY_DELAY="${RETRY_DELAY:-10}"
readonly HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-300}"
readonly HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-5}"
readonly MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-10}"
readonly MIN_PODMAN_VERSION="4.0.0"

#-------------------------------------------------------------------------------
# Deployment Configuration (override via environment variables)
#-------------------------------------------------------------------------------
DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY:-rolling}"  # rolling, blue-green
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
ENVIRONMENT="${ENVIRONMENT:-production}"
PROJECT_NAME="${PROJECT_NAME:-app}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
NAMESPACE="${NAMESPACE:-default}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-false}"
FORCE_DEPLOY="${FORCE_DEPLOY:-false}"

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
    
    # Log to file
    mkdir -p "$LOG_DIR"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Log to console with colors
    case "$level" in
        ERROR)   echo -e "${RED}[$timestamp] [ERROR] $message${NC}" >&2 ;;
        WARN)    echo -e "${YELLOW}[$timestamp] [WARN] $message${NC}" ;;
        SUCCESS) echo -e "${GREEN}[$timestamp] [SUCCESS] $message${NC}" ;;
        INFO)    echo -e "${BLUE}[$timestamp] [INFO] $message${NC}" ;;
        *)       echo "[$timestamp] [$level] $message" ;;
    esac
}

log_info() { log "INFO" "$*"; }
log_warn() { log "WARN" "$*"; }
log_error() { log "ERROR" "$*"; }
log_success() { log "SUCCESS" "$*"; }

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
        log_info "Removed lock file"
    fi
}

trap_cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated unexpectedly with exit code $exit_code"
        if [[ "${DEPLOYMENT_STARTED:-false}" == "true" ]]; then
            log_warn "Deployment was in progress - consider rollback"
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
            die "Another deployment is in progress (PID: ${pid})"
        else
            log_warn "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_info "Acquired deployment lock"
}

#-------------------------------------------------------------------------------
# Version Comparison
#-------------------------------------------------------------------------------
version_ge() {
    local v1="$1"
    local v2="$2"
    # Use sort -V for version comparison
    [[ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)" == "$v2" ]]
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
validate_environment() {
    log_info "Validating environment..."
    
    # Check if running as root (required for some operations)
    if [[ $EUID -ne 0 ]] && [[ "$FORCE_DEPLOY" != "true" ]]; then
        log_warn "Not running as root - some operations may fail"
    fi
    
    # Check Podman installation
    if ! command -v podman &> /dev/null; then
        die "Podman is not installed or not in PATH"
    fi
    
    # Check Podman version
    local podman_version
    podman_version=$(podman version --format '{{.Client.Version}}' 2>/dev/null || echo "0.0.0")
    if ! version_ge "$podman_version" "$MIN_PODMAN_VERSION"; then
        die "Podman version $podman_version is too old. Minimum required: $MIN_PODMAN_VERSION"
    fi
    log_info "Podman version: $podman_version"
    
    # Check Podman service status
    if ! podman info &> /dev/null; then
        die "Podman daemon is not running or not accessible"
    fi
    
    # Check compose file exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        die "Compose file not found: $COMPOSE_FILE"
    fi
    
    # Check available storage
    local available_gb
    available_gb=$(df -BG "$PWD" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$available_gb" -lt "$MIN_FREE_SPACE_GB" ]]; then
        die "Insufficient disk space: ${available_gb}GB available, ${MIN_FREE_SPACE_GB}GB required"
    fi
    log_info "Available disk space: ${available_gb}GB"
    
    # Check network connectivity
    log_info "Checking network connectivity..."
    if ! curl -s --max-time 10 https://registry-1.docker.io/v2/ > /dev/null 2>&1; then
        log_warn "Cannot reach Docker Hub registry"
    fi
    
    # Validate compose file syntax
    if ! podman-compose -f "$COMPOSE_FILE" config > /dev/null 2>&1; then
        die "Invalid compose file syntax"
    fi
    
    log_success "Environment validation passed"
}

#-------------------------------------------------------------------------------
# Retry Logic
#-------------------------------------------------------------------------------
retry_with_backoff() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: $*"
        
        if "$@"; then
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Command failed, waiting ${delay}s before retry..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
        
        ((attempt++))
    done
    
    return 1
}

#-------------------------------------------------------------------------------
# Image Management
#-------------------------------------------------------------------------------
pull_images() {
    log_info "Pulling container images..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would pull images from compose file"
        return 0
    fi
    
    # Extract image names from compose file
    local images
    images=$(podman-compose -f "$COMPOSE_FILE" config 2>/dev/null | grep -E '^\s+image:' | awk '{print $2}' | sort -u || true)
    
    if [[ -z "$images" ]]; then
        log_warn "No images found in compose file"
        return 0
    fi
    
    local failed=0
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        
        log_info "Pulling image: $image"
        if ! retry_with_backoff "$RETRY_ATTEMPTS" "$RETRY_DELAY" podman pull "$image"; then
            log_error "Failed to pull image after $RETRY_ATTEMPTS attempts: $image"
            ((failed++))
            
            # Check if image exists locally (might be acceptable for local builds)
            if podman image exists "$image"; then
                log_warn "Using locally cached image: $image"
                ((failed--))
            fi
        fi
    done <<< "$images"
    
    if [[ $failed -gt 0 ]]; then
        die "Failed to pull $failed image(s)"
    fi
    
    log_success "All images pulled successfully"
}

#-------------------------------------------------------------------------------
# Health Check Functions
#-------------------------------------------------------------------------------
wait_for_container() {
    local container_name="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"
    local interval="${3:-$HEALTH_CHECK_INTERVAL}"
    local elapsed=0
    
    log_info "Waiting for container '$container_name' to be healthy..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(podman inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")
        
        case "$status" in
            running)
                local health_status
                health_status=$(podman inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
                
                if [[ "$health_status" == "healthy" ]] || [[ "$health_status" == "none" ]]; then
                    log_success "Container '$container_name' is healthy"
                    return 0
                fi
                ;;
            exited|dead)
                log_error "Container '$container_name' has failed (status: $status)"
                return 1
                ;;
        esac
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_info "Still waiting for '$container_name'... (${elapsed}s/${timeout}s)"
    done
    
    log_error "Timeout waiting for container '$container_name'"
    return 1
}

health_check_endpoints() {
    local endpoints="$1"
    local timeout="${2:-30}"
    
    [[ -z "$endpoints" ]] && return 0
    
    log_info "Performing endpoint health checks..."
    
    local failed=0
    while IFS=',' read -r endpoint; do
        [[ -z "$endpoint" ]] && continue
        
        local url
        url=$(echo "$endpoint" | xargs)
        log_info "Checking endpoint: $url"
        
        if curl -sf --max-time "$timeout" "$url" > /dev/null 2>&1; then
            log_success "Endpoint healthy: $url"
        else
            log_error "Endpoint unhealthy: $url"
            ((failed++))
        fi
    done <<< "$endpoints"
    
    return $failed
}

#-------------------------------------------------------------------------------
# Deployment Strategies
#-------------------------------------------------------------------------------
deploy_rolling() {
    log_info "Executing rolling deployment..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute rolling deployment"
        return 0
    fi
    
    DEPLOYMENT_STARTED=true
    
    # Tag current containers for rollback
    local running_containers
    running_containers=$(podman ps --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
    
    if [[ -n "$running_containers" ]]; then
        log_info "Tagging current containers for potential rollback..."
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            podman container update --label="previous-version=true" --label="deployment-time=$(date -Iseconds)" "$container" 2>/dev/null || true
        done <<< "$running_containers"
    fi
    
    # Bring up new containers
    log_info "Starting new containers..."
    if ! podman-compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d; then
        die "Failed to start containers"
    fi
    
    # Wait for health checks if not skipped
    if [[ "$SKIP_HEALTH_CHECK" != "true" ]]; then
        log_info "Performing health checks..."
        local new_containers
        new_containers=$(podman ps --filter "label=project=${PROJECT_NAME}" --format '{{.Names}}' 2>/dev/null || true)
        
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            if ! wait_for_container "$container"; then
                die "Health check failed for container: $container"
            fi
        done <<< "$new_containers"
    fi
    
    log_success "Rolling deployment completed successfully"
}

deploy_blue_green() {
    log_info "Executing blue-green deployment..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute blue-green deployment"
        return 0
    fi
    
    # Delegate to blue-green-deploy.sh
    if [[ -f "${SCRIPT_DIR}/blue-green-deploy.sh" ]]; then
        "${SCRIPT_DIR}/blue-green-deploy.sh" --compose-file "$COMPOSE_FILE" --project "$PROJECT_NAME" --environment "$ENVIRONMENT"
    else
        log_warn "blue-green-deploy.sh not found, falling back to rolling deployment"
        deploy_rolling
    fi
}

#-------------------------------------------------------------------------------
# Main Deployment
#-------------------------------------------------------------------------------
run_deployment() {
    log_info "Starting deployment..."
    log_info "Strategy: $DEPLOYMENT_STRATEGY"
    log_info "Environment: $ENVIRONMENT"
    log_info "Project: $PROJECT_NAME"
    log_info "Compose file: $COMPOSE_FILE"
    
    validate_environment
    pull_images
    
    case "$DEPLOYMENT_STRATEGY" in
        rolling)
            deploy_rolling
            ;;
        blue-green)
            deploy_blue_green
            ;;
        *)
            die "Unknown deployment strategy: $DEPLOYMENT_STRATEGY"
            ;;
    esac
    
    log_success "Deployment completed successfully!"
    
    # Output deployment summary
    log_info "=== Deployment Summary ==="
    log_info "Timestamp: $(date -Iseconds)"
    log_info "Strategy: $DEPLOYMENT_STRATEGY"
    log_info "Containers:"
    podman ps --filter "label=project=${PROJECT_NAME}" --format '  - {{.Names}} ({{.Status}})' 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - Enterprise Podman Deployment Script

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -s, --strategy STRATEGY     Deployment strategy: rolling (default), blue-green
    -f, --file FILE             Compose file path (default: docker-compose.yml)
    -e, --environment ENV       Environment name (default: production)
    -p, --project NAME          Project name (default: app)
    -n, --namespace NS          Namespace (default: default)
    -r, --registry URL          Image registry URL
    --skip-health-check         Skip health checks after deployment
    --force                     Force deployment even with warnings
    --dry-run                   Show what would be done without executing
    -h, --help                  Show this help message
    -v, --version               Show version information

ENVIRONMENT VARIABLES:
    DEPLOYMENT_STRATEGY         Default deployment strategy
    COMPOSE_FILE                Default compose file
    ENVIRONMENT                 Default environment
    PROJECT_NAME                Default project name
    RETRY_ATTEMPTS              Number of retry attempts for pulls (default: 3)
    RETRY_DELAY                 Initial retry delay in seconds (default: 10)
    HEALTH_CHECK_TIMEOUT        Health check timeout in seconds (default: 300)
    LOG_DIR                     Log directory (default: /var/log/podman-deploy)

EXAMPLES:
    # Standard rolling deployment
    ${SCRIPT_NAME}

    # Blue-green deployment
    ${SCRIPT_NAME} --strategy blue-green

    # Deploy with custom compose file
    ${SCRIPT_NAME} -f production-compose.yml

    # Dry run to see what would happen
    ${SCRIPT_NAME} --dry-run

EXIT CODES:
    0   Success
    1   General error
    2   Validation error
    3   Deployment failed
    4   Health check failed

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--strategy)
                DEPLOYMENT_STRATEGY="$2"
                shift 2
                ;;
            -f|--file)
                COMPOSE_FILE="$2"
                shift 2
                ;;
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -p|--project)
                PROJECT_NAME="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--registry)
                IMAGE_REGISTRY="$2"
                shift 2
                ;;
            --skip-health-check)
                SKIP_HEALTH_CHECK="true"
                shift
                ;;
            --force)
                FORCE_DEPLOY="true"
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
    
    log_info "========================================"
    log_info "${SCRIPT_NAME} v${VERSION}"
    log_info "========================================"
    
    acquire_lock
    run_deployment
    
    exit 0
}

main "$@"
