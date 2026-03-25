#!/usr/bin/env bats
#
# Unit Tests for Health Check Functions
# Tests health checking, probing, and status evaluation
#

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

load "$BATS_TEST_DIRNAME/../testlib.sh"

# ============================================
# Setup and Teardown
# ============================================

setup() {
    TEST_TEMP_DIR=$(temp_test_dir)
    export TEST_TEMP_DIR
    
    MOCK_DIR=$(mktemp -d)
    setup_mock_env "$MOCK_DIR"
    export MOCK_DIR
    
    create_mock_health_script
    
    # Start a mock HTTP server for testing
    start_mock_server
}

teardown() {
    stop_mock_server
    
    if [[ -d "${MOCK_DIR:-}" ]]; then
        cleanup_mock_env "$MOCK_DIR"
    fi
    
    if [[ -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================
# Helper Functions
# ============================================

create_mock_health_script() {
    cat > "$TEST_TEMP_DIR/health_check.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

# Default configuration
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-2}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-3}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/health}"

# Health check types
CHECK_TYPE_HTTP="http"
CHECK_TYPE_TCP="tcp"
CHECK_TYPE_COMMAND="command"
CHECK_TYPE_CONTAINER="container"

# HTTP health check
http_health_check() {
    local url="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"
    local expected_code="${3:-200}"
    
    local response
    local http_code
    
    response=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null) || {
        echo "unhealthy"
        return 1
    }
    
    if [[ "$response" == "$expected_code" ]]; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

# TCP health check
tcp_health_check() {
    local host="$1"
    local port="$2"
    local timeout="${3:-$HEALTH_CHECK_TIMEOUT}"
    
    if timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

# Command health check
command_health_check() {
    local cmd="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"
    
    if timeout "$timeout" bash -c "$cmd" >/dev/null 2>&1; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

# Container health check using podman
container_health_check() {
    local container="$1"
    local timeout="${2:-$HEALTH_CHECK_TIMEOUT}"
    
    # Check if container exists
    if ! podman ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "unhealthy: container not found"
        return 1
    fi
    
    # Check if container is running
    local status
    status=$(podman inspect "$container" --format='{{.State.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$status" != "running" ]]; then
        echo "unhealthy: container $status"
        return 1
    fi
    
    # Check container health if available
    local health
    health=$(podman inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "")
    if [[ -n "$health" && "$health" != "healthy" ]]; then
        echo "unhealthy: $health"
        return 1
    fi
    
    echo "healthy"
    return 0
}

# Comprehensive health check with retries
health_check_with_retry() {
    local check_type="$1"
    local target="$2"
    local retries="${3:-$HEALTH_CHECK_RETRIES}"
    local interval="${4:-$HEALTH_CHECK_INTERVAL}"
    
    local attempt=0
    local result
    
    while [[ $attempt -lt $retries ]]; do
        case "$check_type" in
            http)
                result=$(http_health_check "$target" 2>&1) && return 0
                ;;
            tcp)
                local host="${target%%:*}"
                local port="${target##*:}"
                result=$(tcp_health_check "$host" "$port" 2>&1) && return 0
                ;;
            command)
                result=$(command_health_check "$target" 2>&1) && return 0
                ;;
            container)
                result=$(container_health_check "$target" 2>&1) && return 0
                ;;
            *)
                echo "unknown check type: $check_type"
                return 1
                ;;
        esac
        
        attempt=$((attempt + 1))
        if [[ $attempt -lt $retries ]]; then
            sleep "$interval"
        fi
    done
    
    echo "$result"
    return 1
}

# Service dependency check
check_dependencies() {
    local -a deps=("$@")
    local failed_deps=()
    
    for dep in "${deps[@]}"; do
        local host="${dep%%:*}"
        local port="${dep##*:}"
        
        if ! tcp_health_check "$host" "$port" "2" >/dev/null; then
            failed_deps+=("$dep")
        fi
    done
    
    if [[ ${#failed_deps[@]} -gt 0 ]]; then
        echo "unhealthy: dependencies failed - ${failed_deps[*]}"
        return 1
    fi
    
    echo "healthy"
    return 0
}

# Aggregate health check for multiple endpoints
aggregate_health_check() {
    local -a endpoints=("$@")
    local failed=()
    local passed=0
    
    for endpoint in "${endpoints[@]}"; do
        local type="${endpoint%%|*}"
        local target="${endpoint#*|}"
        
        if ! health_check_with_retry "$type" "$target" "1" "0" >/dev/null; then
            failed+=("$endpoint")
        else
            passed=$((passed + 1))
        fi
    done
    
    local total=${#endpoints[@]}
    local health_pct=$((passed * 100 / total))
    
    echo "status:$([[ ${#failed[@]} -eq 0 ]] && echo "healthy" || echo "degraded")"
    echo "passed:$passed"
    echo "failed:${#failed[@]}"
    echo "health_pct:$health_pct"
    
    if [[ ${#failed[@]} -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Generate health report
health_report() {
    local service="$1"
    local status="$2"
    local details="${3:-}"
    
    cat << REPORT
{
  "service": "$service",
  "status": "$status",
  "timestamp": "$(date -Iseconds)",
  "details": "$details"
}
REPORT
}

# Main health check entry point
health_check_main() {
    local check_type="${1:-http}"
    local target="${2:-}"
    shift 2 || true
    
    if [[ -z "$target" ]]; then
        echo "Usage: health_check.sh <type> <target> [options]"
        return 1
    fi
    
    health_check_with_retry "$check_type" "$target" "$@"
}
EOF
    chmod +x "$TEST_TEMP_DIR/health_check.sh"
}

MOCK_SERVER_PID=""

start_mock_server() {
    # Create a simple mock HTTP server using Python or netcat
    python3 -m http.server 0 --directory "$TEST_TEMP_DIR" &>/dev/null &
    MOCK_SERVER_PID=$!
    sleep 1
    
    # Find the port
    MOCK_SERVER_PORT=$(ss -tlnp 2>/dev/null | grep "$MOCK_SERVER_PID" | awk '{print $4}' | cut -d':' -f2 | head -1)
    MOCK_SERVER_PORT=${MOCK_SERVER_PORT:-0}
    
    # Create a simple health endpoint
    mkdir -p "$TEST_TEMP_DIR/health"
    echo '{"status":"healthy"}' > "$TEST_TEMP_DIR/health/index.html"
}

stop_mock_server() {
    if [[ -n "$MOCK_SERVER_PID" ]]; then
        kill "$MOCK_SERVER_PID" 2>/dev/null || true
        wait "$MOCK_SERVER_PID" 2>/dev/null || true
    fi
}

# ============================================
# HTTP Health Check Tests
# ============================================

@test "http_health_check returns healthy for 200 response" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Create a mock successful endpoint
    mkdir -p "$TEST_TEMP_DIR"
    echo "OK" > "$TEST_TEMP_DIR/test_health"
    
    # Mock curl to return 200
    curl() {
        echo "200"
        return 0
    }
    export -f curl
    
    run http_health_check "http://localhost:8080/health"
    assert_output "healthy"
}

@test "http_health_check returns unhealthy for non-200 response" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    curl() {
        echo "500"
        return 0
    }
    export -f curl
    
    run http_health_check "http://localhost:8080/health"
    assert_output "unhealthy"
}

@test "http_health_check returns unhealthy on connection failure" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    curl() {
        return 1
    }
    export -f curl
    
    run http_health_check "http://invalid-host:9999/health"
    assert_output "unhealthy"
}

# ============================================
# TCP Health Check Tests
# ============================================

@test "tcp_health_check returns healthy for open port" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Use localhost:22 (SSH) as a likely open port
    if timeout 1 bash -c "</dev/tcp/localhost/22" 2>/dev/null; then
        run tcp_health_check "localhost" "22"
        assert_output "healthy"
    else
        skip "SSH not available on localhost:22"
    fi
}

@test "tcp_health_check returns unhealthy for closed port" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Use a port that's likely closed
    run tcp_health_check "localhost" "59999"
    assert_output "unhealthy"
}

@test "tcp_health_check respects timeout" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Start a command that will block
    (
        sleep 10
    ) &
    local blocker_pid=$!
    
    # Test with short timeout - should fail quickly
    local start_time=$(date +%s)
    run tcp_health_check "192.0.2.1" "80" "1"
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    kill "$blocker_pid" 2>/dev/null || true
    
    [[ $duration -le 2 ]]
}

# ============================================
# Command Health Check Tests
# ============================================

@test "command_health_check returns healthy for successful command" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run command_health_check "true"
    assert_output "healthy"
}

@test "command_health_check returns unhealthy for failed command" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run command_health_check "false"
    assert_output "unhealthy"
}

@test "command_health_check returns unhealthy for non-existent command" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run command_health_check "nonexistent_command_12345"
    assert_output "unhealthy"
}

# ============================================
# Container Health Check Tests
# ============================================

@test "container_health_check returns unhealthy for non-existent container" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run container_health_check "non-existent-container-xyz"
    assert_failure
    assert_output --partial "container not found"
}

# ============================================
# Retry Logic Tests
# ============================================

@test "health_check_with_retry succeeds on first attempt" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Mock successful HTTP check
    http_health_check() {
        echo "healthy"
        return 0
    }
    export -f http_health_check
    
    run health_check_with_retry "http" "http://test/health" "3" "0"
    assert_output "healthy"
}

@test "health_check_with_retry fails after all retries" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Mock failing HTTP check
    http_health_check() {
        echo "unhealthy"
        return 1
    }
    export -f http_health_check
    
    run health_check_with_retry "http" "http://test/health" "2" "0"
    assert_failure
}

@test "health_check_with_retry handles unknown check type" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run health_check_with_retry "unknown" "target" "1" "0"
    assert_failure
    assert_output --partial "unknown check type"
}

# ============================================
# Dependency Check Tests
# ============================================

@test "check_dependencies passes when all dependencies healthy" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Mock tcp_health_check to always succeed
    tcp_health_check() {
        return 0
    }
    export -f tcp_health_check
    
    run check_dependencies "localhost:80" "localhost:443"
    assert_output "healthy"
}

@test "check_dependencies fails when dependency unhealthy" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run check_dependencies "localhost:59999"
    assert_failure
    assert_output --partial "dependencies failed"
}

# ============================================
# Aggregate Health Check Tests
# ============================================

@test "aggregate_health_check reports all healthy" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Mock successful checks
    health_check_with_retry() {
        return 0
    }
    export -f health_check_with_retry
    
    run aggregate_health_check "http|http://test1" "http|http://test2"
    assert_output --partial "status:healthy"
    assert_output --partial "passed:2"
    assert_output --partial "health_pct:100"
}

@test "aggregate_health_check reports degraded" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    local call_count=0
    health_check_with_retry() {
        call_count=$((call_count + 1))
        if [[ $call_count -eq 1 ]]; then
            return 0
        else
            return 1
        fi
    }
    export -f health_check_with_retry
    export call_count
    
    run aggregate_health_check "http|http://test1" "http|http://test2"
    assert_output --partial "status:degraded"
    assert_output --partial "passed:1"
    assert_output --partial "failed:1"
}

# ============================================
# Health Report Tests
# ============================================

@test "health_report generates valid JSON" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run health_report "myservice" "healthy" "All checks passed"
    assert_output --partial '"service": "myservice"'
    assert_output --partial '"status": "healthy"'
    assert_output --partial '"details": "All checks passed"'
}

@test "health_report includes timestamp" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run health_report "test" "healthy"
    assert_output --partial '"timestamp":'
}

# ============================================
# Main Entry Point Tests
# ============================================

@test "health_check_main requires target argument" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    run health_check_main "http"
    assert_failure
}

@test "health_check_main accepts type and target" {
    source "$TEST_TEMP_DIR/health_check.sh"
    
    # Mock the check
    health_check_with_retry() {
        echo "healthy"
        return 0
    }
    export -f health_check_with_retry
    
    run health_check_main "http" "http://test/health"
    assert_output "healthy"
}

# ============================================
# BATS Assertions
# ============================================

assert_success() {
    [[ "$status" -eq 0 ]]
}

assert_failure() {
    [[ "$status" -ne 0 ]]
}

assert_output() {
    if [[ "$1" == "--partial" ]]; then
        [[ "$output" == *"$2"* ]]
    else
        [[ "$output" == *"$1"* ]]
    fi
}
