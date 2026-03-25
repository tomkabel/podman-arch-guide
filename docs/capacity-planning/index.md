---
layout: default
title: Capacity Planning
---

# Capacity Planning

Scaling thresholds, formulas, and growth projections.

## Scaling Triggers

| Resource | Trigger | Action |
|----------|---------|--------|
| CPU | 70% sustained | Add node |
| Memory | 80% usage | Add node |
| Disk IOPS | 10,000 | Upgrade SSD |
| Network | 1 Gbps | Upgrade NIC |

## Formulas

### Horizontal Scaling
```
nodes_needed = ceil(current_requests / requests_per_node)
```

### Storage Growth
```
storage_needed = current_usage * (1 + growth_rate)^months
```

## Capacity Calculator

Use `tools/capacity-calculator/scale-planner.sh` for automated planning.
