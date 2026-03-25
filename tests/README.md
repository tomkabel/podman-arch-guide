# Podman Deployment Test Suite

Comprehensive test suite for Podman-based deployments including unit tests, integration tests, and chaos engineering tests.

## Overview

This test suite provides automated testing for:
- **Unit Tests**: Script function validation using BATS framework
- **Integration Tests**: End-to-end deployment scenarios
- **Chaos Tests**: Resilience testing under failure conditions

## Test Structure

```
tests/
├── run-tests.sh              # Main test runner
├── testlib.sh                # Shared test utilities
├── README.md                 # This file
├── unit/                     # Unit tests
│   ├── test_deploy.bats      # Deployment script tests
│   ├── test_health_check.bats # Health check tests
│   └── test_rollback.bats    # Rollback logic tests
├── integration/              # Integration tests
│   ├── test_single_node.sh   # Single-node deployment
│   ├── test_blue_green.sh    # Blue-green deployment
│   ├── test_multi_node.sh    # Multi-node cluster
│   └── test_backup_restore.sh # Backup/restore workflow
└── chaos/                    # Chaos engineering tests
    ├── test_container_kill.sh   # Container termination
    ├── test_network_partition.sh # Network isolation
    ├── test_resource_exhaustion.sh # CPU/memory pressure
    ├── test_disk_pressure.sh    # Disk full scenarios
    └── test_dns_failure.sh      # DNS resolution failures
```

## Prerequisites

### Required
- `bash` 4.0+
- `podman`
- `curl`

### Optional
- `bats` (Bash Automated Testing System) for unit tests
- `jq` for JSON processing
- `iptables` for network chaos tests
- `stress` or `stress-ng` for resource exhaustion tests
- Root privileges for chaos tests requiring iptables

### Installing BATS

```bash
# Clone BATS
git clone https://github.com/bats-core/bats-core.git tools/bats

# Or use package manager
# Ubuntu/Debian
sudo apt-get install bats

# Fedora/RHEL
sudo dnf install bats

# macOS
brew install bats-core
```

## Running Tests

### Run All Tests

```bash
cd tests/
./run-tests.sh
```

### Run Specific Test Suite

```bash
# Unit tests only
./run-tests.sh unit

# Integration tests only
./run-tests.sh integration

# Chaos tests only
./run-tests.sh chaos
```

### Run Individual Test Files

```bash
# Unit test (requires BATS)
bats unit/test_deploy.bats

# Integration test
bash integration/test_single_node.sh

# Chaos test (may need sudo)
sudo bash chaos/test_container_kill.sh
```

### Command-Line Options

```bash
./run-tests.sh [OPTIONS] [SUITE]

Options:
  -h, --help        Show help message
  -v, --verbose     Enable verbose output
  -c, --ci          Enable CI mode (JUnit XML output)
  -p, --parallel    Run tests in parallel (where supported)
  -o, --output DIR  Output directory for test results
  -s, --skip SUITE  Skip specific suite
  -t, --timeout SEC Global timeout (default: 300s)

Examples:
  ./run-tests.sh -v                    # Verbose output
  ./run-tests.sh -c -o ./results       # CI mode with JUnit output
  ./run-tests.sh -v integration        # Verbose integration tests
  ./run-tests.sh -s chaos              # Skip chaos tests
```

## Test Categories

### Unit Tests

Unit tests validate individual functions and components using the BATS framework.

**Test Files:**
- `test_deploy.bats`: Tests deployment validation, image handling, and container operations
- `test_health_check.bats`: Tests health check logic, retry mechanisms, and status evaluation
- `test_rollback.bats`: Tests state management, rollback operations, and version control

**Running Unit Tests:**
```bash
# Using the test runner
./run-tests.sh unit

# Using BATS directly
bats unit/test_deploy.bats
bats unit/test_health_check.bats
bats unit/test_rollback.bats

# Run specific test
bats unit/test_deploy.bats -f "validate_app_name"
```

### Integration Tests

Integration tests validate end-to-end deployment scenarios.

**Test Files:**
- `test_single_node.sh`: Single-node deployment lifecycle
- `test_blue_green.sh`: Blue-green deployment with traffic switching
- `test_multi_node.sh`: Multi-node cluster deployment (simulated)
- `test_backup_restore.sh`: Backup and restore workflows

**Environment Variables:**
```bash
# Adjust test timeouts
export TEST_TIMEOUT=300

# Use specific ports
export HTTP_PORT=8080

# CI mode
export CI_MODE=1
export VERBOSE=1
```

### Chaos Engineering Tests

Chaos tests verify system resilience under failure conditions.

**Test Files:**
- `test_container_kill.sh`: Random container termination and recovery
- `test_network_partition.sh`: Network isolation between nodes
- `test_resource_exhaustion.sh`: CPU and memory pressure testing
- `test_disk_pressure.sh`: Disk full scenarios
- `test_dns_failure.sh`: DNS resolution failures

**⚠️ Chaos Test Requirements:**
- Root privileges required for network and DNS tests (iptables)
- May temporarily impact system resources
- Some tests use `iptables` which requires careful cleanup

**Running Chaos Tests:**
```bash
# Run all chaos tests with sudo
sudo ./run-tests.sh chaos

# Run specific chaos test
sudo bash chaos/test_container_kill.sh

# Skip if root not available (some tests will be skipped)
bash chaos/test_container_kill.sh
```

## Test Output

### Console Output

Tests provide colored output indicating pass/fail/skip status:
```
[INFO]  Starting: single-node-deployment
[INFO]  Deploying container...
[PASS]  Container is running
[INFO]  Test: Health check endpoint...
[PASS]  Health check passed
...
========================================
Test Results: single-node-deployment
========================================
Passed:  7
Failed:  0
Skipped: 0
Duration: 45s
========================================
```

### JUnit XML Output

In CI mode (`-c` flag), tests generate JUnit-compatible XML:
```bash
./run-tests.sh -c -o ./test-results
# Generates: test-results/junit-*.xml
```

## Writing New Tests

### Unit Test Template (BATS)

```bash
#!/usr/bin/env bats

# Load test library
load '../testlib.sh'

setup() {
    TEST_TEMP_DIR=$(temp_test_dir)
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

@test "description of test" {
    # Arrange
    expected="value"
    
    # Act
    run some_function
    
    # Assert
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}
```

### Integration Test Template

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../testlib.sh"

TEST_NAME="my-integration-test"

setup_test_env() {
    TEST_DIR=$(temp_test_dir)
    register_cleanup "cleanup_test_env"
}

cleanup_test_env() {
    # Cleanup code
    rm -rf "$TEST_DIR"
}

run_test() {
    init_tests "$TEST_NAME"
    
    # Test logic here
    run_test_case || exit_code=1
    
    finish_tests "$TEST_NAME"
    return $exit_code
}

main() {
    trap_cleanup
    setup_test_env
    run_test
    run_cleanup
}

main "$@"
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install Podman
        run: |
          sudo apt-get update
          sudo apt-get install -y podman
      
      - name: Install BATS
        run: |
          git clone https://github.com/bats-core/bats-core.git
          cd bats-core
          sudo ./install.sh /usr/local
      
      - name: Run tests
        run: |
          cd tests
          ./run-tests.sh -c -o ../test-results
      
      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: test-results
          path: test-results/
```

### GitLab CI Example

```yaml
test:
  image: fedora:latest
  before_script:
    - dnf install -y podman bats jq
  script:
    - cd tests
    - ./run-tests.sh -c
  artifacts:
    reports:
      junit: tests/junit-*.xml
```

## Troubleshooting

### Common Issues

**1. Permission Denied (Chaos Tests)**
```bash
# Run with sudo
sudo ./run-tests.sh chaos

# Or skip chaos tests
./run-tests.sh -s chaos
```

**2. Port Already in Use**
```bash
# Tests automatically find free ports
# If issues persist, check for stale containers:
podman ps -a
podman rm -f $(podman ps -aq)
```

**3. BATS Not Found**
```bash
# Install BATS
git submodule update --init --recursive

# Or specify path
export PATH="$PWD/tools/bats/bin:$PATH"
```

**4. Test Timeouts**
```bash
# Increase timeout
./run-tests.sh -t 600  # 10 minutes
```

### Debug Mode

```bash
# Enable verbose output
export VERBOSE=1
./run-tests.sh -v

# Run with bash tracing
bash -x integration/test_single_node.sh
```

## Test Library Reference

### Assertion Functions

```bash
assert_equals "expected" "actual" ["message"]
assert_not_equals "not_expected" "actual" ["message"]
assert_true "condition" ["message"]
assert_false "condition" ["message"]
assert_file_exists "/path/to/file" ["message"]
assert_dir_exists "/path/to/dir" ["message"]
assert_command_exists "command" ["message"]
assert_contains "haystack" "needle" ["message"]
```

### Utility Functions

```bash
# Container helpers
wait_for_container "container_name" [timeout] [interval]
wait_for_http "http://url" [timeout] [interval]

# Test utilities
random_string [length]
test_container_name
get_free_port
temp_test_dir

# Chaos helpers
simulate_network_partition "target_ip" [duration]
limit_bandwidth "interface" "rate"
consume_memory "size_mb" [duration]
create_disk_pressure "/path" "size_mb"
block_dns [duration]
```

### Logging Functions

```bash
log_info "message"
log_success "message"
log_error "message"
log_warn "message"
log_skip "message"
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0    | All tests passed |
| 1    | One or more tests failed |
| 2    | Invalid arguments |
| 3    | Prerequisites not met |
| 77   | Test skipped (used internally) |

## Contributing

When adding new tests:
1. Follow the existing naming conventions
2. Include proper setup and cleanup
3. Add tests to the appropriate directory
4. Update this README with test descriptions
5. Ensure tests are idempotent and independent
6. Use the testlib.sh functions for consistency

## License

See repository LICENSE file for details.
