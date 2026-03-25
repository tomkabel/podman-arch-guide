---
layout: default
title: Operations Runbook
nav_order: 2
---

<span class="section-label">// 02_operations.sh</span>

# Operations Runbook

Incident response procedures and operational best practices.

---

## Container Management

### Start / Stop / Restart

```bash
# Start a container
podman start my-container

# Stop gracefully
podman stop my-container

# Force stop
podman kill my-container

# Restart
podman restart my-container
```

### Logs

```bash
# Follow logs in real-time
podman logs -f my-container

# Last 100 lines
podman logs --tail 100 my-container

# Since timestamp
podman logs --since 2024-01-01T00:00:00Z my-container
```

---

## Incident Response

### Container Not Starting

```bash
# 1. Check logs
podman logs <container>

# 2. Inspect configuration
podman inspect <container>

# 3. Run healthcheck
podman healthcheck run <container>

# 4. Check events
podman events --since 5m
```

### High Resource Usage

```bash
# Real-time stats
podman stats --all

# Top processes
podman top <container>

# Detailed info
podman inspect <container> | jq
```

---

## Daily Checklist

- [ ] `podman ps -a` — Verify all containers running
- [ ] `podman logs --tail 50 $(podman ps -q)` — Review recent logs
- [ ] `podman healthcheck run $(podman ps -q)` — Verify health checks
- [ ] `podman stats --no-stream` — Check resource usage

## Weekly Tasks

```bash
# Clean unused images
podman image prune -af

# Review capacity
podman system df

# Backup volumes
./scripts/backup.sh --all
```

---

## Emergency Procedures

### Rollback Deployment

```bash
# Force rollback to previous version
./scripts/rollback.sh <app-name> --force
```

### Full System Restart

```bash
# Graceful shutdown
podman-compose down

# Start services
podman-compose up -d
```

### Emergency Recovery

```bash
# Reset podman system
podman system reset --force

# Rebuild everything
make rebuild
```

---

## See Also

- [Architecture Guide](../architecture/)
- [Monitoring](../monitoring/)
- [Post-Incident Template](../incident-response/)

---

```bash
# System status check
podman ps -a && echo "---" && podman stats --no-stream
```