# Capacity Planning Guide

When to scale and how to plan for growth.

## Scaling Thresholds

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| CPU (sustained) | 70% | 85% | Add node or optimize |
| Memory | 80% | 90% | Increase limit or add node |
| Disk IOPS | 70% capacity | 85% capacity | Upgrade storage tier |
| Network bandwidth | 70% | 85% | Add NIC or load balancer |
| Container count | 50/node | 75/node | Add node |

## Capacity Formulas

### CPU
```
Required vCPUs = (Current vCPUs × Current CPU%) / Target CPU%

Example:
- Current: 4 vCPUs at 80% utilization
- Target: 70% utilization
- Required: (4 × 0.8) / 0.7 = 4.57 → 5 vCPUs
```

### Memory
```
Required Memory = Current Usage × 1.5 (headroom)

Example:
- Current usage: 12 GB
- Required: 12 × 1.5 = 18 GB
```

### Storage IOPS
```
Required IOPS = (Current IOPS / Current Utilization) × Target Utilization

Example:
- Current: 5000 IOPS at 80% utilization
- Target: 70% utilization
- Required: (5000 / 0.8) × 0.7 = 4375 → 5000 IOPS (next tier)
```

## Growth Projection

```bash
#!/bin/bash
# capacity-projector.sh

CURRENT_TRAFFIC=${1:-1000}  # requests/minute
GROWTH_RATE=${2:-0.15}      # 15% monthly growth
MONTHS=${3:-6}

echo "Traffic Projection:"
echo "Current: $CURRENT_TRAFFIC req/min"
echo "Growth: $(echo "$GROWTH_RATE * 100" | bc)%/month"
echo ""

for i in $(seq 1 $MONTHS); do
    projected=$(echo "$CURRENT_TRAFFIC * (1 + $GROWTH_RATE)^$i" | bc -l)
    nodes=$(echo "($projected / 1000) + 1" | bc)  # 1000 req/min per node
    echo "Month $i: $(printf "%.0f" $projected) req/min → $nodes nodes"
done
```

## Load Testing for Capacity Validation

```bash
#!/bin/bash
# capacity-test.sh

ENDPOINT=${1:-http://localhost:8080}
START_RPS=${2:-100}
MAX_RPS=${3:-2000}
STEP=${4:-100}
DURATION=${5:-60}

echo "=== Capacity Test ==="
echo "Endpoint: $ENDPOINT"
echo "Range: ${START_RPS}-${MAX_RPS} RPS"
echo ""

for rps in $(seq $START_RPS $STEP $MAX_RPS); do
    echo "Testing $rps RPS for ${DURATION}s..."
    
    # Run load test
    results=$(wrk -t4 -c100 -d${DURATION}s -R$rps $ENDPOINT 2>&1)
    
    # Parse results
    latency=$(echo "$results" | grep "Latency" | awk '{print $2}')
    errors=$(echo "$results" | grep "Socket errors" | awk '{print $3}')
    
    echo "  Latency: $latency | Errors: $errors"
    
    # Check thresholds
    if [[ -n "$errors" && "$errors" -gt 0 ]]; then
        echo "  ❌ FAIL: Errors detected at $rps RPS"
        echo "  Maximum capacity: $((rps - STEP)) RPS"
        break
    fi
done
```

## Capacity Planning Worksheet

```
Current State:
- Nodes: ___
- vCPUs per node: ___
- Memory per node: ___ GB
- Storage per node: ___ GB
- Network per node: ___ Gbps

Current Utilization (p95):
- CPU: ___%
- Memory: ___%
- Disk IOPS: ___%
- Network: ___%

Growth Projections:
- Traffic growth: ___%/month
- Data growth: ___ GB/month

Required in 6 Months:
- Nodes: ___
- vCPUs per node: ___
- Memory per node: ___ GB
- Storage per node: ___ GB
- Network per node: ___ Gbps

Scaling Trigger:
- Scale when CPU > ___%
- Scale when Memory > ___%
```

---

**Next**: [Chaos Engineering](../chaos-engineering/game-days.md)
