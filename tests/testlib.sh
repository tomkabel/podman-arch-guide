#!/bin/bash
#
# Test Library - Shared utilities for all tests
# Usage: source testlib.sh
#

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_START_TIME=0
JUNIT_OUTPUT=""

# Configuration
TEST_TIMEOUT=${TEST_TIMEOUT:-300}
VERBOSE=${VERBOSE:-0}
CI_MODE=${CI_MODE:-0}

# ============================================
# Logging Functions
# ============================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $*" >&2
    ((TESTS_FAILED++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $*"
    ((TESTS_SKIPPED++))
}

# ============================================
# Test Framework Functions
# ============================================

# Initialize test suite
init_tests() {
    local suite_name="${1:-Test Suite}"
    TEST_START_TIME=$(date +%s)
    
    log_info "Starting: $suite_name"
    
    if [[ "$CI_MODE" == "1" ]]; then
        JUNIT_OUTPUT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        JUNIT_OUTPUT+="<testsuite name=\"$suite_name\" timestamp=\"$(date -Iseconds)\">\n"
    fi
}

# Cleanup and finalize test suite
finish_tests() {
    local suite_name="${1:-Test Suite}"
    local end_time=$(date +%s)
    local duration=$((end_time - TEST_START_TIME))
    
    log_info "========================================"
    log_info "Test Results: $suite_name"
    log_info "========================================"
    log_info "Passed:  $TESTS_PASSED"
    log_info "Failed:  $TESTS_FAILED"
    log_info "Skipped: $TESTS_SKIPPED"
    log_info "Duration: ${duration}s"
    log_info "========================================"
    
    if [[ "$CI_MODE" == "1" ]]; then
        JUNIT_OUTPUT+="</testsuite>\n"
        echo -e "$JUNIT_OUTPUT" > "junit-${suite_name// /_}.xml"
        log_info "JUnit XML written to junit-${suite_name// /_}.xml"
    fi
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Run a single test case
run_test() {
    local test_name="$1"
    local test_func="$2"
    local start_time=$(date +%s)
    local test_output=""
    local test_error=""
    
    log_info "Running: $test_name"
    
    # Create temp file for capturing output
    local temp_output=$(mktemp)
    local temp_error=$(mktemp)
    
    # Run test with timeout
    if timeout "$TEST_TIMEOUT" bash -c "$test_func" > "$temp_output" 2> "$temp_error"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "$test_name (${duration}s)"
        
        if [[ "$VERBOSE" == "1" ]]; then
            cat "$temp_output"
        fi
        
        if [[ "$CI_MODE" == "1" ]]; then
            JUNIT_OUTPUT+="  <testcase name=\"$test_name\" time=\"${duration}\"/>\n"
        fi
        
        rm -f "$temp_output" "$temp_error"
        return 0
    else
        local exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ $exit_code -eq 124 ]]; then
            log_error "$test_name - TIMEOUT after ${TEST_TIMEOUT}s"
        else
            log_error "$test_name (${duration}s)"
        fi
        
        if [[ -s "$temp_output" ]]; then
            echo "  STDOUT:"
            sed 's/^/    /' "$temp_output"
        fi
        
        if [[ -s "$temp_error" ]]; then
            echo "  STDERR:"
            sed 's/^/    /' "$temp_error"
        fi
        
        if [[ "$CI_MODE" == "1" ]]; then
            JUNIT_OUTPUT+="  <testcase name=\"$test_name\" time=\"${duration}\">\n"
            JUNIT_OUTPUT+="    <failure message=\"Test failed\"><![CDATA[$(cat "$temp_error")]]></failure>\n"
            JUNIT_OUTPUT+="  </testcase>\n"
        fi
        
        rm -f "$temp_output" "$temp_error"
        return 1
    fi
}

# Skip a test with reason
skip_test() {
    local test_name="$1"
    local reason="$2"
    log_skip "$test_name - $reason"
    
    if [[ "$CI_MODE" == "1" ]]; then
        JUNIT_OUTPUT+="  <testcase name=\"$test_name\">\n"
        JUNIT_OUTPUT+="    <skipped message=\"$reason\"/>\n"
        JUNIT_OUTPUT+="  </testcase>\n"
    fi
}

# ============================================
# Assertion Functions
# ============================================

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"
    
    if [[ "$expected" != "$actual" ]]; then
        echo "Assertion failed: $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

assert_not_equals() {
    local not_expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"
    
    if [[ "$not_expected" == "$actual" ]]; then
        echo "Assertion failed: $message"
        echo "  Not expected: $not_expected"
        echo "  Actual:       $actual"
        return 1
    fi
}

assert_true() {
    local condition="$1"
    local message="${2:-Assertion failed: expected true}"
    
    if [[ -z "$condition" || "$condition" == "0" || "$condition" == "false" ]]; then
        echo "$message"
        return 1
    fi
}

assert_false() {
    local condition="$1"
    local message="${2:-Assertion failed: expected false}"
    
    if [[ -n "$condition" && "$condition" != "0" && "$condition" != "false" ]]; then
        echo "$message"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File does not exist: $file}"
    
    if [[ ! -f "$file" ]]; then
        echo "$message"
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory does not exist: $dir}"
    
    if [[ ! -d "$dir" ]]; then
        echo "$message"
        return 1
    fi
}

assert_command_exists() {
    local cmd="$1"
    local message="${2:-Command not found: $cmd}"
    
    if ! command -v "$cmd" &> /dev/null; then
        echo "$message"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String does not contain expected value}"
    
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "$message"
        echo "  Haystack: $haystack"
        echo "  Needle:   $needle"
        return 1
    fi
}

assert_exit_code() {
    local expected_code="$1"
    shift
    local output
    local exit_code
    
    output=$("$@" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}
    
    if [[ "$exit_code" != "$expected_code" ]]; then
        echo "Expected exit code $expected_code but got $exit_code"
        echo "Output: $output"
        return 1
    fi
}

# ============================================
# Podman Mock Functions
# ============================================

# Create a mock podman command for testing
create_podman_mock() {
    local mock_dir="${1:-$(mktemp -d)}"
    local mock_file="$mock_dir/podman"
    
    cat > "$mock_file" << 'EOF'
#!/bin/bash
# Mock podman for testing

MOCK_STATE_DIR="${MOCK_STATE_DIR:-/tmp/podman-mock-state}"
mkdir -p "$MOCK_STATE_DIR/containers" "$MOCK_STATE_DIR/images" "$MOCK_STATE_DIR/pods"

case "$1" in
    ps)
        if [[ "$*" == *"-q"* ]]; then
            ls "$MOCK_STATE_DIR/containers" 2>/dev/null || true
        else
            echo "CONTAINER ID  IMAGE   COMMAND  CREATED  STATUS  PORTS  NAMES"
            for container in "$MOCK_STATE_DIR/containers"/*; do
                [[ -f "$container" ]] || continue
                cat "$container"
            done
        fi
        ;;
    run)
        local name=""
        local image=""
        local cid=$(date +%s%N | cut -c1-12)
        
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --name) name="$2"; shift 2 ;;
                -*) shift ;;
                *) image="$1"; shift ;;
            esac
        done
        
        name="${name:-$cid}"
        echo "$cid  $image  /bin/sh  2 seconds ago  Up 2 seconds  $name" > "$MOCK_STATE_DIR/containers/$cid"
        echo "$cid"
        ;;
    stop)
        local cid="$2"
        if [[ -f "$MOCK_STATE_DIR/containers/$cid" ]]; then
            rm -f "$MOCK_STATE_DIR/containers/$cid"
            echo "$cid"
        else
            echo "Error: no such container: $cid" >&2
            exit 1
        fi
        ;;
    rm)
        local cid="$2"
        if [[ -f "$MOCK_STATE_DIR/containers/$cid" ]]; then
            rm -f "$MOCK_STATE_DIR/containers/$cid"
            echo "$cid"
        fi
        ;;
    images)
        echo "REPOSITORY  TAG   IMAGE ID   CREATED   SIZE"
        ls "$MOCK_STATE_DIR/images" 2>/dev/null | while read img; do
            echo "mock/$img  latest  abc123  1 day ago  100MB"
        done
        ;;
    pull)
        local image="$2"
        touch "$MOCK_STATE_DIR/images/${image//\//_}"
        echo "Trying to pull $image..."
        echo "$image:latest"
        ;;
    healthcheck)
        echo "healthy"
        ;;
    inspect)
        echo '[{"State":{"Status":"running","Health":{"Status":"healthy"}}}]'
        ;;
    version)
        echo "podman version 4.9.0"
        ;;
    info)
        echo '{"host":{"arch":"amd64","os":"linux"},"store":{"graphDriverName":"overlay"}}'
        ;;
    *)
        echo "mock: podman $*"
        ;;
esac
EOF
    chmod +x "$mock_file"
    echo "$mock_file"
}

# Setup mock environment
setup_mock_env() {
    local mock_dir="${1:-$(mktemp -d)}"
    export MOCK_STATE_DIR="$mock_dir/state"
    export PATH="$mock_dir:$PATH"
    mkdir -p "$MOCK_STATE_DIR"
    create_podman_mock "$mock_dir"
}

# Cleanup mock environment
cleanup_mock_env() {
    local mock_dir="$1"
    if [[ -d "$mock_dir" ]]; then
        rm -rf "$mock_dir"
    fi
}

# ============================================
# Container/Service Helpers
# ============================================

# Wait for container to be healthy
wait_for_container() {
    local container="$1"
    local timeout="${2:-60}"
    local interval="${3:-2}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if podman inspect "$container" --format='{{.State.Status}}' 2>/dev/null | grep -q "running"; then
            local health=$(podman inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "")
            if [[ -z "$health" || "$health" == "healthy" ]]; then
                return 0
            fi
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

# Wait for HTTP endpoint
wait_for_http() {
    local url="$1"
    local timeout="${2:-60}"
    local interval="${3:-2}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if curl -sf "$url" &>/dev/null; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

# ============================================
# Test Environment Functions
# ============================================

# Check prerequisites
check_prerequisites() {
    local missing=()
    
    for cmd in "$@"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing prerequisites: ${missing[*]}"
        return 1
    fi
    
    return 0
}

# Check if running in CI environment
is_ci() {
    [[ -n "${CI:-}" ]] || [[ "$CI_MODE" == "1" ]]
}

# Check if user has root privileges
is_root() {
    [[ $EUID -eq 0 ]]
}

# Check if systemd is available
has_systemd() {
    command -v systemctl &> /dev/null && [[ -d /run/systemd/system ]]
}

# ============================================
# Cleanup Functions
# ============================================

# Register cleanup function
CLEANUP_FUNCTIONS=()

register_cleanup() {
    CLEANUP_FUNCTIONS+=("$1")
}

run_cleanup() {
    log_info "Running cleanup..."
    for func in "${CLEANUP_FUNCTIONS[@]}"; do
        eval "$func" || true
    done
}

# Setup trap for cleanup
trap_cleanup() {
    trap 'run_cleanup' EXIT INT TERM
}

# ============================================
# Utility Functions
# ============================================

# Generate random string
random_string() {
    local length="${1:-8}"
    tr -dc 'a-z0-9' < /dev/urandom | head -c "$length"
}

# Generate test container name
test_container_name() {
    echo "test-$(random_string 8)"
}

# Get free port
get_free_port() {
    local port
    port=$(comm -23 <(seq 1024 65535 | sort) <(ss -tan | tail -n +2 | cut -d':' -f2 | cut -d' ' -f1 | sort -u) | shuf | head -n1)
    echo "$port"
}

# Create temporary test directory
temp_test_dir() {
    mktemp -d -t "podman-test-XXXXXX"
}

# ============================================
# Network and Resource Chaos Helpers
# ============================================

# Simulate network partition
simulate_network_partition() {
    local target="$1"
    local duration="${2:-30}"
    
    log_info "Simulating network partition to $target for ${duration}s"
    iptables -A OUTPUT -d "$target" -j DROP
    (
        sleep "$duration"
        iptables -D OUTPUT -d "$target" -j DROP
        log_info "Network partition to $target removed"
    ) &
}

# Limit bandwidth
limit_bandwidth() {
    local interface="$1"
    local rate="${2:-1mbit}"
    
    tc qdisc add dev "$interface" root tbf rate "$rate" burst 32kbit latency 400ms
    register_cleanup "tc qdisc del dev $interface root 2>/dev/null || true"
}

# Consume memory
consume_memory() {
    local size="$1"
    local duration="${2:-60}"
    
    (
        # Create memory pressure
        python3 -c "
import time
data = 'x' * ($size * 1024 * 1024)
time.sleep($duration)
" 2>/dev/null || \
        dd if=/dev/zero of=/tmp/memory-pressure bs=1M count="$size" 2>/dev/null
        rm -f /tmp/memory-pressure
    ) &
}

# Create disk pressure
create_disk_pressure() {
    local path="$1"
    local size_mb="${2:-1000}"
    
    dd if=/dev/zero of="$path/fill.tmp" bs=1M count="$size_mb" 2>/dev/null || true
}

# Block DNS
block_dns() {
    local duration="${1:-60}"
    
    iptables -A OUTPUT -p udp --dport 53 -j DROP
    iptables -A OUTPUT -p tcp --dport 53 -j DROP
    
    (
        sleep "$duration"
        iptables -D OUTPUT -p udp --dport 53 -j DROP
        iptables -D OUTPUT -p tcp --dport 53 -j DROP
    ) &
}

# Export functions for use in subshells
export -f log_info log_success log_error log_warn log_skip
export -f assert_equals assert_not_equals assert_true assert_false
export -f assert_file_exists assert_dir_exists assert_command_exists
export -f assert_contains assert_exit_code
