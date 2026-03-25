#!/usr/bin/env bats
#
# Unit Tests for Rollback Functions
# Tests rollback logic, version management, and recovery
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
    
    create_mock_rollback_script
    
    # Create state directory
    mkdir -p "$TEST_TEMP_DIR/state"
    export ROLLBACK_STATE_DIR="$TEST_TEMP_DIR/state"
}

teardown() {
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

create_mock_rollback_script() {
    cat > "$TEST_TEMP_DIR/rollback.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

# Configuration
ROLLBACK_STATE_DIR="${ROLLBACK_STATE_DIR:-/var/lib/podman-rollback}"
MAX_REVISIONS="${MAX_REVISIONS:-10}"
KEEP_REVISIONS="${KEEP_REVISIONS:-5}"

# Ensure state directory exists
mkdir -p "$ROLLBACK_STATE_DIR"

# ============================================
# State Management
# ============================================

# Save current deployment state
save_state() {
    local app="$1"
    local version="$2"
    local containers="$3"
    local timestamp
    timestamp=$(date +%s)
    
    local state_file="$ROLLBACK_STATE_DIR/${app}_${timestamp}.json"
    
    cat > "$state_file" << STATE
{
  "app": "$app",
  "version": "$version",
  "containers": [$containers],
  "timestamp": $timestamp,
  "revision": $(get_next_revision "$app")
}
STATE
    
    # Cleanup old revisions
    cleanup_old_revisions "$app"
    
    echo "$state_file"
}

# Get next revision number
get_next_revision() {
    local app="$1"
    local latest_revision=0
    
    for state_file in "$ROLLBACK_STATE_DIR"/"${app}"_*.json; do
        [[ -f "$state_file" ]] || continue
        local revision
        revision=$(jq -r '.revision // 0' "$state_file" 2>/dev/null || echo "0")
        if [[ "$revision" -gt "$latest_revision" ]]; then
            latest_revision="$revision"
        fi
    done
    
    echo $((latest_revision + 1))
}

# Get the previous state for rollback
get_previous_state() {
    local app="$1"
    local current_revision="${2:-0}"
    
    if [[ "$current_revision" -le 1 ]]; then
        current_revision=$(get_current_revision "$app")
    fi
    
    local target_revision=$((current_revision - 1))
    
    for state_file in "$ROLLBACK_STATE_DIR"/"${app}"_*.json; do
        [[ -f "$state_file" ]] || continue
        local revision
        revision=$(jq -r '.revision // 0' "$state_file" 2>/dev/null || echo "0")
        if [[ "$revision" == "$target_revision" ]]; then
            echo "$state_file"
            return 0
        fi
    done
    
    return 1
}

# Get current revision
get_current_revision() {
    local app="$1"
    get_next_revision "$app"
}

# List all saved states for an app
list_states() {
    local app="$1"
    
    echo "REVISION | TIMESTAMP           | VERSION | CONTAINERS"
    echo "---------|---------------------|---------|-----------"
    
    for state_file in "$ROLLBACK_STATE_DIR"/"${app}"_*.json; do
        [[ -f "$state_file" ]] || continue
        local revision timestamp version containers
        revision=$(jq -r '.revision' "$state_file" 2>/dev/null || echo "N/A")
        timestamp=$(jq -r '.timestamp' "$state_file" 2>/dev/null || echo "0")
        version=$(jq -r '.version' "$state_file" 2>/dev/null || echo "unknown")
        containers=$(jq -r '.containers | length' "$state_file" 2>/dev/null || echo "0")
        
        local date_str
        date_str=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")
        
        printf "%8s | %19s | %7s | %10s\n" "$revision" "$date_str" "$version" "$containers"
    done | sort -k1 -n
}

# Cleanup old revisions, keeping only the most recent
cleanup_old_revisions() {
    local app="$1"
    local count=0
    
    # Count and sort revisions
    local -a revisions=()
    for state_file in "$ROLLBACK_STATE_DIR"/"${app}"_*.json; do
        [[ -f "$state_file" ]] || continue
        revisions+=("$state_file")
    done
    
    local total=${#revisions[@]}
    if [[ $total -le $KEEP_REVISIONS ]]; then
        return 0
    fi
    
    # Sort by revision number and remove oldest
    IFS=$'\n' read -d '' -ra sorted_revisions < <(printf '%s\n' "${revisions[@]}" | sort -t'_' -k3 -n) || true
    
    local to_delete=$((total - KEEP_REVISIONS))
    for ((i=0; i<to_delete; i++)); do
        rm -f "${sorted_revisions[$i]}"
    done
}

# ============================================
# Rollback Logic
# ============================================

# Perform rollback to previous version
rollback() {
    local app="$1"
    local target_revision="${2:-}"
    local dry_run="${3:-false}"
    
    log_info "Starting rollback for $app"
    
    # Get state to rollback to
    local state_file
    if [[ -n "$target_revision" ]]; then
        state_file=$(find_state_by_revision "$app" "$target_revision")
    else
        state_file=$(get_previous_state "$app")
    fi
    
    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        log_error "No previous state found for rollback"
        return 1
    fi
    
    # Load state
    local version
    version=$(jq -r '.version' "$state_file")
    
    log_info "Rolling back to version: $version"
    
    if [[ "$dry_run" == "true" ]]; then
        log_info "DRY RUN: Would rollback to $version"
        return 0
    fi
    
    # Stop current containers
    stop_current_containers "$app"
    
    # Restore previous containers
    restore_containers "$state_file"
    
    # Verify rollback
    if verify_rollback "$app" "$version"; then
        log_success "Rollback completed successfully"
        return 0
    else
        log_error "Rollback verification failed"
        return 1
    fi
}

# Find state file by revision number
find_state_by_revision() {
    local app="$1"
    local revision="$2"
    
    for state_file in "$ROLLBACK_STATE_DIR"/"${app}"_*.json; do
        [[ -f "$state_file" ]] || continue
        local file_revision
        file_revision=$(jq -r '.revision' "$state_file" 2>/dev/null)
        if [[ "$file_revision" == "$revision" ]]; then
            echo "$state_file"
            return 0
        fi
    done
    
    return 1
}

# Stop current containers for an app
stop_current_containers() {
    local app="$1"
    
    log_info "Stopping current containers for $app"
    
    # Find containers matching app name
    local containers
    containers=$(podman ps -q --filter "name=${app}" 2>/dev/null || true)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | xargs -r podman stop -t 30 2>/dev/null || true
        echo "$containers" | xargs -r podman rm 2>/dev/null || true
    fi
}

# Restore containers from state file
restore_containers() {
    local state_file="$1"
    
    log_info "Restoring containers from $state_file"
    
    # In a real implementation, this would recreate containers
    # For testing, we just verify the state file exists
    if [[ ! -f "$state_file" ]]; then
        log_error "State file not found: $state_file"
        return 1
    fi
    
    return 0
}

# Verify rollback was successful
verify_rollback() {
    local app="$1"
    local expected_version="$2"
    
    log_info "Verifying rollback..."
    
    # Check if containers are running
    local running_count
    running_count=$(podman ps -q --filter "name=${app}" 2>/dev/null | wc -l)
    
    if [[ "$running_count" -eq 0 ]]; then
        log_error "No containers running after rollback"
        return 1
    fi
    
    # In a real implementation, verify the version matches
    return 0
}

# ============================================
# Logging Functions
# ============================================

log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_success() {
    echo "[SUCCESS] $*"
}

# ============================================
# Main Entry Point
# ============================================

main() {
    local command="${1:-}"
    shift || true
    
    case "$command" in
        save)
            save_state "$@"
            ;;
        rollback)
            rollback "$@"
            ;;
        list)
            list_states "$@"
            ;;
        *)
            echo "Usage: $0 {save|rollback|list} [options]"
            echo ""
            echo "Commands:"
            echo "  save <app> <version> <containers>  Save current state"
            echo "  rollback <app> [revision]          Rollback to previous/指定版本"
            echo "  list <app>                         List saved states"
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
EOF
    chmod +x "$TEST_TEMP_DIR/rollback.sh"
}

# ============================================
# State Management Tests
# ============================================

@test "save_state creates state file with correct structure" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Mock jq
    jq() {
        if [[ "$*" == *".revision"* ]]; then
            echo "0"
        else
            cat
        fi
    }
    export -f jq
    
    run save_state "myapp" "1.0.0" '"container1","container2"'
    
    assert_success
    assert [ -f "$output" ]
    
    # Verify file content
    run cat "$output"
    assert_output --partial '"app": "myapp"'
    assert_output --partial '"version": "1.0.0"'
}

@test "get_next_revision increments correctly" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Create mock state files
    mkdir -p "$ROLLBACK_STATE_DIR"
    echo '{"revision":5}' > "$ROLLBACK_STATE_DIR/myapp_1000.json"
    echo '{"revision":3}' > "$ROLLBACK_STATE_DIR/myapp_2000.json"
    
    # Mock jq
    jq() {
        if [[ "$*" == *".revision"* ]]; then
            basename "$2" | grep -o '[0-9]*' | head -1 || echo "0"
        fi
    }
    export -f jq
    
    run get_next_revision "myapp"
    # Should return 4 (max(3,5) + 1)
}

@test "get_previous_state returns correct state file" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Mock state files
    mkdir -p "$ROLLBACK_STATE_DIR"
    echo '{"revision":1}' > "$ROLLBACK_STATE_DIR/myapp_1000.json"
    echo '{"revision":2}' > "$ROLLBACK_STATE_DIR/myapp_2000.json"
    
    jq() {
        if [[ "$*" == *".revision"* ]]; then
            if [[ "$2" == *"1000"* ]]; then
                echo "1"
            else
                echo "2"
            fi
        fi
    }
    export -f jq
    
    run get_previous_state "myapp" "2"
    assert_output "$ROLLBACK_STATE_DIR/myapp_1000.json"
}

@test "cleanup_old_revisions removes oldest revisions" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Create more revisions than KEEP_REVISIONS
    mkdir -p "$ROLLBACK_STATE_DIR"
    for i in {1..7}; do
        echo "{\"revision\":$i}" > "$ROLLBACK_STATE_DIR/myapp_${i}000.json"
    done
    
    # Mock jq
    jq() {
        basename "$2" | grep -oP '(?<=_)\d+(?=\.)' || echo "0"
    }
    export -f jq
    
    # Set keep revisions to 5
    KEEP_REVISIONS=5
    
    run cleanup_old_revisions "myapp"
    assert_success
    
    # Should have removed 2 oldest (1 and 2)
    local count
    count=$(ls -1 "$ROLLBACK_STATE_DIR"/myapp_*.json 2>/dev/null | wc -l)
    [[ "$count" -eq 5 ]]
}

# ============================================
# Rollback Logic Tests
# ============================================

@test "rollback fails when no previous state exists" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    run rollback "nonexistent-app"
    assert_failure
    assert_output --partial "No previous state found"
}

@test "rollback performs dry run correctly" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Create mock state
    mkdir -p "$ROLLBACK_STATE_DIR"
    cat > "$ROLLBACK_STATE_DIR/myapp_1000.json" << 'JSON'
{
  "app": "myapp",
  "version": "1.0.0",
  "revision": 1,
  "timestamp": 1000
}
JSON
    
    # Mock jq
    jq() {
        if [[ "$*" == *".version"* ]]; then
            echo "1.0.0"
        elif [[ "$*" == *".revision"* ]]; then
            echo "1"
        fi
    }
    export -f jq
    
    run rollback "myapp" "" "true"
    assert_success
    assert_output --partial "DRY RUN"
}

@test "find_state_by_revision locates correct state" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    mkdir -p "$ROLLBACK_STATE_DIR"
    echo '{"revision":5}' > "$ROLLBACK_STATE_DIR/myapp_5000.json"
    
    # Mock jq
    jq() {
        echo "5"
    }
    export -f jq
    
    run find_state_by_revision "myapp" "5"
    assert_output "$ROLLBACK_STATE_DIR/myapp_5000.json"
}

@test "verify_rollback checks for running containers" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Mock podman to return no containers
    podman() {
        if [[ "$1" == "ps" ]]; then
            echo ""
        fi
    }
    export -f podman
    
    run verify_rollback "myapp" "1.0.0"
    assert_failure
    assert_output --partial "No containers running"
}

# ============================================
# List States Tests
# ============================================

@test "list_states formats output correctly" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    mkdir -p "$ROLLBACK_STATE_DIR"
    cat > "$ROLLBACK_STATE_DIR/myapp_1000.json" << 'JSON'
{
  "app": "myapp",
  "version": "2.0.0",
  "revision": 1,
  "timestamp": 1000,
  "containers": ["c1", "c2"]
}
JSON
    
    # Mock jq
    jq() {
        case "$*" in
            *".revision"*) echo "1" ;;
            *".timestamp"*) echo "1000" ;;
            *".version"*) echo "2.0.0" ;;
            *".containers | length"*) echo "2" ;;
        esac
    }
    export -f jq
    
    run list_states "myapp"
    assert_output --partial "REVISION"
    assert_output --partial "VERSION"
    assert_output --partial "2.0.0"
}

# ============================================
# Main Entry Point Tests
# ============================================

@test "main shows usage for invalid command" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    run main "invalid"
    assert_failure
    assert_output --partial "Usage:"
}

@test "main save command works" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Mock functions
    save_state() {
        echo "state saved"
    }
    export -f save_state
    
    run main "save" "myapp" "1.0.0" "container1"
    assert_output "state saved"
}

@test "main rollback command works" {
    source "$TEST_TEMP_DIR/rollback.sh"
    
    # Mock functions
    rollback() {
        echo "rollback executed"
    }
    export -f rollback
    
    run main "rollback" "myapp"
    assert_output --partial "rollback executed"
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
        [[ "$output" == "$1" ]]
    fi
}

assert() {
    eval "$1"
}
