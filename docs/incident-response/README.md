# Incident Response

Procedures for handling incidents, escalation, and post-incident reviews.

## Response Procedures

### Initial Response Steps

```bash
# 1. Identify affected containers
podman ps -a

# 2. Check container status
podman inspect <container> | jq '.State'

# 3. View recent logs
podman logs --tail 100 <container>

# 4. Check resource usage
podman stats --no-stream

# 5. Export container details for debugging
podman inspect <container> > /tmp/container-inspect.json
podman logs <container> > /tmp/container-logs.txt
```

### Common Incident Types

#### Container Not Responding

```bash
# Check if container is running
podman ps -a | grep <container>

# Inspect container state
podman inspect <container> --format '{{.State.Status}}'

# Try exec into container
podman exec -it <container> /bin/sh

# Restart container
podman restart <container>

# If unresponsive, force stop and restart
podman stop -t 0 <container>
podman rm <container>
podman run -d <previous-flags> <image>
```

#### High Resource Usage

```bash
# Identify resource consumers
podman stats --no-stream --format "table {{.Name}}\t{{.CPU}}\t{{.MemUsage}}"

# Kill problematic process inside container
podman exec <container> ps aux
podman exec <container> kill -9 <pid>

# Limit container resources
podman update --memory=512m --cpus=1.0 <container>
```

#### Network Issues

```bash
# Check network connectivity
podman network ls

# Inspect container network
podman inspect <container> --format '{{.NetworkSettings.Networks}}'

# Restart podman networking
systemctl --user restart podman.socket

# Recreate network
podman network rm <network>
podman network create <network>
```

### Immediate Mitigation

```bash
#!/bin/bash
# emergency-mitigation.sh

# Stop affected container
podman stop -t 0 $CONTAINER_NAME

# Start backup container
podman start $BACKUP_CONTAINER

# Update load balancer if needed
# (addres:port to backup)

# Preserve logs for investigation
podman logs $CONTAINER_NAME > /tmp/incident-$DATE.log
```

## Escalation Matrix

### Severity Levels

| Severity | Description | Response Time | Examples |
|----------|-------------|---------------|----------|
| SEV1 | Critical - Complete outage | 15 minutes | All services down |
| SEV2 | Major - Partial outage | 30 minutes | Key service down |
| SEV3 | Minor - Degraded performance | 2 hours | Slow response |
| SEV4 | Low - Minor issue | 24 hours | Non-critical |

### Escalation Contacts

| Role | Contact | Responsibility |
|------|---------|-----------------|
| On-Call Engineer | oncall@example.com | Initial response |
| Team Lead | lead@example.com | SEV2+ incidents |
| Engineering Manager | manager@example.com | SEV1 incidents |
| VP Engineering | vp@example.com | All SEV1 |

### Escalation Process

```
SEV4/SEV3 → Team Lead (24h/2h)
     ↓
SEV2 → Engineering Manager (30m)
     ↓
SEV1 → VP Engineering + All Hands (15m)
```

### Communication Templates

#### Initial Alert

```
INCIDENT: <title>
SEVERITY: <SEV1-4>
IMPACT: <description>
CONTAINERS AFFECTED: <list>
CURRENT STATUS: <investigating/identified/mitigating/resolved>
ACTION: <immediate action taken>
```

#### Status Update

```
UPDATE: <incident title>
STATUS: <investigating|identified|mitigating|resolved>
PROGRESS: <what's been done>
NEXT STEPS: <what's next>
ETA: <estimated resolution time>
```

## Post-Incident Review Process

### Timeline Collection

```bash
# Export relevant logs
podman logs --since "2024-01-01T00:00:00Z" <container> > /tmp/incident-logs.txt

# Export system events
podman system events --since 24h > /tmp/events.txt

# Export container stats
podman stats --no-stream --format "{{.Name}},{{.CPU}},{{.MemUsage}}" > /tmp/stats.csv
```

### Post-Incident Review Template

```markdown
# Post-Incident Review

## Incident Summary
- **Date**: YYYY-MM-DD
- **Duration**: X hours Y minutes
- **Severity**: SEV1-4
- **Impact**: Description of impact

## Timeline
| Time | Event |
|------|-------|
| HH:MM | Incident detected |
| HH:MM | Initial response |
| HH:MM | Root cause identified |
| HH:MM | Mitigation deployed |
| HH:MM | Service restored |

## Root Cause
Description of the technical root cause.

## What Went Well
- List of successful responses

## What Could Be Improved
- List of improvement areas

## Action Items
| Action | Owner | Due Date |
|--------|-------|----------|
| Fix root cause | @owner | YYYY-MM-DD |
| Add monitoring | @owner | YYYY-MM-DD |
| Update runbook | @owner | YYYY-MM-DD |

## Lessons Learned
Key takeaways from the incident.
```

### Action Item Tracking

```bash
# Create action item in project tracking
# Example: Create GitHub issue

cat <<EOF > incident-actions.md
# Incident Action Items

## Infrastructure
- [ ] Implement auto-scaling for containers
- [ ] Add health check for critical service

## Monitoring
- [ ] Create alert for high memory usage
- [ ] Add latency SLO alert

## Process
- [ ] Update runbook with incident steps
- [ ] Schedule incident drill
EOF
```

## Link to Template

### External Resources

- [Postmortem Template - Google](https://sre.google/sre-book/postmortem-culture/)
- [Postmortem Template - Atlassian](https://www.atlassian.com/incident-management/handbook/postmortems)
- [Incident Response Guide - NIST](https://nvd.nist.gov/800-53)

### Internal Templates

Find additional templates in:

```
/home/notroot/Documents/podman/repo/docs/
├── templates/
│   ├── postmortem-template.md
│   └── incident-communication-template.md
```

### Quick Reference

| Command | Purpose |
|---------|---------|
| `podman ps -a` | List all containers |
| `podman logs` | View container logs |
| `podman stats` | Real-time stats |
| `podman inspect` | Container details |
| `podman system events` | System events |
