#!/bin/bash
#
# Chaos Test: DNS Failure
# Tests system behavior during DNS resolution failures
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="chaos-dns-failure"
APP_NAME="chaos-dns-test"
HTTP_PORT=0
DNS_FAILURE_DURATION=20
RECOVERY_TIMEOUT=60
TEST_TIMEOUT=180

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local required=(podman curl iptables)
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
    
    # Check for root (needed for iptables)
    if [[ $EUID -ne 0 ]]; then
        log_warn "DNS failure tests require root for iptables manipulation"
        log_warn "Some tests may fail without root privileges"
    fi
    
    log_info "Prerequisites check passed"
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up DNS failure test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    HTTP_PORT=$(get_free_port)
    export HTTP_PORT
    
    # Create a simple application that makes DNS queries
    mkdir -p "$TEST_DIR/app"
    
    cat > "$TEST_DIR/app/dns-test.sh" << 'EOF'
#!/bin/sh
# Simple DNS test script
echo "HTTP/1.1 200 OK"
echo "Content-Type: text/plain"
echo ""

# Try to resolve some common domains
for domain in google.com github.com cloudflare.com; do
    if nslookup "$domain" > /dev/null 2>&1; then
        echo "OK: $domain"
    else
        echo "FAIL: $domain"
    fi
done
EOF
    chmod +x "$TEST_DIR/app/dns-test.sh"
    
    # Create index page
    cat > "$TEST_DIR/app/index.html" << EOF
<!DOCTYPE html>
<html>
<head><title>DNS Test</title></head>
<body>
<h1>DNS Failure Test</h1>
<p>Container ID: $(hostname)</p>
<p>Time: $(date)</p>
</body>
</html>
EOF
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
}

# ============================================
# Chaos Functions
# ============================================

deploy_application() {
    log_info "Deploying test application..."
    
    if ! podman run -d \
        --name "$APP_NAME" \
        -p "$HTTP_PORT:80" \
        -v "$TEST_DIR/app:/usr/share/nginx/html:ro" \
        --dns="8.8.8.8" \
        --dns="8.8.4.4" \
        --label "app=$APP_NAME" \
        docker.io/library/nginx:alpine > /dev/null 2>&1; then
        log_error "Failed to deploy application"
        return 1
    fi
    
    # Wait for container to be ready
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
            log_success "Application is ready"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    log_error "Application failed to start"
    return 1
}

block_dns() {
    log_info "Blocking DNS queries..."
    
    if [[ $EUID -ne 0 ]]; then
        log_warn "Cannot block DNS without root privileges"
        return 77  # Skip exit code
    fi
    
    # Block common DNS ports
    iptables -A OUTPUT -p udp --dport 53 -j DROP
    iptables -A OUTPUT -p tcp --dport 53 -j DROP
    
    # Block to common DNS servers
    for dns in "8.8.8.8" "8.8.4.4" "1.1.1.1"; do
        iptables -A OUTPUT -d "$dns" -j DROP 2>/dev/null || true
    done
    
    # Schedule removal
    (
        sleep "$DNS_FAILURE_DURATION"
        iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
        for dns in "8.8.8.8" "8.8.4.4" "1.1.1.1"; do
            iptables -D OUTPUT -d "$dns" -j DROP 2>/dev/null || true
        done
        log_info "DNS blocking removed"
    ) &
    
    log_success "DNS queries blocked for ${DNS_FAILURE_DURATION}s"
    return 0
}

test_dns_resolution() {
    local from_container="${1:-}"
    
    log_info "Testing DNS resolution..."
    
    local domains=("google.com" "github.com" "cloudflare.com")
    local success_count=0
    
    for domain in "${domains[@]}"; do
        local result
        if [[ -n "$from_container" ]]; then
            # Test from inside container
            result=$(podman exec "$from_container" nslookup "$domain" 2>&1 || echo "FAILED")
        else
            # Test from host
            result=$(nslookup "$domain" 2>&1 || echo "FAILED")
        fi
        
        if [[ "$result" != *"FAILED"* && "$result" != *"NXDOMAIN"* && "$result" != *"connection timed out"* ]]; then
            success_count=$((success_count + 1))
            log_info "  $domain: OK"
        else
            log_info "  $domain: FAIL"
        fi
    done
    
    log_info "DNS resolution: $success_count/${#domains[@]} domains resolved"
    
    if [[ $success_count -eq ${#domains[@]} ]]; then
        return 0
    else
        return 1
    fi
}

test_container_behavior() {
    log_info "Testing container behavior during DNS failure..."
    
    # Check if container is still running
    local status
    status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    log_info "Container status: $status"
    
    # Test if HTTP endpoint still works
    local http_ok=0
    if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
        http_ok=1
        log_info "HTTP endpoint responding"
    else
        log_warn "HTTP endpoint not responding"
    fi
    
    # Check container logs for DNS errors
    local dns_errors
    dns_errors=$(podman logs "$APP_NAME" 2>&1 | grep -i "error\|fail\|timeout" | wc -l)
    log_info "Container log errors: $dns_errors"
    
    return 0
}

measure_recovery() {
    log_info "Measuring DNS recovery..."
    
    local start_time=$SECONDS
    local recovered=0
    local elapsed=0
    
    while [[ $elapsed -lt $RECOVERY_TIMEOUT ]]; do
        # Test DNS resolution
        if test_dns_resolution > /dev/null 2>&1; then
            recovered=1
            break
        fi
        
        sleep 2
        elapsed=$((SECONDS - start_time))
        
        # Progress indicator
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log_info "DNS recovery in progress... (${elapsed}s elapsed)"
        fi
    done
    
    local recovery_time=$((SECONDS - start_time))
    
    if [[ $recovered -eq 1 ]]; then
        log_success "DNS recovered in ${recovery_time}s"
        return 0
    else
        log_error "DNS did not recover within ${RECOVERY_TIMEOUT}s"
        return 1
    fi
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
    
    # Phase 1: Deploy application
    if ! deploy_application; then
        log_error "Deployment failed"
        return 1
    fi
    
    # Phase 2: Baseline DNS test
    log_info "Phase 2: Baseline DNS test..."
    if test_dns_resolution; then
        log_success "DNS working normally"
    else
        log_warn "DNS issues detected in baseline"
    fi
    
    # Phase 3: Block DNS
    log_info "Phase 3: Blocking DNS..."
    local block_result
    if ! block_dns; then
        block_result=$?
        if [[ $block_result -eq 77 ]]; then
            skip_test "dns_block" "Root required for DNS blocking"
            exit_code=77
        else
            exit_code=1
        fi
    fi
    
    # Wait a moment for block to take effect
    sleep 2
    
    # Phase 4: Test DNS failure
    log_info "Phase 4: Testing DNS failure..."
    if test_dns_resolution; then
        log_warn "DNS still working (block may have failed)"
    else
        log_success "DNS blocked successfully"
    fi
    
    # Test container behavior during DNS failure
    test_container_behavior
    
    # Phase 5: Wait for DNS failure period
    log_info "Phase 5: Waiting for DNS failure period..."
    sleep "$DNS_FAILURE_DURATION"
    sleep 3  # Extra time for recovery
    
    # Phase 6: Measure recovery
    log_info "Phase 6: Measuring DNS recovery..."
    if [[ $exit_code -ne 77 ]]; then
        if ! measure_recovery; then
            exit_code=1
        fi
    fi
    
    # Phase 7: Final verification
    log_info "Phase 7: Final verification..."
    
    # Verify application is still healthy
    if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
        log_success "Application still responding after DNS failure"
    else
        log_error "Application not responding"
        exit_code=1
    fi
    
    # Final DNS test
    if test_dns_resolution; then
        log_success "DNS fully recovered"
    else
        log_warn "DNS may still have issues"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "========================================"
    if [[ $exit_code -eq 0 ]]; then
        log_success "DNS failure test passed in ${duration}s"
    elif [[ $exit_code -eq 77 ]]; then
        log_warn "DNS failure test skipped (requires root)"
        exit_code=0  # Don't fail if skipped
    else
        log_error "DNS failure test failed after ${duration}s"
    fi
    log_info "========================================"
    
    return $exit_code
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up DNS failure test environment..."
    
    # Remove iptables rules if they exist
    if [[ $EUID -eq 0 ]]; then
        iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null || true
        for dns in "8.8.8.8" "8.8.4.4" "1.1.1.1"; do
            iptables -D OUTPUT -d "$dns" -j DROP 2>/dev/null || true
        done
    fi
    
    # Stop and remove container
    if podman ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
        podman stop -t 5 "$APP_NAME" > /dev/null 2>&1 || true
        podman rm "$APP_NAME" > /dev/null 2>&1 || true
    fi
    
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
    # Initialize SECONDS
    SECONDS=0
    
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
