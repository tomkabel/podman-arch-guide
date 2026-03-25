---
layout: default
title: Chaos Engineering
nav_order: 5
---

# Chaos Engineering

Game day procedures for validating system resilience.

## Game Day Scenarios

### 1. Container Kill
Randomly terminate containers to test auto-restart behavior.

### 2. Network Partition
Simulate network isolation between nodes to test failover.

### 3. Resource Exhaustion
Test system behavior under CPU/memory pressure.

### 4. Disk Pressure
Fill disk space and verify graceful degradation.

### 5. DNS Failure
Block DNS resolution to test fallback behavior.

## Running Chaos Tests

```bash
# Run container kill test
./tests/chaos/test_container_kill.sh

# Run network partition
./tests/chaos/test_network_partition.sh --duration 5m
```

## Expected Behavior

| Scenario | Expected Recovery |
|----------|------------------|
| Container Kill | Auto-restart < 30s |
| Network Partition | Failover < 60s |
| Resource Exhaustion | Graceful degradation |
| Disk Pressure | Read-only mode |
| DNS Failure | Fallback to /etc/hosts |

## Post-Game Review

- Document what failed
- Update runbooks
- Add monitoring for undetected failures

## See Also

- [Game Days Detail](game-days/)
