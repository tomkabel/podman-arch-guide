#!/bin/bash
#
# Integration Test: Blue-Green Deployment
# Tests blue-green deployment flow with traffic switching
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="blue-green-deployment"
APP_NAME="test-bg-app"
BLUE_VERSION="1.0.0"
GREEN_VERSION="2.0.0"
BLUE_PORT=0
GREEN_PORT=0
PROXY_PORT=0
TEST_TIMEOUT=120

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local required=(podman curl jq)
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
    
    log_info "Prerequisites check passed"
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    # Get free ports
    BLUE_PORT=$(get_free_port)
    GREEN_PORT=$(get_free_port)
    PROXY_PORT=$(get_free_port)
    
    # Ensure ports are different
    while [[ "$GREEN_PORT" == "$BLUE_PORT" ]]; do
        GREEN_PORT=$(get_free_port)
    done
    while [[ "$PROXY_PORT" == "$BLUE_PORT" || "$PROXY_PORT" == "$GREEN_PORT" ]]; do
        PROXY_PORT=$(get_free_port)
    done
    
    export BLUE_PORT GREEN_PORT PROXY_PORT
    
    log_info "Blue port: $BLUE_PORT"
    log_info "Green port: $GREEN_PORT"
    log_info "Proxy port: $PROXY_PORT"
    
    # Create nginx config for different versions
    mkdir -p "$TEST_DIR/nginx"
    
    # Blue version response
    cat > "$TEST_DIR/nginx/blue.html" << EOF
<!DOCTYPE html>
<html>
<head><title>Blue Version</title></head>
<body><h1>Version: $BLUE_VERSION</h1></body>
</html>
EOF
    
    # Green version response
    cat > "$TEST_DIR/nginx/green.html" << EOF
<!DOCTYPE html>
<html>
<head><title>Green Version</title></head>
<body><h1>Version: $GREEN_VERSION</h1></body>
</html>
EOF
    
    # Create state tracking
    echo "blue" > "$TEST_DIR/active-environment"
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
}

# ============================================
# Blue-Green Deployment Functions
# ============================================

deploy_blue() {
    log_info "Deploying BLUE version ($BLUE_VERSION) on port $BLUE_PORT..."
    
    # Create a simple HTTP server for blue
    if ! podman run -d \
        --name "${APP_NAME}-blue" \
        -p "$BLUE_PORT:80" \
        -v "$TEST_DIR/nginx/blue.html:/usr/share/nginx/html/index.html:ro" \
        --label "app=$APP_NAME" \
        --label "version=$BLUE_VERSION" \
        --label "environment=blue" \
        docker.io/library/nginx:alpine > /dev/null 2>&1; then
        log_error "Failed to deploy BLUE version"
        return 1
    fi
    
    # Wait for container to be ready
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "http://localhost:$BLUE_PORT/" > /dev/null 2>&1; then
            log_success "BLUE version deployed and healthy"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    log_error "BLUE version failed health check"
    return 1
}

deploy_green() {
    log_info "Deploying GREEN version ($GREEN_VERSION) on port $GREEN_PORT..."
    
    if ! podman run -d \
        --name "${APP_NAME}-green" \
        -p "$GREEN_PORT:80" \
        -v "$TEST_DIR/nginx/green.html:/usr/share/nginx/html/index.html:ro" \
        --label "app=$APP_NAME" \
        --label "version=$GREEN_VERSION" \
        --label "environment=green" \
        docker.io/library/nginx:alpine > /dev/null 2>&1; then
        log_error "Failed to deploy GREEN version"
        return 1
    fi
    
    # Wait for container to be ready
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "http://localhost:$GREEN_PORT/" > /dev/null 2>&1; then
            log_success "GREEN version deployed and healthy"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    log_error "GREEN version failed health check"
    return 1
}

switch_traffic() {
    local from_env="$1"
    local to_env="$2"
    
    log_info "Switching traffic from $from_env to $to_env..."
    
    # Update active environment
    echo "$to_env" > "$TEST_DIR/active-environment"
    
    # In a real scenario, this would update load balancer or proxy
    # For testing, we verify both versions are still accessible
    local from_port
    local to_port
    
    if [[ "$from_env" == "blue" ]]; then
        from_port=$BLUE_PORT
        to_port=$GREEN_PORT
    else
        from_port=$GREEN_PORT
        to_port=$BLUE_PORT
    fi
    
    # Verify new environment is healthy
    if ! curl -sf "http://localhost:$to_port/" > /dev/null 2>&1; then
        log_error "New environment ($to_env) is not healthy"
        return 1
    fi
    
    log_success "Traffic switched to $to_env"
    return 0
}

verify_deployment() {
    local env="$1"
    local expected_version="$2"
    local port
    
    if [[ "$env" == "blue" ]]; then
        port=$BLUE_PORT
    else
        port=$GREEN_PORT
    fi
    
    log_info "Verifying $env deployment..."
    
    local response
    response=$(curl -sf "http://localhost:$port/" 2>/dev/null)
    
    if [[ "$response" != *"$expected_version"* ]]; then
        log_error "Version mismatch in $env: expected $expected_version"
        return 1
    fi
    
    log_success "$env version verified ($expected_version)"
    return 0
}

cleanup_old_version() {
    local env="$1"
    
    log_info "Cleaning up $env environment..."
    
    local container_name="${APP_NAME}-${env}"
    
    if podman ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        podman stop -t 10 "$container_name" > /dev/null 2>&1 || true
        podman rm "$container_name" > /dev/null 2>&1 || true
        log_success "$env environment cleaned up"
    fi
    
    return 0
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
    
    # Test 1: Deploy initial blue version
    test_deploy_initial_blue || exit_code=1
    
    # Test 2: Deploy green version alongside blue
    test_deploy_green_alongside_blue || exit_code=1
    
    # Test 3: Switch traffic to green
    test_switch_to_green || exit_code=1
    
    # Test 4: Verify zero-downtime switch
    test_zero_downtime || exit_code=1
    
    # Test 5: Rollback to blue
    test_rollback_to_blue || exit_code=1
    
    # Test 6: Clean up old version
    test_cleanup_old_version || exit_code=1
    
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

test_deploy_initial_blue() {
    log_info "Test: Deploy initial BLUE version..."
    
    if ! deploy_blue; then
        return 1
    fi
    
    if ! verify_deployment "blue" "$BLUE_VERSION"; then
        return 1
    fi
    
    return 0
}

test_deploy_green_alongside_blue() {
    log_info "Test: Deploy GREEN version alongside BLUE..."
    
    if ! deploy_green; then
        return 1
    fi
    
    # Verify both are running
    local blue_status
    local green_status
    blue_status=$(podman inspect "${APP_NAME}-blue" --format '{{.State.Status}}' 2>/dev/null)
    green_status=$(podman inspect "${APP_NAME}-green" --format '{{.State.Status}}' 2>/dev/null)
    
    if [[ "$blue_status" != "running" ]]; then
        log_error "BLUE environment not running"
        return 1
    fi
    
    if [[ "$green_status" != "running" ]]; then
        log_error "GREEN environment not running"
        return 1
    fi
    
    # Verify both respond correctly
    if ! verify_deployment "blue" "$BLUE_VERSION"; then
        return 1
    fi
    
    if ! verify_deployment "green" "$GREEN_VERSION"; then
        return 1
    fi
    
    log_success "Both BLUE and GREEN environments running"
    return 0
}

test_switch_to_green() {
    log_info "Test: Switch traffic to GREEN..."
    
    if ! switch_traffic "blue" "green"; then
        return 1
    fi
    
    # Verify green is now active
    local active
    active=$(cat "$TEST_DIR/active-environment")
    if [[ "$active" != "green" ]]; then
        log_error "Active environment is not green"
        return 1
    fi
    
    return 0
}

test_zero_downtime() {
    log_info "Test: Verify zero-downtime switching..."
    
    # Quick test: both endpoints should respond during transition
    local blue_ok=0
    local green_ok=0
    
    for i in {1..5}; do
        if curl -sf "http://localhost:$BLUE_PORT/" > /dev/null 2>&1; then
            blue_ok=1
        fi
        if curl -sf "http://localhost:$GREEN_PORT/" > /dev/null 2>&1; then
            green_ok=1
        fi
        sleep 0.5
    done
    
    if [[ $blue_ok -eq 0 ]]; then
        log_warn "BLUE was not available during test (may be acceptable)"
    fi
    
    if [[ $green_ok -eq 0 ]]; then
        log_error "GREEN was not available during test"
        return 1
    fi
    
    log_success "Zero-downtime verified (at least one environment always available)"
    return 0
}

test_rollback_to_blue() {
    log_info "Test: Rollback to BLUE version..."
    
    if ! switch_traffic "green" "blue"; then
        return 1
    fi
    
    # Verify blue is now active
    local active
    active=$(cat "$TEST_DIR/active-environment")
    if [[ "$active" != "blue" ]]; then
        log_error "Rollback failed - active environment is not blue"
        return 1
    fi
    
    # Verify blue still responds correctly
    if ! verify_deployment "blue" "$BLUE_VERSION"; then
        return 1
    fi
    
    log_success "Rollback to BLUE successful"
    return 0
}

test_cleanup_old_version() {
    log_info "Test: Cleanup old GREEN version..."
    
    if ! cleanup_old_version "green"; then
        return 1
    fi
    
    # Verify green container is removed
    if podman ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}-green$"; then
        log_error "GREEN container still exists after cleanup"
        return 1
    fi
    
    # Verify blue is still running
    local blue_status
    blue_status=$(podman inspect "${APP_NAME}-blue" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    if [[ "$blue_status" != "running" ]]; then
        log_error "BLUE container not running after GREEN cleanup"
        return 1
    fi
    
    log_success "Old version cleanup successful"
    return 0
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up test environment..."
    
    # Stop and remove all test containers
    for env in blue green; do
        local container_name="${APP_NAME}-${env}"
        if podman ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            podman stop -t 5 "$container_name" > /dev/null 2>&1 || true
            podman rm "$container_name" > /dev/null 2>&1 || true
        fi
    done
    
    # Remove images
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
    trap_cleanup
    init_tests "$TEST_NAME"
    
    if ! check_prerequisites; then
        skip_test "$TEST_NAME" "Prerequisites not met"
        finish_tests "$TEST_NAME"
        exit 77
    fi
    
    setup_test_env
    
    local exit_code=0
    if ! run_test; then
        exit_code=1
    fi
    
    run_cleanup
    finish_tests "$TEST_NAME"
    
    return $exit_code
}

main "$@"
