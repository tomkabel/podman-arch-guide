#!/bin/bash
#
# Main Test Runner
# Runs all test suites: unit, integration, and chaos tests
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default configuration
TEST_SUITE="all"
VERBOSITY=0
CI_MODE=0
PARALLEL=0
JUNIT_OUTPUT=""
FAILED_SUITES=()

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ============================================
# Usage and Help
# ============================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [SUITE]

Run the Podman deployment test suite.

SUITE:
    all           Run all test suites (default)
    unit          Run only unit tests
    integration   Run only integration tests
    chaos         Run only chaos tests

OPTIONS:
    -h, --help        Show this help message
    -v, --verbose     Enable verbose output
    -c, --ci          Enable CI mode (JUnit XML output)
    -p, --parallel    Run tests in parallel where possible
    -o, --output DIR  Output directory for test results
    -s, --skip SUITE  Skip specific suite (can be used multiple times)
    -t, --timeout SEC Global timeout for tests (default: 300)

EXAMPLES:
    $(basename "$0")                  # Run all tests
    $(basename "$0") unit             # Run only unit tests
    $(basename "$0") -v integration   # Run integration tests with verbose output
    $(basename "$0") -c -o ./results  # Run all tests in CI mode, save results

EXIT CODES:
    0   All tests passed
    1   One or more tests failed
    2   Invalid arguments
    3   Prerequisites not met

EOF
}

# ============================================
# Argument Parsing
# ============================================

parse_args() {
    local skip_suites=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSITY=1
                shift
                ;;
            -c|--ci)
                CI_MODE=1
                shift
                ;;
            -p|--parallel)
                PARALLEL=1
                shift
                ;;
            -o|--output)
                JUNIT_OUTPUT="$2"
                shift 2
                ;;
            -s|--skip)
                skip_suites+=("$2")
                shift 2
                ;;
            -t|--timeout)
                export TEST_TIMEOUT="$2"
                shift 2
                ;;
            -*)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
            *)
                TEST_SUITE="$1"
                shift
                ;;
        esac
    done
    
    # Validate suite
    case "$TEST_SUITE" in
        all|unit|integration|chaos)
            ;;
        *)
            echo "Invalid test suite: $TEST_SUITE" >&2
            usage >&2
            exit 2
            ;;
    esac
    
    # Set environment variables for testlib
    export VERBOSE="$VERBOSITY"
    export CI_MODE="$CI_MODE"
    
    # Create output directory if specified
    if [[ -n "$JUNIT_OUTPUT" ]]; then
        mkdir -p "$JUNIT_OUTPUT"
    fi
}

# ============================================
# Prerequisites Check
# ============================================

check_prerequisites() {
    echo -e "${BLUE}[INFO]${NC} Checking prerequisites..."
    
    local missing=()
    
    # Check for bash
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        echo -e "${RED}[ERROR]${NC} Bash 4.0+ required" >&2
        exit 3
    fi
    
    # Check for required tools
    for cmd in podman curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Check for BATS if running unit tests
    if [[ "$TEST_SUITE" == "all" || "$TEST_SUITE" == "unit" ]]; then
        if ! command -v bats &> /dev/null && [[ ! -f "$REPO_ROOT/tools/bats/bin/bats" ]]; then
            echo -e "${YELLOW}[WARN]${NC} BATS not found. Unit tests will be skipped."
            echo "Install with: git submodule update --init --recursive"
        fi
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[WARN]${NC} Optional tools not found: ${missing[*]}"
    fi
    
    # Check for root for chaos tests
    if [[ "$TEST_SUITE" == "all" || "$TEST_SUITE" == "chaos" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo -e "${YELLOW}[WARN]${NC} Chaos tests require root privileges. Some tests may be skipped."
        fi
    fi
    
    return 0
}

# ============================================
# Test Suite Runners
# ============================================

run_unit_tests() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Running Unit Tests${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    local bats_cmd="bats"
    if [[ -f "$REPO_ROOT/tools/bats/bin/bats" ]]; then
        bats_cmd="$REPO_ROOT/tools/bats/bin/bats"
    fi
    
    if ! command -v "$bats_cmd" &> /dev/null; then
        echo -e "${YELLOW}[SKIP]${NC} BATS not available, skipping unit tests"
        return 0
    fi
    
    local unit_test_dir="$SCRIPT_DIR/unit"
    local exit_code=0
    
    # Find and run all .bats files
    for test_file in "$unit_test_dir"/*.bats; do
        [[ -f "$test_file" ]] || continue
        
        echo -e "${BLUE}[RUN]${NC} $(basename "$test_file")"
        
        local bats_args=()
        [[ "$VERBOSITY" == "1" ]] && bats_args+=("--verbose-run")
        [[ "$CI_MODE" == "1" ]] && bats_args+=("--formatter junit")
        
        if ! "$bats_cmd" "${bats_args[@]}" "$test_file"; then
            exit_code=1
            FAILED_SUITES+=("unit:$(basename "$test_file")")
        fi
    done
    
    # Run shell-based unit tests
    for test_file in "$unit_test_dir"/test_*.sh; do
        [[ -f "$test_file" ]] || continue
        [[ "$test_file" == *.bats ]] && continue
        
        echo -e "${BLUE}[RUN]${NC} $(basename "$test_file")"
        
        if ! bash "$test_file"; then
            exit_code=1
            FAILED_SUITES+=("unit:$(basename "$test_file")")
        fi
    done
    
    return $exit_code
}

run_integration_tests() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Running Integration Tests${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    local integration_dir="$SCRIPT_DIR/integration"
    local exit_code=0
    
    # Find and run all integration tests
    for test_file in "$integration_dir"/test_*.sh; do
        [[ -f "$test_file" ]] || continue
        
        echo -e "${BLUE}[RUN]${NC} $(basename "$test_file")"
        
        local start_time=$(date +%s)
        
        if bash "$test_file"; then
            local end_time=$(date +%s)
            echo -e "${GREEN}[PASS]${NC} $(basename "$test_file") ($((end_time - start_time))s)"
        else
            local end_time=$(date +%s)
            echo -e "${RED}[FAIL]${NC} $(basename "$test_file") ($((end_time - start_time))s)"
            exit_code=1
            FAILED_SUITES+=("integration:$(basename "$test_file")")
        fi
    done
    
    return $exit_code
}

run_chaos_tests() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Running Chaos Tests${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    local chaos_dir="$SCRIPT_DIR/chaos"
    local exit_code=0
    
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}[WARN]${NC} Chaos tests require root. Attempting with sudo..."
    fi
    
    # Find and run all chaos tests
    for test_file in "$chaos_dir"/test_*.sh; do
        [[ -f "$test_file" ]] || continue
        
        echo -e "${BLUE}[RUN]${NC} $(basename "$test_file")"
        
        local start_time=$(date +%s)
        local test_exit_code=0
        
        # Run with sudo if not root
        if [[ $EUID -ne 0 ]]; then
            sudo bash "$test_file" || test_exit_code=$?
        else
            bash "$test_file" || test_exit_code=$?
        fi
        
        local end_time=$(date +%s)
        
        if [[ $test_exit_code -eq 0 ]]; then
            echo -e "${GREEN}[PASS]${NC} $(basename "$test_file") ($((end_time - start_time))s)"
        elif [[ $test_exit_code -eq 77 ]]; then
            echo -e "${YELLOW}[SKIP]${NC} $(basename "$test_file") ($((end_time - start_time))s)"
        else
            echo -e "${RED}[FAIL]${NC} $(basename "$test_file") ($((end_time - start_time))s)"
            exit_code=1
            FAILED_SUITES+=("chaos:$(basename "$test_file")")
        fi
    done
    
    return $exit_code
}

# ============================================
# Main Execution
# ============================================

main() {
    parse_args "$@"
    
    echo -e "${BLUE}Podman Deployment Test Suite${NC}"
    echo -e "${BLUE}============================${NC}\n"
    
    # Check prerequisites
    check_prerequisites
    
    # Track overall results
    local overall_exit=0
    local start_time=$(date +%s)
    
    # Run selected test suites
    case "$TEST_SUITE" in
        all)
            run_unit_tests || overall_exit=1
            run_integration_tests || overall_exit=1
            run_chaos_tests || overall_exit=1
            ;;
        unit)
            run_unit_tests || overall_exit=1
            ;;
        integration)
            run_integration_tests || overall_exit=1
            ;;
        chaos)
            run_chaos_tests || overall_exit=1
            ;;
    esac
    
    # Calculate total time
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    # Print summary
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Total time: ${total_time}s"
    
    if [[ $overall_exit -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed:${NC}"
        for suite in "${FAILED_SUITES[@]}"; do
            echo "  - $suite"
        done
    fi
    
    # Move JUnit files if output directory specified
    if [[ -n "$JUNIT_OUTPUT" && "$CI_MODE" == "1" ]]; then
        find "$SCRIPT_DIR" -name "junit-*.xml" -exec mv {} "$JUNIT_OUTPUT/" \;
        echo -e "\nJUnit XML reports saved to: $JUNIT_OUTPUT"
    fi
    
    return $overall_exit
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
