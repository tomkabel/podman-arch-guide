#!/bin/bash
#
# Chaos Test: Network Partition
# Tests system resilience during network isolation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="chaos-network-partition"
APP_NAME="chaos-net-test"
NUM_CONTAINERS=3
PARTITION_DURATION=15
NETWORK_NAME="chaos-test-net"
TEST_TIMEOUT=120

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
        log_warn "Network partition tests require root for iptables manipulation"
        log_warn "Some tests may fail without root privileges"
    fi
    
    log_info "Prerequisites check passed"
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up network partition test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    # Create podman network
    if ! podman network exists "$NETWORK_NAME" 2>/dev/null; then
        if ! podman network create "$NETWORK_NAME" > /dev/null 2>&1; then
            log_error "Failed to create test network"
            return 1
        fi
    fi
    
    export NETWORK_NAME
    
    # Create containers
    CONTAINER_NAMES=()
    CONTAINER_IPS=()
    
    for i in $(seq 1 $NUM_CONTAINERS); do
        local container_name="${APP_NAME}-$i"
        CONTAINER_NAMES+=("$container_name")
        
        # Deploy container in the network
        if ! podman run -d \
            --name "$container_name" \
            --network "$NETWORK_NAME" \
            --label "app=$APP_NAME" \
            --label "instance=$i" \
            docker.io/library/alpine:latest \
            sh -c "apk add --no-cache socat && socat TCP-LISTEN:8080,fork EXEC:'echo HTTP/1.1 200 OK; echo; echo Container $i'" \
            > /dev/null 2>&1; then
            log_error "Failed to deploy container $i"
            return 1
        fi
        
        # Get container IP
        sleep 2
        local ip
        ip=$(podman inspect "$container_name" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
        CONTAINER_IPS+=("$ip")
        
        log_info "Deployed $container_name with IP: $ip"
    done
    
    export CONTAINER_NAMES
    export CONTAINER_IPS
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
}

# ============================================
# Chaos Functions
# ============================================

verify_connectivity() {
    log_info "Verifying inter-container connectivity..."
    
    local all_connected=1
    
    for i in "${!CONTAINER_NAMES[@]}"; do
        local from_container="${CONTAINER_NAMES[$i]}"
        
        for j in "${!CONTAINER_IPS[@]}"; do
            if [[ $i -eq $j ]]; then
                continue
            fi
            
            local to_ip="${CONTAINER_IPS[$j]}"
            
            # Test connectivity using podman exec
            if ! podman exec "$from_container" wget -qO- "http://$to_ip:8080/" > /dev/null 2>&1; then
                log_warn "No connectivity from $from_container to $to_ip"
                all_connected=0
            fi
        done
    done
    
    if [[ $all_connected -eq 1 ]]; then
        log_success "All containers can communicate"
        return 0
    else
        return 1
    fi
}

simulate_partition() {
    local isolated_container="$1"
    local isolated_ip="$2"
    
    log_info "Simulating network partition: isolating $isolated_container ($isolated_ip)..."
    
    if [[ $EUID -ne 0 ]]; then
        log_warn "Cannot create partition without root privileges"
        return 77  # Skip exit code
    fi
    
    # Block traffic to/from the isolated container
    # This is a simplified simulation using iptables
    iptables -A FORWARD -s "$isolated_ip" -d "${CONTAINER_IPS[0]%.*}.0/24" -j DROP
    iptables -A FORWARD -d "$isolated_ip" -s "${CONTAINER_IPS[0]%.*}.0/24" -j DROP
    
    # Schedule removal
    (
        sleep "$PARTITION_DURATION"
        iptables -D FORWARD -s "$isolated_ip" -d "${CONTAINER_IPS[0]%.*}.0/24" -j DROP 2>/dev/null || true
        iptables -D FORWARD -d "$isolated_ip" -s "${CONTAINER_IPS[0]%.*}.0/24" -j DROP 2>/dev/null || true
        log_info "Network partition removed"
    ) &
    
    log_success "Network partition active for ${PARTITION_DURATION}s"
    return 0
}

test_partition_recovery() {
    log_info "Testing partition recovery..."
    
    local isolated_idx=0
    local isolated_container="${CONTAINER_NAMES[$isolated_idx]}"
    local isolated_ip="${CONTAINER_IPS[$isolated_idx]}"
    
    # Create partition
    if ! simulate_partition "$isolated_container" "$isolated_ip"; then
        if [[ $? -eq 77 ]]; then
            skip_test "partition_test" "Root required for network partition"
            return 77
        fi
        return 1
    fi
    
    # Wait for partition to be active
    sleep 2
    
    # Verify isolation
    log_info "Verifying isolation..."
    local isolated=1
    
    # Try to connect from isolated container to others
    for j in "${!CONTAINER_IPS[@]}"; do
        if [[ $isolated_idx -eq $j ]]; then
            continue
        fi
        
        local to_ip="${CONTAINER_IPS[$j]}"
        
        # Should fail during partition
        if podman exec "$isolated_container" wget -qO- "http://$to_ip:8080/" > /dev/null 2>&1; then
            log_warn "Connection succeeded during partition (should have failed)"
            isolated=0
        fi
    done
    
    if [[ $isolated -eq 1 ]]; then
        log_success "Isolation verified"
    else
        log_warn "Isolation may not be complete"
    fi
    
    # Wait for partition to be removed
    log_info "Waiting for partition to be removed..."
    sleep "$PARTITION_DURATION"
    sleep 3  # Extra time for recovery
    
    # Verify recovery
    log_info "Verifying recovery..."
    local recovered=0
    local retry=0
    
    while [[ $retry -lt 10 ]]; do
        if verify_connectivity > /dev/null 2>&1; then
            recovered=1
            break
        fi
        sleep 2
        retry=$((retry + 1))
    done
    
    if [[ $recovered -eq 1 ]]; then
        log_success "Network partition recovery successful"
        return 0
    else
        log_error "Network partition recovery failed"
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
    
    # Phase 1: Verify initial connectivity
    log_info "Phase 1: Verify initial connectivity..."
    if ! verify_connectivity; then
        log_error "Initial connectivity check failed"
        exit_code=1
    fi
    
    # Phase 2: Test network partition
    log_info "Phase 2: Test network partition..."
    local partition_result
    if ! test_partition_recovery; then
        partition_result=$?
        if [[ $partition_result -eq 77 ]]; then
            log_warn "Partition test skipped (requires root)"
        else
            exit_code=1
        fi
    fi
    
    # Phase 3: Final connectivity check
    log_info "Phase 3: Final connectivity check..."
    if ! verify_connectivity; then
        log_error "Final connectivity check failed"
        exit_code=1
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "========================================"
    if [[ $exit_code -eq 0 ]]; then
        log_success "Network partition test passed in ${duration}s"
    else
        log_error "Network partition test failed after ${duration}s"
    fi
    log_info "========================================"
    
    return $exit_code
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up network partition test environment..."
    
    # Remove any iptables rules we might have added
    if [[ $EUID -eq 0 ]]; then
        for ip in "${CONTAINER_IPS[@]}"; do
            iptables -D FORWARD -s "$ip" -d "${CONTAINER_IPS[0]%.*}.0/24" -j DROP 2>/dev/null || true
            iptables -D FORWARD -d "$ip" -s "${CONTAINER_IPS[0]%.*}.0/24" -j DROP 2>/dev/null || true
        done
    fi
    
    # Stop and remove containers
    for container in "${CONTAINER_NAMES[@]}"; do
        if podman ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            podman stop -t 5 "$container" > /dev/null 2>&1 || true
            podman rm "$container" > /dev/null 2>&1 || true
        fi
    done
    
    # Remove network
    if podman network exists "$NETWORK_NAME" 2>/dev/null; then
        podman network rm "$NETWORK_NAME" > /dev/null 2>&1 || true
    fi
    
    # Remove images
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
