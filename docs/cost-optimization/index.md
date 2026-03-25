---
layout: default
title: Cost Optimization
---

# Cost Optimization

Cloud cost management and optimization strategies.

## Cost Estimates

| Deployment | AWS | GCP | Azure |
|------------|-----|-----|-------|
| Single Node | $50-100/mo | $40-80/mo | $45-90/mo |
| Blue/Green | $100-200/mo | $80-160/mo | $90-180/mo |
| Multi-Node (3x) | $300-500/mo | $240-400/mo | $270-450/mo |

## Optimization Strategies

- Use reserved instances for baseline
- Spot instances for non-critical workloads
- Right-size containers
- Enable auto-scaling
- Use preemptible/spot VMs

## Cost Calculators

Use `tools/cost-calculator/` for detailed estimates.
