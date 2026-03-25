#!/bin/bash
#
# Integration Test: Multi-Node Cluster
# Tests multi-node deployment (uses Vagrant/LXC if available)
# Marked as manual if no VM/container technology available
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../testlib.sh"

# ============================================
# Test Configuration
# ============================================

TEST_NAME="multi-node-deployment"
APP_NAME="test-multi-node"
APP_VERSION="1.0.0"
NODES=("node1" "node2" "node3")
NETWORK_NAME="test-cluster-net"
TEST_TIMEOUT=180

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    log_info "Checking prerequisites for multi-node test..."
    
    # Check for podman
    if ! command -v podman &> /dev/null; then
        log_error "Podman not found"
        return 1
    fi
    
    # Check if podman supports pods (for multi-container simulation)
    if ! podman pod --help &> /dev/null; then
        log_warn "Podman pods not available, will use container groups"
    fi
    
    # Check for virtualization options (optional)
    local virt_available=""
    if command -v vagrant &> /dev/null; then
        virt_available="vagrant"
    elif command -v lxc &> /dev/null; then
        virt_available="lxc"
    elif command -v incus &> /dev/null; then
        virt_available="incus"
    fi
    
    if [[ -n "$virt_available" ]]; then
        log_info "Virtualization available: $virt_available"
    else
        log_info "No VM/LXC available, using container simulation mode"
    fi
    
    return 0
}

# ============================================
# Test Setup
# ============================================

setup_test_env() {
    log_info "Setting up test environment..."
    
    TEST_DIR=$(temp_test_dir)
    export TEST_DIR
    
    # Create podman network for simulated multi-node
    if ! podman network exists "$NETWORK_NAME" 2>/dev/null; then
        if ! podman network create "$NETWORK_NAME" > /dev/null 2>&1; then
            log_warn "Failed to create network, using default"
            NETWORK_NAME=""
        fi
    fi
    
    # Create container configuration for each "node"
    mkdir -p "$TEST_DIR/nodes"
    
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port=$((8080 + i))
        
        cat > "$TEST_DIR/nodes/${node}.conf" << EOF
NODE_NAME=$node
NODE_ID=$i
NODE_PORT=$port
APP_NAME=$APP_NAME
APP_VERSION=$APP_VERSION
EOF
    done
    
    # Create shared volume for "distributed storage"
    mkdir -p "$TEST_DIR/shared-data"
    
    # Register cleanup
    register_cleanup "cleanup_test_env"
    
    log_info "Test environment setup complete"
}

# ============================================
# Node Simulation Functions
# ============================================

deploy_node() {
    local node="$1"
    local node_id="$2"
    local port="$3"
    
    log_info "Deploying to $node (ID: $node_id, Port: $port)..."
    
    local container_name="${APP_NAME}-${node}"
    local network_arg=""
    if [[ -n "$NETWORK_NAME" ]]; then
        network_arg="--network $NETWORK_NAME"
    fi
    
    # Create a unique response for each node
    mkdir -p "$TEST_DIR/nodes/$node"
    cat > "$TEST_DIR/nodes/$node/index.html" << EOF
<!DOCTYPE html>
<html>
<head><title>$node</title></head>
<body>
<h1>Node: $node</h1>
<p>ID: $node_id</p>
<p>Version: $APP_VERSION</p>
</body>
</html>
EOF
    
    # Deploy container
    if ! podman run -d \
        --name "$container_name" \
        $network_arg \
        -p "$port:80" \
        -v "$TEST_DIR/nodes/$node:/usr/share/nginx/html:ro" \
        --label "app=$APP_NAME" \
        --label "node=$node" \
        --label "node-id=$node_id" \
        docker.io/library/nginx:alpine > /dev/null 2>&1; then
        log_error "Failed to deploy $node"
        return 1
    fi
    
    # Wait for container to be ready
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "http://localhost:$port/" > /dev/null 2>&1; then
            log_success "$node is ready"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    log_error "$node failed health check"
    return 1
}

verify_node_health() {
    local node="$1"
    local port="$2"
    
    local container_name="${APP_NAME}-${node}"
    
    # Check container status
    local status
    status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    
    if [[ "$status" != "running" ]]; then
        log_error "$node is not running (status: $status)"
        return 1
    fi
    
    # Check HTTP endpoint
    local response
    response=$(curl -sf "http://localhost:$port/" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        log_error "$node not responding on port $port"
        return 1
    fi
    
    # Verify node identity
    if [[ "$response" != *"$node"* ]]; then
        log_error "$node identity mismatch"
        return 1
    fi
    
    return 0
}

simulate_node_failure() {
    local node="$1"
    local container_name="${APP_NAME}-${node}"
    
    log_info "Simulating failure of $node..."
    
    if podman ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        podman stop -t 2 "$container_name" > /dev/null 2>&1 || true
        log_success "$node stopped"
    else
        log_warn "$node not running"
    fi
}

recover_node() {
    local node="$1"
    local node_id="$2"
    local port="$3"
    
    log_info "Recovering $node..."
    
    local container_name="${APP_NAME}-${node}"
    
    # Remove old container if exists
    if podman ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        podman rm -f "$container_name" > /dev/null 2>&1 || true
    fi
    
    # Redeploy
    deploy_node "$node" "$node_id" "$port"
}

# ============================================
# Cluster Operations
# ============================================

deploy_cluster() {
    log_info "Deploying cluster across ${#NODES[@]} nodes..."
    
    local failed=0
    
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port=$((8080 + i))
        
        if ! deploy_node "$node" "$i" "$port"; then
            failed=1
        fi
    done
    
    if [[ $failed -eq 1 ]]; then
        return 1
    fi
    
    log_success "Cluster deployment complete"
    return 0
}

verify_cluster_health() {
    log_info "Verifying cluster health..."
    
    local healthy=0
    local total=${#NODES[@]}
    
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port=$((8080 + i))
        
        if verify_node_health "$node" "$port"; then
            healthy=$((healthy + 1))
        fi
    done
    
    log_info "Cluster health: $healthy/$total nodes healthy"
    
    if [[ $healthy -eq $total ]]; then
        return 0
    else
        return 1
    fi
}

get_cluster_status() {
    log_info "Cluster Status:"
    printf "%-10s | %-10s | %-6s | %-10s\n" "NODE" "STATUS" "PORT" "RESPONSE"
    printf "-----------|------------|--------|------------\n"
    
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local container_name="${APP_NAME}-${node}"
        local port=$((8080 + i))
        
        local status
        status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        
        local response="-"
        if [[ "$status" == "running" ]]; then
            response=$(curl -sf "http://localhost:$port/" 2>/dev/null | grep -oP '(?<=<h1>).*?(?=</h1>)' || echo "no response")
        fi
        
        printf "%-10s | %-10s | %-6s | %-10s\n" "$node" "$status" "$port" "$response"
    done
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
    
    # Test 1: Deploy cluster
    test_deploy_cluster || exit_code=1
    
    # Test 2: Verify initial health
    test_initial_health || exit_code=1
    
    # Test 3: Simulate node failure and recovery
    test_node_failure_recovery || exit_code=1
    
    # Test 4: Test rolling restart
    test_rolling_restart || exit_code=1
    
    # Test 5: Verify cluster after operations
    test_final_verification || exit_code=1
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_info "========================================"
    if [[ $exit_code -eq 0 ]]; then
        log_success "All tests passed in ${duration}s"
    else
        log_error "Some tests failed after ${duration}s"
    fi
    log_info "========================================"
    
    # Show final status
    get_cluster_status
    
    return $exit_code
}

# ============================================
# Individual Test Cases
# ============================================

test_deploy_cluster() {
    log_info "Test: Deploy cluster across nodes..."
    
    if ! deploy_cluster; then
        log_error "Cluster deployment failed"
        return 1
    fi
    
    return 0
}

test_initial_health() {
    log_info "Test: Verify initial cluster health..."
    
    if ! verify_cluster_health; then
        log_error "Initial health check failed"
        return 1
    fi
    
    return 0
}

test_node_failure_recovery() {
    log_info "Test: Node failure and recovery simulation..."
    
    # Stop one node
    simulate_node_failure "node2"
    
    # Wait a moment
    sleep 2
    
    # Verify node2 is down
    local container_name="${APP_NAME}-node2"
    local status
    status=$(podman inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
    
    if [[ "$status" == "running" ]]; then
        log_error "Node2 should be stopped but is still running"
        return 1
    fi
    
    # Recover node2
    if ! recover_node "node2" "1" "8081"; then
        log_error "Node2 recovery failed"
        return 1
    fi
    
    # Verify all nodes healthy
    if ! verify_cluster_health; then
        log_error "Cluster not healthy after recovery"
        return 1
    fi
    
    log_success "Node failure and recovery test passed"
    return 0
}

test_rolling_restart() {
    log_info "Test: Rolling restart of cluster..."
    
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port=$((8080 + i))
        local container_name="${APP_NAME}-${node}"
        
        log_info "Restarting $node..."
        
        # Stop node
        podman stop -t 5 "$container_name" > /dev/null 2>&1 || true
        sleep 1
        
        # Start node
        podman start "$container_name" > /dev/null 2>&1
        
        # Wait for health
        local elapsed=0
        local healthy=0
        while [[ $elapsed -lt 20 ]]; do
            if verify_node_health "$node" "$port"; then
                healthy=1
                break
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        
        if [[ $healthy -eq 0 ]]; then
            log_error "$node did not become healthy after restart"
            return 1
        fi
        
        # Brief pause between restarts
        sleep 2
    done
    
    log_success "Rolling restart completed"
    return 0
}

test_final_verification() {
    log_info "Test: Final cluster verification..."
    
    if ! verify_cluster_health; then
        log_error "Final verification failed"
        return 1
    fi
    
    # Verify each node has correct identity
    for i in "${!NODES[@]}"; do
        local node="${NODES[$i]}"
        local port=$((8080 + i))
        local response
        
        response=$(curl -sf "http://localhost:$port/" 2>/dev/null)
        
        if [[ "$response" != *"$node"* ]]; then
            log_error "$node identity verification failed"
            return 1
        fi
    done
    
    log_success "Final verification passed"
    return 0
}

# ============================================
# Cleanup
# ============================================

cleanup_test_env() {
    log_info "Cleaning up test environment..."
    
    # Stop and remove all containers
    for node in "${NODES[@]}"; do
        local container_name="${APP_NAME}-${node}"
        if podman ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            podman stop -t 5 "$container_name" > /dev/null 2>&1 || true
            podman rm "$container_name" > /dev/null 2>&1 || true
        fi
    done
    
    # Remove network
    if [[ -n "$NETWORK_NAME" ]] && podman network exists "$NETWORK_NAME" 2>/dev/null; then
        podman network rm "$NETWORK_NAME" > /dev/null 2>&1 || true
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
