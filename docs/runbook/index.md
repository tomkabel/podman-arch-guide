---
layout: default
title: Operations Runbook
nav_order: 2
---

# Operations Runbook

Incident response procedures and operational best practices.

## Container Management

### Start/Stop Containers

```bash
# Start a container
podman start my-container

# Stop a container
podman stop my-container

# Restart
podman restart my-container
```

### View Logs

```bash
# View logs
podman logs -f my-container

# Last 100 lines
podman logs --tail 100 my-container
```

## Incident Response

### Container Not Starting

1. Check logs: `podman logs <container>`
2. Inspect: `podman inspect <container>`
3. Check health: `podman healthcheck run <container>`

### High Resource Usage

```bash
podman stats
podman top
```

## Daily Checklist

- [ ] Check container status: `podman ps -a`
- [ ] Review logs for errors
- [ ] Verify health checks
- [ ] Check resource usage

## Weekly Tasks

- [ ] Clean unused images: `podman image prune -a`
- [ ] Review capacity metrics
- [ ] Update containers if needed
- [ ] Backup volumes

## Emergency Procedures

### Rollback Deployment

```bash
./scripts/rollback.sh <app-name> --force
```

### Full System Restart

```bash
podman-compose down
podman-compose up -d
```

## See Also

- [Architecture Guide](../architecture/)
- [Monitoring](../monitoring/)
- [Post-Incident Template](../incident-response/)
