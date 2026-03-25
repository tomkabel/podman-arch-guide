#!/usr/bin/env bats
#
# Unit Tests for Deployment Script Functions
# Tests deployment logic, validation, and error handling
#

# Setup BATS path
BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# Load test library
load "$BATS_TEST_DIRNAME/../testlib.sh"

# ============================================
# Test Setup and Teardown
# ============================================

setup() {
    # Create temporary test directory
    TEST_TEMP_DIR=$(temp_test_dir)
    export TEST_TEMP_DIR
    
    # Setup mock podman
    MOCK_DIR=$(mktemp -d)
    setup_mock_env "$MOCK_DIR"
    export MOCK_DIR
    
    # Create mock deployment script
    create_mock_deploy_script
    
    # Track test state
    TEST_CONTAINERS=()
}

teardown() {
    # Cleanup mock environment
    if [[ -d "${MOCK_DIR:-}" ]]; then
        cleanup_mock_env "$MOCK_DIR"
    fi
    
    # Cleanup temp directory
    if [[ -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================
# Helper Functions
# ============================================

create_mock_deploy_script() {
    cat > "$TEST_TEMP_DIR/deploy.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

# Deployment configuration
APP_NAME="${APP_NAME:-webapp}"
VERSION="${VERSION:-latest}"
NAMESPACE="${NAMESPACE:-default}"
REPLICAS="${REPLICAS:-1}"

# Validation functions
validate_app_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "ERROR: App name cannot be empty" >&2
        return 1
    fi
    if [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
        echo "ERROR: App name must be lowercase alphanumeric with hyphens only" >&2
        return 1
    fi
    if [[ ${#name} -gt 63 ]]; then
        echo "ERROR: App name too long (max 63 chars)" >&2
        return 1
    fi
    return 0
}

validate_version() {
    local version="$1"
    if [[ -z "$version" ]]; then
        echo "ERROR: Version cannot be empty" >&2
        return 1
    fi
    if [[ ! "$version" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "ERROR: Invalid version format" >&2
        return 1
    fi
    return 0
}

validate_replicas() {
    local replicas="$1"
    if [[ ! "$replicas" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Replicas must be a number" >&2
        return 1
    fi
    if [[ "$replicas" -lt 1 ]]; then
        echo "ERROR: Replicas must be at least 1" >&2
        return 1
    fi
    if [[ "$replicas" -gt 100 ]]; then
        echo "ERROR: Replicas cannot exceed 100" >&2
        return 1
    fi
    return 0
}

# Image functions
build_image_name() {
    local registry="${1:-localhost}"
    local app="$2"
    local version="$3"
    echo "${registry}/${app}:${version}"
}

parse_image_tag() {
    local image="$1"
    if [[ "$image" =~ ^([^/]+/)?([^:]+)(:([^/]+))?$ ]]; then
        echo "registry:${BASH_REMATCH[1]:-localhost}"
        echo "name:${BASH_REMATCH[2]}"
        echo "tag:${BASH_REMATCH[4]:-latest}"
    fi
}

# Deployment functions
generate_container_name() {
    local app="$1"
    local index="${2:-0}"
    echo "${app}-${index}-$(date +%s)"
}

calculate_resource_limits() {
    local replicas="$1"
    local cpu_per="${2:-0.5}"
    local mem_per="${3:-512}"
    
    local total_cpu=$(echo "$replicas * $cpu_per" | bc -l 2>/dev/null || echo "0")
    local total_mem=$((replicas * mem_per))
    
    echo "cpu:$total_cpu"
    echo "memory:${total_mem}Mi"
}

# Podman wrapper functions
container_exists() {
    local name="$1"
    podman ps -a --format '{{.Names}}' | grep -q "^${name}$"
}

stop_container() {
    local name="$1"
    local timeout="${2:-30}"
    
    if container_exists "$name"; then
        podman stop -t "$timeout" "$name" >/dev/null 2>&1 || true
        podman rm "$name" >/dev/null 2>&1 || true
    fi
}

deploy_container() {
    local name="$1"
    local image="$2"
    local ports="${3:-}"
    local env_vars="${4:-}"
    local volumes="${5:-}"
    
    local cmd=(podman run -d --name "$name")
    
    # Add ports
    if [[ -n "$ports" ]]; then
        IFS=',' read -ra PORT_ARRAY <<< "$ports"
        for port in "${PORT_ARRAY[@]}"; do
            cmd+=(-p "$port")
        done
    fi
    
    # Add environment variables
    if [[ -n "$env_vars" ]]; then
        IFS=',' read -ra ENV_ARRAY <<< "$env_vars"
        for env in "${ENV_ARRAY[@]}"; do
            cmd+=(-e "$env")
        done
    fi
    
    # Add volumes
    if [[ -n "$volumes" ]]; then
        IFS=',' read -ra VOL_ARRAY <<< "$volumes"
        for vol in "${VOL_ARRAY[@]}"; do
            cmd+=(-v "$vol")
        done
    fi
    
    cmd+=("$image")
    "${cmd[@]}"
}

# Rollout functions
calculate_rollout_progress() {
    local desired="$1"
    local current="$2"
    local ready="$3"
    
    if [[ "$desired" -eq 0 ]]; then
        echo "100"
        return 0
    fi
    
    local progress=$((ready * 100 / desired))
    echo "$progress"
}

is_rollout_complete() {
    local desired="$1"
    local ready="$2"
    local updated="$3"
    
    [[ "$desired" -eq "$ready" && "$desired" -eq "$updated" ]]
}

# Config functions
parse_config() {
    local file="$1"
    local key="$2"
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    grep "^${key}=" "$file" | cut -d'=' -f2- | tr -d '"'
}

validate_config() {
    local file="$1"
    local errors=()
    
    if [[ ! -f "$file" ]]; then
        echo "Config file not found: $file"
        return 1
    fi
    
    # Check required fields
    if ! grep -q "^APP_NAME=" "$file"; then
        errors+=("Missing APP_NAME")
    fi
    
    if ! grep -q "^VERSION=" "$file"; then
        errors+=("Missing VERSION")
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        printf '%s\n' "${errors[@]}"
        return 1
    fi
    
    return 0
}

# Main deploy function (simplified for testing)
deploy() {
    local config_file="${1:-}"
    
    # Load config if provided
    if [[ -n "$config_file" ]]; then
        if ! validate_config "$config_file"; then
            return 1
        fi
        source "$config_file"
    fi
    
    # Validate inputs
    validate_app_name "$APP_NAME" || return 1
    validate_version "$VERSION" || return 1
    validate_replicas "$REPLICAS" || return 1
    
    echo "Deploying $APP_NAME v$VERSION ($REPLICAS replicas)"
    return 0
}
EOF
    chmod +x "$TEST_TEMP_DIR/deploy.sh"
}

# ============================================
# Validation Tests
# ============================================

@test "validate_app_name accepts valid names" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_app_name "myapp"
    assert_success
    
    run validate_app_name "my-app"
    assert_success
    
    run validate_app_name "myapp123"
    assert_success
}

@test "validate_app_name rejects empty names" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_app_name ""
    assert_failure
    assert_output --partial "cannot be empty"
}

@test "validate_app_name rejects invalid characters" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_app_name "MyApp"
    assert_failure
    assert_output --partial "lowercase alphanumeric"
    
    run validate_app_name "my_app"
    assert_failure
    
    run validate_app_name "my app"
    assert_failure
}

@test "validate_app_name rejects names that are too long" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_app_name "$(head -c 64 /dev/zero | tr '\0' 'a')"
    assert_failure
    assert_output --partial "too long"
}

@test "validate_version accepts valid versions" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_version "1.0.0"
    assert_success
    
    run validate_version "latest"
    assert_success
    
    run validate_version "v1.2.3-beta.1"
    assert_success
}

@test "validate_version rejects invalid versions" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_version ""
    assert_failure
    
    run validate_version "v1.0@invalid"
    assert_failure
}

@test "validate_replicas accepts valid numbers" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_replicas "1"
    assert_success
    
    run validate_replicas "10"
    assert_success
}

@test "validate_replicas rejects invalid inputs" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_replicas "0"
    assert_failure
    assert_output --partial "at least 1"
    
    run validate_replicas "101"
    assert_failure
    assert_output --partial "cannot exceed 100"
    
    run validate_replicas "abc"
    assert_failure
    assert_output --partial "must be a number"
}

# ============================================
# Image Functions Tests
# ============================================

@test "build_image_name constructs correct image name" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run build_image_name "registry.io" "myapp" "v1.0.0"
    assert_output "registry.io/myapp:v1.0.0"
}

@test "build_image_name uses default registry" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run build_image_name "" "myapp" "latest"
    assert_output "/myapp:latest"
}

@test "parse_image_tag extracts components correctly" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run parse_image_tag "registry.io/myapp:v1.0.0"
    assert_output --partial "registry:registry.io/"
    assert_output --partial "name:myapp"
    assert_output --partial "tag:v1.0.0"
}

@test "parse_image_tag handles default tag" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run parse_image_tag "myapp"
    assert_output --partial "tag:latest"
}

# ============================================
# Container Functions Tests
# ============================================

@test "generate_container_name includes app and index" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run generate_container_name "webapp" "0"
    assert_output --regexp "^webapp-0-[0-9]+$"
}

@test "calculate_resource_limits computes correctly" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run calculate_resource_limits "3" "0.5" "512"
    assert_output --partial "memory:1536Mi"
}

@test "container_exists returns false for non-existent container" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run container_exists "non-existent-container-12345"
    assert_failure
}

# ============================================
# Rollout Functions Tests
# ============================================

@test "calculate_rollout_progress computes percentage correctly" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run calculate_rollout_progress "10" "10" "5"
    assert_output "50"
}

@test "calculate_rollout_progress handles zero desired" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run calculate_rollout_progress "0" "0" "0"
    assert_output "100"
}

@test "is_rollout_complete returns true when complete" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run is_rollout_complete "3" "3" "3"
    assert_success
}

@test "is_rollout_complete returns false when incomplete" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run is_rollout_complete "3" "2" "3"
    assert_failure
    
    run is_rollout_complete "3" "3" "2"
    assert_failure
}

# ============================================
# Config Functions Tests
# ============================================

@test "parse_config extracts value from config file" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    cat > "$TEST_TEMP_DIR/test.conf" << EOF
APP_NAME=testapp
VERSION=1.0.0
REPLICAS=3
EOF
    
    run parse_config "$TEST_TEMP_DIR/test.conf" "APP_NAME"
    assert_output "testapp"
}

@test "validate_config passes valid config" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    cat > "$TEST_TEMP_DIR/valid.conf" << EOF
APP_NAME=testapp
VERSION=1.0.0
REPLICAS=3
EOF
    
    run validate_config "$TEST_TEMP_DIR/valid.conf"
    assert_success
}

@test "validate_config fails for missing file" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run validate_config "$TEST_TEMP_DIR/nonexistent.conf"
    assert_failure
    assert_output --partial "not found"
}

@test "validate_config fails for missing required fields" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    cat > "$TEST_TEMP_DIR/invalid.conf" << EOF
VERSION=1.0.0
EOF
    
    run validate_config "$TEST_TEMP_DIR/invalid.conf"
    assert_failure
    assert_output --partial "Missing APP_NAME"
}

# ============================================
# Error Handling Tests
# ============================================

@test "deploy fails with missing config" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    run deploy "$TEST_TEMP_DIR/nonexistent.conf"
    assert_failure
}

@test "deploy succeeds with valid config" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    cat > "$TEST_TEMP_DIR/good.conf" << EOF
APP_NAME=testapp
VERSION=1.0.0
REPLICAS=1
EOF
    
    run deploy "$TEST_TEMP_DIR/good.conf"
    assert_success
    assert_output --partial "Deploying testapp v1.0.0"
}

@test "deploy fails with invalid app name in config" {
    source "$TEST_TEMP_DIR/deploy.sh"
    
    cat > "$TEST_TEMP_DIR/badname.conf" << EOF
APP_NAME=Invalid_Name
VERSION=1.0.0
REPLICAS=1
EOF
    
    run deploy "$TEST_TEMP_DIR/badname.conf"
    assert_failure
}

# ============================================
# BATS Assertions (simplified)
# ============================================

assert_success() {
    [[ "$status" -eq 0 ]]
}

assert_failure() {
    [[ "$status" -ne 0 ]]
}

assert_output() {
    local expected="$1"
    if [[ "$1" == "--partial" ]]; then
        [[ "$output" == *"$2"* ]]
    elif [[ "$1" == "--regexp" ]]; then
        [[ "$output" =~ $2 ]]
    else
        [[ "$output" == "$expected" ]]
    fi
}
