---
layout: default
title: Monitoring & Alerts
nav_order: 4
---

# Monitoring & Alerts

SLI/SLO implementation with Prometheus and Grafana.

## Service Level Indicators (SLIs)

| Metric | Query |
|--------|-------|
| Container Availability | `uptime / total_time` |
| Deployment Success | `successful_deploys / total_deploys` |
| Rollback Time | Time to complete rollback |
| MTTR | Mean time to recovery |

## Service Level Objectives (SLOs)

| SLI | Target |
|-----|--------|
| Container Availability | 99.9% |
| Deployment Success | 99% |
| Rollback Time | < 5 min |
| MTTR | < 15 min |

## Prometheus Configuration

### Alerts

```yaml
groups:
- name: podman
  rules:
  - alert: ContainerDown
    expr: podman_container_up == 0
    for: 5m
  - alert: HighMemoryUsage
    expr: container_memory_usage_bytes / container_spec_memory_limit_bytes > 0.9
    for: 5m
```

## Grafana Dashboards

Import from `monitoring/prometheus/` directory.

## Alerting Channels

Configure in `monitoring/alertmanager/`.

## See Also

- [SLI/SLO Configuration]({{ site.baseurl }}/monitoring/prometheus/slos.yml)
- [Alert Rules]({{ site.baseurl }}/monitoring/prometheus/rules.d/alerts.yml)
