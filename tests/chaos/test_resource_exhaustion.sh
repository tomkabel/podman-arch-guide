#!/bin/bash
#
# Chaos Test: Resource Exhaustion
# Tests system behavior under CPU and memory pressure
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="chaos-resource-exhaustion"
APP_NAME="chaos-resource-test"
HTTP_PORT=0
STRESS_DURATION=20
RECOVERY_TIMEOUT=60
TEST_TIMEOUT=180
MEMORY_PRESSURE_MB=500  # Amount of memory to consume

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
    
    log_info "Prerequisites check passed"
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up resource exhaustion test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    HTTP_PORT=$(get_free_port)
    export HTTP_PORT
    
    # Create monitoring script
    cat > "$TEST_DIR/monitor.sh" << 'EOF'
#!/bin/bash
container="$1"
logfile="$2"
while true; do
    timestamp=$(date -Iseconds)
    cpu=$(podman stats "$container" --no-stream --format '{{.CPUPerc}}' 2>/dev/null || echo "N/A")
    mem=$(podman stats "$container" --no-stream --format '{{.MemUsage}}' 2>/dev/null || echo "N/A")
    echo "$timestamp CPU:$cpu MEM:$mem" >> "$logfile"
    sleep 1
done
EOF
    chmod +x "$TEST_DIR/monitor.sh"
    
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
        --memory="1g" \
        --cpus="1.0" \
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

consume_memory() {
    log_info "Creating memory pressure (${MEMORY_PRESSURE_MB}MB)..."
    
    # Create memory pressure inside the container
    podman exec "$APP_NAME" sh -c "
        # Try to allocate memory
        if command -v python3 >/dev/null 2>&1; then
            python3 -c \"data = 'x' * ($MEMORY_PRESSURE_MB * 1024 * 1024); import time; time.sleep($STRESS_DURATION)\" &
        elif command -v dd >/dev/null 2>&1; then
            dd if=/dev/zero of=/tmp/memory-fill bs=1M count=$MEMORY_PRESSURE_MB 2>/dev/null &
        else
            # Simple memory allocation using shell
            for i in \$(seq 1 $MEMORY_PRESSURE_MB); do
                eval 'VAR_\$i=\$(head -c 1048576 /dev/zero)' &
            done
        fi
        echo \$! > /tmp/stress.pid
    " 2>/dev/null || true
    
    # Also create system-wide memory pressure
    (
        if command -v stress-ng &> /dev/null; then
            stress-ng --vm 2 --vm-bytes "${MEMORY_PRESSURE_MB}M" --timeout "${STRESS_DURATION}s" 2>/dev/null
        elif command -v stress &> /dev/null; then
            stress --vm 2 --vm-bytes "${MEMORY_PRESSURE_MB}M" --timeout "${STRESS_DURATION}s" 2>/dev/null
        fi
    ) &
    
    log_success "Memory pressure initiated"
}

consume_cpu() {
    log_info "Creating CPU pressure..."
    
    # Create CPU pressure inside the container
    podman exec "$APP_NAME" sh -c "
        # Infinite loop to consume CPU
        for i in 1 2; do
            while true; do
                : # busy loop
            done &
            echo \$! >> /tmp/cpu-stress.pids
        done
    " 2>/dev/null || true
    
    # Also create system-wide CPU pressure
    (
        if command -v stress-ng &> /dev/null; then
            stress-ng --cpu 2 --timeout "${STRESS_DURATION}s" 2>/dev/null
        elif command -v stress &> /dev/null; then
            stress --cpu 2 --timeout "${STRESS_DURATION}s" 2>/dev/null
        fi
    ) &
    
    log_success "CPU pressure initiated"
}

stop_resource_pressure() {
    log_info "Stopping resource pressure..."
    
    # Stop memory pressure
    podman exec "$APP_NAME" sh -c "
        if [ -f /tmp/stress.pid ]; then
            kill \$(cat /tmp/stress.pid) 2>/dev/null || true
        fi
        rm -f /tmp/memory-fill 2>/dev/null || true
    " 2>/dev/null || true
    
    # Stop CPU pressure
    podman exec "$APP_NAME" sh -c "
        if [ -f /tmp/cpu-stress.pids ]; then
            for pid in \$(cat /tmp/cpu-stress.pids); do
                kill \$pid 2>/dev/null || true
            done
            rm -f /tmp/cpu-stress.pids
        fi
        # Kill any remaining stress processes
        pkill -f 'while true' 2>/dev/null || true
    " 2>/dev/null || true
    
    # Kill system-wide stress processes
    pkill -f stress-ng 2>/dev/null || true
    pkill -f stress 2>/dev/null || true
    
    log_success "Resource pressure stopped"
}

measure_resource_usage() {
    log_info "Current resource usage:"
    
    # Get container stats
    local stats
    stats=$(podman stats "$APP_NAME" --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null || echo "Container not running")
    
    echo "$stats"
    
    # Get system stats
    local mem_info
    mem_info=$(free -h 2>/dev/null | grep -E "Mem|Swap" || echo "Memory info unavailable")
    
    log_info "System memory:"
    echo "$mem_info"
}

verify_application_health() {
    log_info "Verifying application health under pressure..."
    
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
    
    if [[ $healthy -eq 1 ]]; then
        log_success "Application responded under resource pressure"
        return 0
    else
        log_warn "Application did not respond (may be under heavy load)"
        return 1
    fi
}

measure_recovery() {
    log_info "Measuring recovery from resource exhaustion..."
    
    # Stop the resource pressure
    stop_resource_pressure
    
    local start_time=$SECONDS
    local recovered=0
    local elapsed=0
    
    while [[ $elapsed -lt $RECOVERY_TIMEOUT ]]; do
        # Check if application is responding
        if curl -sf "http://localhost:$HTTP_PORT/" > /dev/null 2>&1; then
            # Check if container is healthy
            local status
            status=$(podman inspect "$APP_NAME" --format '{{.State.Status}}' 2>/dev/null)
            
            if [[ "$status" == "running" ]]; then
                recovered=1
                break
            fi
        fi
        
        sleep 2
        elapsed=$((SECONDS - start_time))
        
        # Progress indicator
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log_info "Recovery in progress... (${elapsed}s elapsed)"
            measure_resource_usage
        fi
    done
    
    local recovery_time=$((SECONDS - start_time))
    
    if [[ $recovered -eq 1 ]]; then
        log_success "Application recovered in ${recovery_time}s"
        return 0
    else
        log_error "Application did not recover within ${RECOVERY_TIMEOUT}s"
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
    
    # Phase 2: Baseline measurement
    log_info "Phase 2: Baseline resource measurement..."
    measure_resource_usage
    
    # Phase 3: Memory pressure
    log_info "Phase 3: Applying memory pressure..."
    consume_memory
    sleep 5
    measure_resource_usage
    verify_application_health || true  # Don't fail, just record
    
    # Phase 4: CPU pressure
    log_info "Phase 4: Applying CPU pressure..."
    consume_cpu
    sleep 5
    measure_resource_usage
    
    # Wait for stress duration
    log_info "Waiting ${STRESS_DURATION}s for stress to complete..."
    sleep "$STRESS_DURATION"
    
    # Phase 5: Recovery
    log_info "Phase 5: Measuring recovery..."
    if ! measure_recovery; then
        exit_code=1
    fi
    
    # Phase 6: Final verification
    log_info "Phase 6: Final verification..."
    measure_resource_usage
    
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
        log_success "Resource exhaustion test passed in ${duration}s"
    else
        log_error "Resource exhaustion test failed after ${duration}s"
    fi
    log_info "========================================"
    
    return $exit_code
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up resource exhaustion test environment..."
    
    # Stop any running stress processes
    stop_resource_pressure
    
    # Stop and remove container
    if podman ps -a --format '{{.Names}}' | grep -q "^${APP_NAME}$"; then
        podman stop -t 5 "$APP_NAME" > /dev/null 2>&1 || true
        podman rm "$APP_NAME" > /dev/null 2>&1 || true
    fi
    
    # Kill any remaining stress processes
    pkill -9 -f stress-ng 2>/dev/null || true
    pkill -9 -f stress 2>/dev/null || true
    
    # Remove images
    podman rmi docker.io/library/nginx:alpine > /dev/null 2>&1 || true
    podman rmi docker.io/library/alpine:latest > /dev/null 2>&1 || true
    
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
