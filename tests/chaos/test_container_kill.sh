#!/bin/bash
#
# Chaos Test: Random Container Termination
# Tests system resilience when containers are randomly killed
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="chaos-container-kill"
APP_NAME="chaos-test-app"
NUM_CONTAINERS=5
CHAOS_DURATION=30
RECOVERY_TIMEOUT=60
TEST_TIMEOUT=180

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
    log_info "Setting up chaos test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    # Create test application instances
    mkdir -p "$TEST_DIR/containers"
    CONTAINER_PORTS=()
    
    for i in $(seq 1 $NUM_CONTAINERS); do
        local port=$(get_free_port)
        CONTAINER_PORTS+=("$port")
        
        # Create unique content for each container
        mkdir -p "$TEST_DIR/containers/container-$i"
        cat > "$TEST_DIR/containers/container-$i/index.html" << EOF
<!DOCTYPE html>
<html>
<head><title>Container $i</title></head>
<body><h1>Container $i - Instance ID: $(uuidgen 2>/dev/null || echo $RANDOM)</h1></body>
</html>
EOF
    done
    
    export CONTAINER_PORTS
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
    log_info "Will deploy $NUM_CONTAINERS containers"
}

# ============================================
# Chaos Functions
# ============================================

deploy_containers() {
    log_info "Deploying $NUM_CONTAINERS containers..."
    
    for i in $(seq 1 $NUM_CONTAINERS); do
        local port="${CONTAINER_PORTS[$((i-1))]}"
        local container_name="${APP_NAME}-$i"
        
        if ! podman run -d \
            --name "$container_name" \
            -p "$port:80" \
            -v "$TEST_DIR/containers/container-$i:/usr/share/nginx/html:ro" \
            --label "app=$APP_NAME" \
            --label "instance=$i" \
            --restart=always \
            docker.io/library/nginx:alpine > /dev/null 2>&1; then
            log_error "Failed to deploy container $i"
            return 1
        fi
        
        log_info "Deployed $container_name on port $port"
    done
    
    # Wait for all containers to be ready
    log_info "Waiting for all containers to be ready..."
    local all_ready=0
    local elapsed=0
    
    while [[ $elapsed -lt 30 && $all_ready -eq 0 ]]; do
        all_ready=1
        for i in $(seq 1 $NUM_CONTAINERS); do
            local port="${CONTAINER_PORTS[$((i-1))]}"
            if ! curl -sf "http://localhost:$port/" > /dev/null 2>&1; then
                all_ready=0
                break
            fi
        done
        
        if [[ $all_ready -eq 0 ]]; then
            sleep 1
            elapsed=$((elapsed + 1))
        fi
    done
    
    if [[ $all_ready -eq 1 ]]; then
        log_success "All $NUM_CONTAINERS containers are ready"
        return 0
    else
        log_error "Not all containers became ready"
        return 1
    fi
}

get_running_containers() {
    podman ps --format '{{.Names}}' --filter "name=${APP_NAME}-" --filter "status=running" 2>/dev/null
}

get_all_containers() {
    podman ps -a --format '{{.Names}}' --filter "name=${APP_NAME}-" 2>/dev/null
}

chaos_kill_random() {
    log_info "Starting chaos: random container kills for ${CHAOS_DURATION}s..."
    
    local end_time=$((SECONDS + CHAOS_DURATION))
    local kills=0
    
    while [[ $SECONDS -lt $end_time ]]; do
        local containers
        containers=$(get_running_containers)
        
        if [[ -z "$containers" ]]; then
            log_warn "No running containers to kill"
            break
        fi
        
        # Pick random container
        local container
        container=$(echo "$containers" | shuf -n 1)
        
        log_info "CHAOS: Killing $container"
        
        # Kill with SIGKILL for immediate termination
        if podman kill -s SIGKILL "$container" > /dev/null 2>&1; then
            kills=$((kills + 1))
        fi
        
        # Random delay between kills (1-5 seconds)
        local delay=$((1 + RANDOM % 5))
        sleep "$delay"
    done
    
    log_info "Chaos complete: killed $kills containers"
    return 0
}

measure_recovery() {
    log_info "Measuring recovery..."
    
    local start_time=$SECONDS
    local recovered=0
    local elapsed=0
    
    while [[ $elapsed -lt $RECOVERY_TIMEOUT ]]; do
        local running_count
        running_count=$(get_running_containers | wc -l)
        
        if [[ "$running_count" -eq "$NUM_CONTAINERS" ]]; then
            recovered=1
            break
        fi
        
        sleep 1
        elapsed=$((SECONDS - start_time))
        
        # Progress indicator
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log_info "Recovery progress: $running_count/$NUM_CONTAINERS containers running (${elapsed}s elapsed)"
        fi
    done
    
    local recovery_time=$((SECONDS - start_time))
    
    if [[ $recovered -eq 1 ]]; then
        log_success "All containers recovered in ${recovery_time}s"
        return 0
    else
        log_error "Recovery incomplete after ${RECOVERY_TIMEOUT}s"
        return 1
    fi
}

verify_service_health() {
    log_info "Verifying service health..."
    
    local healthy=0
    local total=0
    
    for i in $(seq 1 $NUM_CONTAINERS); do
        local port="${CONTAINER_PORTS[$((i-1))]}"
        total=$((total + 1))
        
        if curl -sf "http://localhost:$port/" > /dev/null 2>&1; then
            healthy=$((healthy + 1))
        else
            log_warn "Container $i not responding on port $port"
        fi
    done
    
    log_info "Service health: $healthy/$total containers responding"
    
    # Accept if at least 80% are healthy
    local threshold=$((NUM_CONTAINERS * 80 / 100))
    if [[ $healthy -ge $threshold ]]; then
        return 0
    else
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
    
    # Phase 1: Deploy containers
    if ! deploy_containers; then
        log_error "Deployment phase failed"
        return 1
    fi
    
    # Phase 2: Verify initial health
    log_info "Phase 2: Verify initial health..."
    if ! verify_service_health; then
        log_error "Initial health check failed"
        exit_code=1
    fi
    
    # Phase 3: Execute chaos
    log_info "Phase 3: Execute chaos..."
    chaos_kill_random
    
    # Phase 4: Measure recovery
    log_info "Phase 4: Measure recovery..."
    if ! measure_recovery; then
        exit_code=1
    fi
    
    # Phase 5: Verify final health
    log_info "Phase 5: Verify final health..."
    if ! verify_service_health; then
        log_error "Final health check failed"
        exit_code=1
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "========================================"
    if [[ $exit_code -eq 0 ]]; then
        log_success "Chaos test passed in ${duration}s"
    else
        log_error "Chaos test failed after ${duration}s"
    fi
    log_info "========================================"
    
    return $exit_code
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up chaos test environment..."
    
    # Stop and remove all test containers
    local containers
    containers=$(get_all_containers)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read -r container; do
            podman stop -t 2 "$container" > /dev/null 2>&1 || true
            podman rm "$container" > /dev/null 2>&1 || true
        done
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
    # Initialize SECONDS for timing
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
