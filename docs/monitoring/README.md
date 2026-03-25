# Monitoring Setup

Prometheus, Grafana, alerting, and observability configuration.

## Prometheus Configuration

### Installation

```bash
# Install Prometheus
sudo pacman -S prometheus

# Create configuration directory
mkdir -p /home/notroot/.config/prometheus
```

### Podman Metrics Exporter

```yaml
# docker-compose.yml
version: "3.8"

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
    restart: unless-stopped

  podman-exporter:
    image: quay.io/bobbylite/podman-exporter:latest
    container_name: podman-exporter
    ports:
      - "9180:9180"
    environment:
      - PODMAN_SOCKET=unix:///run/user/1000/podman/podman.sock
    restart: unless-stopped

volumes:
  prometheus-data:
```

### Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - "alerts/*.yml"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "podman"
    static_configs:
      - targets: ["podman-exporter:9180"]
    metrics_path: "/metrics"

  - job_name: "node-exporter"
    static_configs:
      - targets: ["node-exporter:9100"]
```

### Basic Podman Metrics

```bash
# Access podman metrics directly
curl http://localhost:9180/metrics

# Key metrics:
# - podman_container_info - Container metadata
# - podman_container_restart_count - Restart counts
# - podman_container_cpu_usage_seconds_total - CPU usage
# - podman_container_memory_usage_bytes - Memory usage
# - podman_container_network_receive_bytes_total - Network RX
# - podman_container_network_transmit_bytes_total - Network TX
```

## Grafana Dashboards Setup

### Installation

```yaml
# docker-compose.yml
version: "3.8"

services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=changeme
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
    restart: unless-stopped

volumes:
  grafana-data:
```

### Import Dashboard

```bash
# Access Grafana at http://localhost:3000
# Login with admin/changeme

# Import via API
curl -X POST http://admin:changeme@localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d @dashboard.json
```

### Podman Dashboard JSON

```json
{
  "dashboard": {
    "title": "Podman Containers",
    "tags": ["podman", "containers"],
    "timezone": "browser",
    "panels": [
      {
        "title": "Container Status",
        "type": "stat",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
        "targets": [
          {
            "expr": "count(podman_container_info{state=\"running\"})",
            "legendFormat": "Running"
          },
          {
            "expr": "count(podman_container_info{state=\"exited\"})",
            "legendFormat": "Stopped"
          }
        ]
      },
      {
        "title": "CPU Usage",
        "type": "graph",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
        "targets": [
          {
            "expr": "rate(podman_container_cpu_usage_seconds_total[5m])",
            "legendFormat": "{{name}}"
          }
        ]
      },
      {
        "title": "Memory Usage",
        "type": "graph",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
        "targets": [
          {
            "expr": "podman_container_memory_usage_bytes",
            "legendFormat": "{{name}}"
          }
        ]
      },
      {
        "title": "Network I/O",
        "type": "graph",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
        "targets": [
          {
            "expr": "rate(podman_container_network_receive_bytes_total[5m])",
            "legendFormat": "{{name}} RX"
          },
          {
            "expr": "rate(podman_container_network_transmit_bytes_total[5m])",
            "legendFormat": "{{name}} TX"
          }
        ]
      }
    ]
  }
}
```

## Alert Definitions

### Prometheus Alerts

```yaml
# alerts/container-alerts.yml
groups:
  - name: container_alerts
    rules:
      - alert: ContainerDown
        expr: absent(podman_container_info{state="running"})
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Container is down"
          description: "Container {{ $labels.name }} has been down for more than 1 minute"

      - alert: ContainerHighRestarts
        expr: podman_container_restart_count > 5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Container restarting frequently"
          description: "Container {{ $labels.name }} has restarted {{ $value }} times"

      - alert: ContainerHighCPU
        expr: rate(podman_container_cpu_usage_seconds_total[5m]) > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage"
          description: "Container {{ $labels.name }} CPU usage is above 80%"

      - alert: ContainerHighMemory
        expr: podman_container_memory_usage_bytes > 1073741824
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage"
          description: "Container {{ $labels.name }} memory usage exceeds 1GB"

      - alert: ContainerNetworkHigh
        expr: rate(podman_container_network_receive_bytes_total[5m]) > 104857600
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High network traffic"
          description: "Container {{ $labels.name }} receiving over 100MB/s"
```

### AlertManager Configuration

```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'team-notifications'
  routes:
    - match:
        severity: critical
      receiver: 'critical-alerts'
      continue: true

receivers:
  - name: 'team-notifications'
    email_configs:
      - to: 'team@example.com'
        send_resolved: true

  - name: 'critical-alerts'
    email_configs:
      - to: 'oncall@example.com'
        send_resolved: true
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK'
        channel: '#alerts'
```

## SLI/SLO Explanation

### Service Level Indicators

| Indicator | Metric | Target |
|-----------|--------|--------|
| Availability | Container uptime | > 99.9% |
| Latency | Response time p95 | < 200ms |
| Throughput | Requests per second | > 1000 |
| Error Rate | Failed requests | < 0.1% |

### SLO Definitions

```yaml
# alerts/slo-alerts.yml
groups:
  - name: slo_alerts
    rules:
      - alert: AvailabilitySLOViolation
        expr: (sum(rate(container_requests_total{success="true"}[5m])) / sum(rate(container_requests_total[5m]))) < 0.999
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Availability SLO breach"
          description: "Current availability: {{ $value | humanizePercentage }}"

      - alert: LatencySLOViolation
        expr: histogram_quantile(0.95, rate(container_request_duration_seconds_bucket[5m])) > 0.2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Latency SLO breach"
          description: "p95 latency: {{ $value | humanizeDuration }}"
```

### Error Budget

```bash
# Calculate error budget
# Monthly SLO: 99.9% availability
# Total minutes in month: 43200
# Allowed downtime: 43200 * 0.001 = 43.2 minutes

# Check remaining error budget
# curl http://prometheus:9090/api/v1/query?query=... 
```

## Creating Custom Alerts

### Step 1: Define Metric

```bash
# Add custom metric to application
# Example: request counter with labels
podman run -d myapp:latest

# Check custom metrics
curl http://localhost:8080/metrics
```

### Step 2: Add Alert Rule

```yaml
# alerts/custom-alerts.yml
groups:
  - name: custom_alerts
    rules:
      - alert: CustomMetricAlert
        expr: custom_metric_threshold > 100
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Custom metric threshold exceeded"
          description: "{{ $labels.name }}: {{ $value }}"
```

### Step 3: Reload Prometheus

```bash
# Send SIGHUP to reload config
podman exec prometheus kill -HUP 1

# Or use API
curl -X POST http://localhost:9090/-/reload
```

### Alert Templates

```yaml
# Generic alert template
- alert: <ALERT_NAME>
  expr: <PROMQL_EXPRESSION>
  for: <DURATION>
  labels:
    severity: <critical|warning>
  annotations:
    summary: "<Short description>"
    description: "<Detailed description with {{ $value }}>"
```

## Quick Reference

| Command | Description |
|---------|-------------|
| `podman stats` | Real-time container stats |
| `podman inspect` | Container details |
| `podman logs` | Container logs |
| `curl localhost:9090/graph` | Prometheus UI |
| `curl localhost:3000` | Grafana UI |
| `curl localhost:9180/metrics` | Podman metrics |
