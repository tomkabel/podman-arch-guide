#!/bin/bash
#
# Integration Test: Single-Node Deployment
# Tests full deployment lifecycle on a single node
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test library
source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="single-node-deployment"
APP_NAME="test-single-node"
APP_VERSION="1.0.0"
HTTP_PORT=0  # Will be assigned dynamically
TEST_TIMEOUT=120

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local required=(podman curl)
    local missing=()
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing prerequisites: ${missing[*]}"
        return 1
    fi
    
    # Check if podman is functional
    if ! podman version &> /dev/null; then
        log_error "Podman is not functional"
        return 1
    fi
    
    log_info "Prerequisites check passed"
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up test environment..."
    
    # Create test directories
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    # Get a free port
    HTTP_PORT=$(get_free_port)
    export HTTP_PORT
    
    log_info "Using port: $HTTP_PORT"
    log_info "Test directory: $TEST_DIR"
    
    # Create quadlet files
    mkdir -p "$TEST_DIR/containers"
    
    cat > "$TEST_DIR/containers/${APP_NAME}.container" << EOF
[Container]
ContainerName=${APP_NAME}
Image=docker.io/library/nginx:alpine
PublishPort=${HTTP_PORT}:80

[Service]
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    
    # Create a simple health check script
    cat > "$TEST_DIR/health-check.sh" << 'EOF'
#!/bin/bash
url="${1:-http://localhost:80}"
if curl -sf "$url" > /dev/null 2>&1; then
    echo "healthy"
    exit 0
else
    echo "unhealthy"
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/health-check.sh"
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
}

# ============================================
# Test Execution
# ============================================

run_test() {
    log_info "========================================"
    log_info "Running: $TEST_NAME"
    log_info "========================================"
    
    local start_time=$(date +%s)
    local exit_code=0
    
    # Run test steps
    test_deploy_container || exit_code=1
    test_verify_running || exit_code=1
    test_health_check || exit_code=1
    test_port_binding || exit_code=1
    test_logs_accessible || exit_code=1
    test_stop_container || exit_code=1
    test_restart_container || exit_code=1
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "========================================"
    if [[ $exit_code -eq 0 ]]; then
        log_success "All tests passed in ${duration}s"
    else
        log_error "Some tests failed after ${duration}s"
    fi
    log_info "========================================"
    
    return $exit_code
}

# ============================================
# Individual Test Cases
# ============================================

test_deploy_container() {
    log_info "Test: Deploy container..."
    
    # Pull the image first
    if ! podman pull docker.io/library/nginx:alpine > /dev/null 2>&1; then
        log_error "Failed to pull nginx image"
        return 1
    fi
    
    # Run container
    if ! podman run -d \
        --name "$APP_NAME" \
        -p "$HTTP_PORT:80" \
        --label "app=$APP_NAME" \
        --label "version=$APP_VERSION" \
        docker.io/library/nginx:alpine > /dev/null 2>&1; then
        log_error "Failed to start container"
        return 1
    fi
    
    # Wait for container to be running
    local elapsed=0
    while [[ $elapsed -lt $TEST_TIMEOUT ]]; do
        local status
        status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
        if [[ "$status" == "running" ]]; then
            log_success "Container is running"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    log_error "Container failed to reach running state"
    return 1
}

test_verify_running() {
    log_info "Test: Verify container is running..."
    
    local status
    status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null)
    
    if [[ "$status" != "running" ]]; then
        log_error "Container is not running (status: $status)"
        return 1
    fi
    
    # Check labels
    local app_label
    app_label=$(podman inspect "$APP_NAME" --format '{{.Config.Labels.app}}' 2>/dev/null)
    
    if [[ "$app_label" != "$APP_NAME" ]]; then
        log_error "Container label mismatch: expected $APP_NAME, got $app_label"
        return 1
    fi
    
    log_success "Container is running with correct labels"
    return 0
}

test_health_check() {
    log_info "Test: Health check endpoint..."
    
    local elapsed=0
    local healthy=0
    
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
            healthy=1
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    if [[ $healthy -eq 0 ]]; then
        log_error "Health check failed - container not responding"
        return 1
    fi
    
    log_success "Health check passed"
    return 0
}

test_port_binding() {
    log_info "Test: Port binding..."
    
    # Verify port is bound
    local port_bound
    port_bound=$(ss -tln | grep ":$HTTP_PORT " | wc -l)
    
    if [[ "$port_bound" -eq 0 ]]; then
        log_error "Port $HTTP_PORT is not bound"
        return 1
    fi
    
    # Test response from bound port
    local response
    response=$(curl -s "http://localhost:$HTTP_PORT/" 2>/dev/null | head -1)
    
    if [[ -z "$response" ]]; then
        log_error "No response from bound port"
        return 1
    fi
    
    log_success "Port binding working correctly"
    return 0
}

test_logs_accessible() {
    log_info "Test: Container logs accessible..."
    
    local logs
    logs=$(podman logs "$APP_NAME" 2>&1)
    
    if [[ -z "$logs" ]]; then
        log_warn "Container logs are empty (may be OK for fresh container)"
    fi
    
    # Check that logs command works
    if ! podman logs "$APP_NAME" > /dev/null 2>&1; then
        log_error "Failed to retrieve container logs"
        return 1
    fi
    
    log_success "Container logs are accessible"
    return 0
}

test_stop_container() {
    log_info "Test: Stop container..."
    
    if ! podman stop -t 10 "$APP_NAME" > /dev/null 2>&1; then
        log_error "Failed to stop container"
        return 1
    fi
    
    local status
    status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null)
    
    if [[ "$status" != "exited" && "$status" != "stopped" ]]; then
        log_error "Container not stopped (status: $status)"
        return 1
    fi
    
    # Verify port is released
    sleep 1
    local port_bound
    port_bound=$(ss -tln 2>/dev/null | grep ":$HTTP_PORT " | wc -l)
    
    if [[ "$port_bound" -gt 0 ]]; then
        log_warn "Port $HTTP_PORT still bound after container stop"
    fi
    
    log_success "Container stopped successfully"
    return 0
}

test_restart_container() {
    log_info "Test: Restart container..."
    
    if ! podman start "$APP_NAME" > /dev/null 2>&1; then
        log_error "Failed to restart container"
        return 1
    fi
    
    # Wait for container to be running
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        local status
        status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null)
        if [[ "$status" == "running" ]]; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    # Verify health check passes after restart
    local healthy=0
    local retry=0
    while [[ $retry -lt 10 ]]; do
        if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
            healthy=1
            break
        fi
        sleep 1
        retry=$((retry + 1))
    done
    
    if [[ $healthy -eq 0 ]]; then
        log_error "Container not healthy after restart"
        return 1
    fi
    
    log_success "Container restarted successfully"
    return 0
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up test environment..."
    
    # Stop and remove container
    if podman ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
        log_info "Stopping container $APP_NAME..."
        podman stop -t 10 "$APP_NAME" > /dev/null 2>&1 || true
        log_info "Removing container $APP_NAME..."
        podman rm "$APP_NAME" > /dev/null 2>&1 || true
    fi
    
    # Remove image
    podman rmi docker.io/library/nginx:alpine > /dev/null 2>&1 || true
    
    # Remove test directory
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
    
    log_info "Cleanup complete"
}

# ============================================
# Main
# ============================================

main() {
    # Setup trap for cleanup
    trap_cleanup
    
    # Initialize tests
    init_tests "$TEST_NAME"
    
    # Check prerequisites
    if ! check_prerequisites; then
        skip_test "$TEST_NAME" "Prerequisites not met"
        finish_tests "$TEST_NAME"
        exit 77  # Skip exit code
    fi
    
    # Setup test environment
    setup_test_env
    
    # Run tests
    local exit_code=0
    if ! run_test; then
        exit_code=1
    fi
    
    # Cleanup
    run_cleanup
    
    # Finish
    finish_tests "$TEST_NAME"
    
    return $exit_code
}

# Run main
main "$@"
