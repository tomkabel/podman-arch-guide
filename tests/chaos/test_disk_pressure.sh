#!/bin/bash
#
# Chaos Test: Disk Pressure
# Tests system behavior when disk is full
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="chaos-disk-pressure"
APP_NAME="chaos-disk-test"
HTTP_PORT=0
TEST_DIR_SIZE_MB=100  # Size of test directory partition
FILL_PERCENTAGE=95    # Percentage to fill
RECOVERY_TIMEOUT=60
TEST_TIMEOUT=180

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local required=(podman curl df dd)
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
    
    # Check available disk space
    local available_kb
    available_kb=$(df -k "${TEMP:-/tmp}" | tail -1 | awk '{print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt $TEST_DIR_SIZE_MB ]]; then
        log_error "Insufficient disk space: ${available_mb}MB available, ${TEST_DIR_SIZE_MB}MB required"
        return 1
    fi
    
    log_info "Prerequisites check passed (${available_mb}MB available)"
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up disk pressure test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    HTTP_PORT=$(get_free_port)
    export HTTP_PORT
    
    # Create a subdirectory for filling
    FILL_DIR="$TEST_DIR/fill"
    mkdir -p "$FILL_DIR"
    export FILL_DIR
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
    log_info "Fill directory: $FILL_DIR"
}

# ============================================
# Chaos Functions
# ============================================

deploy_application() {
    log_info "Deploying test application..."
    
    if ! podman run -d \
        --name "$APP_NAME" \
        -p "$HTTP_PORT:80" \
        -v "$TEST_DIR:/data:Z" \
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

get_disk_usage() {
    local path="${1:-$TEST_DIR}"
    df -h "$path" | tail -1
}

get_disk_usage_percent() {
    local path="${1:-$TEST_DIR}"
    df "$path" | tail -1 | awk '{print $5}' | tr -d '%'
}

get_disk_available_kb() {
    local path="${1:-$TEST_DIR}"
    df -k "$path" | tail -1 | awk '{print $4}'
}

create_disk_pressure() {
    log_info "Creating disk pressure (target: ${FILL_PERCENTAGE}% usage)..."
    
    local current_usage
    current_usage=$(get_disk_usage_percent "$FILL_DIR")
    
    log_info "Current disk usage: ${current_usage}%"
    
    # Calculate how much to fill
    local available_kb
    available_kb=$(get_disk_available_kb "$FILL_DIR")
    local available_mb=$((available_kb / 1024))
    
    # Fill 90% of available space
    local fill_mb=$((available_mb * 9 / 10))
    
    if [[ $fill_mb -gt 0 ]]; then
        log_info "Filling ${fill_mb}MB..."
        
        # Create large file in chunks to avoid memory issues
        local chunk_size=50  # MB per chunk
        local chunks=$((fill_mb / chunk_size))
        local remainder=$((fill_mb % chunk_size))
        
        for i in $(seq 1 $chunks); do
            local file="$FILL_DIR/fill_$i.tmp"
            dd if=/dev/zero of="$file" bs=1M count=$chunk_size conv=fsync 2>/dev/null || {
                log_warn "Disk full during fill (this is expected)"
                break
            }
            
            # Show progress every 100MB
            if [[ $((i % 2)) -eq 0 ]]; then
                local usage
                usage=$(get_disk_usage_percent "$FILL_DIR")
                log_info "Fill progress: ${usage}% used"
            fi
        done
        
        # Fill remainder
        if [[ $remainder -gt 0 ]]; then
            dd if=/dev/zero of="$FILL_DIR/fill_remainder.tmp" bs=1M count=$remainder 2>/dev/null || true
        fi
    fi
    
    # Also try to fill from inside the container
    log_info "Attempting to write from container..."
    podman exec "$APP_NAME" sh -c "
        for i in 1 2 3; do
            dd if=/dev/zero of=/data/fill_container_\$i.tmp bs=1M count=20 2>/dev/null || break
        done
    " 2>/dev/null || log_warn "Container write failed (expected when disk full)"
    
    local final_usage
    final_usage=$(get_disk_usage_percent "$FILL_DIR")
    log_success "Disk pressure created: ${final_usage}% used"
}

free_disk_space() {
    log_info "Freeing disk space..."
    
    # Remove fill files
    rm -f "$FILL_DIR"/fill_*.tmp 2>/dev/null || true
    rm -f "$TEST_DIR"/fill_*.tmp 2>/dev/null || true
    
    # Sync to ensure deletion is complete
    sync 2>/dev/null || true
    
    # Also clean up inside container
    podman exec "$APP_NAME" sh -c "rm -f /data/*.tmp 2>/dev/null || true" 2>/dev/null || true
    
    local usage
    usage=$(get_disk_usage_percent "$FILL_DIR")
    log_success "Disk space freed: ${usage}% used"
}

test_writing_under_pressure() {
    log_info "Testing write operations under disk pressure..."
    
    # Try to write a small file
    local test_file="$TEST_DIR/test_under_pressure.txt"
    
    if echo "test" > "$test_file" 2>/dev/null; then
        log_info "Write succeeded under pressure"
        rm -f "$test_file"
        return 0
    else
        log_warn "Write failed under pressure (expected behavior)"
        return 1
    fi
}

test_container_behavior() {
    log_info "Testing container behavior under disk pressure..."
    
    # Check container status
    local status
    status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    log_info "Container status: $status"
    
    # Try to access the application
    local can_respond=0
    if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
        can_respond=1
        log_info "Container is still responding"
    else
        log_warn "Container not responding (may be expected under disk pressure)"
    fi
    
    # Check if container logs are being written
    local log_size
    log_size=$(podman logs "$APP_NAME" 2>&1 | wc -c)
    log_info "Container log size: ${log_size} bytes"
    
    return 0
}

measure_recovery() {
    log_info "Measuring recovery from disk pressure..."
    
    free_disk_space
    
    local start_time=$SECONDS
    local recovered=0
    local elapsed=0
    
    while [[ $elapsed -lt $RECOVERY_TIMEOUT ]]; do
        # Test if we can write again
        if echo "test" > "$TEST_DIR/recovery_test.txt" 2>/dev/null; then
            rm -f "$TEST_DIR/recovery_test.txt"
            
            # Also verify application
            if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
                recovered=1
                break
            fi
        fi
        
        sleep 2
        elapsed=$((SECONDS - start_time))
    done
    
    local recovery_time=$((SECONDS - start_time))
    
    if [[ $recovered -eq 1 ]]; then
        log_success "System recovered in ${recovery_time}s"
        return 0
    else
        log_error "System did not recover within ${RECOVERY_TIMEOUT}s"
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
    
    # Phase 2: Baseline
    log_info "Phase 2: Baseline disk usage..."
    get_disk_usage
    
    # Phase 3: Create disk pressure
    log_info "Phase 3: Creating disk pressure..."
    create_disk_pressure
    get_disk_usage
    
    # Phase 4: Test behavior under pressure
    log_info "Phase 4: Testing behavior under pressure..."
    test_writing_under_pressure || true
    test_container_behavior
    
    # Phase 5: Recovery
    log_info "Phase 5: Measuring recovery..."
    if ! measure_recovery; then
        exit_code=1
    fi
    
    # Phase 6: Final verification
    log_info "Phase 6: Final verification..."
    get_disk_usage
    
    # Verify application is healthy
    if ! curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
        log_error "Application not responding after recovery"
        exit_code=1
    else
        log_success "Application fully recovered"
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "========================================"
    if [[ $exit_code -eq 0 ]]; then
        log_success "Disk pressure test passed in ${duration}s"
    else
        log_error "Disk pressure test failed after ${duration}s"
    fi
    log_info "========================================"
    
    return $exit_code
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up disk pressure test environment..."
    
    # Free disk space first
    free_disk_space 2>/dev/null || true
    
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
