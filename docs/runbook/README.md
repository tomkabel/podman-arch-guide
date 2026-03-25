# Operations Runbook

Common operational procedures, incident response, and maintenance checklists.

## Common Operational Tasks

### Container Management

#### Start/Stop/Restart Container

```bash
# Start a container
podman start myapp

# Stop a container (graceful)
podman stop myapp

# Stop immediately (force)
podman stop -t 0 myapp

# Restart container
podman restart myapp

# View container status
podman ps -a --filter "name=myapp"
```

#### View Logs

```bash
# View recent logs
podman logs myapp

# Follow logs in real-time
podman logs -f myapp

# View last 100 lines
podman logs --tail 100 myapp

# View logs since specific time
podman logs --since "2024-01-01T00:00:00Z" myapp
```

#### Access Container Shell

```bash
# Open bash shell in container
podman exec -it myapp /bin/bash

# Run single command
podman exec myapp ls -la /app

# Execute as specific user
podman exec -u 1000 myapp whoami
```

### Image Management

```bash
# Pull latest image
podman pull myregistry/myapp:latest

# List images
podman images

# Remove unused images
podman image prune -a

# Build image from Dockerfile
podman build -t myapp:1.0 .

# Tag image for registry
podman tag myapp:1.0 myregistry/myapp:1.0
```

### Volume Management

```bash
# List volumes
podman volume ls

# Inspect volume
podman volume inspect myvolume

# Remove unused volumes
podman volume prune

# Create volume with options
podman volume create \
  --opt type=tmpfs \
  --opt device=tmpfs \
  --opt o=size=100m \
  myvolume
```

### Network Management

```bash
# List networks
podman network ls

# Inspect network
podman network inspect podman

# Create network
podman network create mynetwork

# Remove network
podman network rm mynetwork
```

## Incident Response Procedures

### Container Not Starting

```bash
# 1. Check container status
podman ps -a

# 2. View logs for errors
podman logs myapp

# 3. Inspect container
podman inspect myapp

# 4. Check events
podman system events --filter event=start

# 5. Check resource availability
podman system df

# Common fixes:
# - Remove stuck container: podman rm -f myapp
# - Clear build cache: podman builder prune -a
```

### High Memory Usage

```bash
# 1. Identify containers using memory
podman stats --no-stream

# 2. Check container memory limits
podman inspect myapp --format '{{.HostConfig.Memory}}'

# 3. View process list in container
podman top myapp

# 4. Restart affected container
podman restart myapp
```

### Network Connectivity Issues

```bash
# 1. Check network status
podman network ls

# 2. Inspect container network
podman inspect myapp --format '{{.NetworkSettings.Networks}}'

# 3. Test connectivity from container
podman exec myapp ping -c 3 8.8.8.8

# 4. Restart podman socket
systemctl --user restart podman.socket
```

### Disk Space Issues

```bash
# 1. Check disk usage
podman system df

# 2. List large containers
podman ps -s --sort size

# 3. Clean unused data
podman system prune -a --volumes -f

# 4. Remove unused images
podman image prune -a -f
```

## Daily/Weekly/Monthly Checklist

### Daily Checks

| Task | Command | Expected |
|------|---------|----------|
| Check running containers | `podman ps` | All expected containers running |
| Check container health | `podman ps --format '{{.Names}}: {{.Status}}'` | All healthy |
| Check disk space | `podman system df` | Usage < 80% |
| Check logs for errors | `podman logs --tail 500 myapp \| grep -i error` | No recent errors |

### Weekly Tasks

```bash
#!/bin/bash
# weekly-maintenance.sh

echo "=== Weekly Podman Maintenance ==="

echo "Cleaning unused images..."
podman image prune -a -f

echo "Cleaning unused volumes..."
podman volume prune -f

echo "Cleaning build cache..."
podman builder prune -a -f

echo "Checking for updates..."
podman pull myapp:latest || echo "Update check complete"

echo "Reviewing container logs..."
for container in $(podman ps --format '{{.Names}}'); do
    errors=$(podman logs --tail 100 $container 2>&1 | grep -ic error || true)
    if [ "$errors" -gt 0 ]; then
        echo "WARNING: $container has $errors errors"
    fi
done

echo "=== Weekly Maintenance Complete ==="
```

### Monthly Tasks

```bash
#!/bin/bash
# monthly-maintenance.sh

echo "=== Monthly Podman Maintenance ==="

echo "Full system prune..."
podman system prune -a --volumes -f

echo "Rebuilding stale images..."
podman image list --format '{{.Names}}' | while read image; do
    podman rmi $image || true
done

echo "Reviewing resource usage trends..."
podman stats --no-stream --format '{{.Name}},{{.CPU}},{{.MemUsage}}'

echo "Checking for security updates..."
sudo pacman -Syu

echo "=== Monthly Maintenance Complete ==="
```

## Emergency Procedures

### Complete System Failure

```bash
#!/bin/bash
# emergency-recovery.sh

# 1. Stop all containers
echo "Stopping all containers..."
podman stop $(podman ps -q) 2>/dev/null || true

# 2. Check Podman service status
echo "Checking Podman service..."
systemctl --user status podman.socket

# 3. Restart Podman
echo "Restarting Podman service..."
systemctl --user restart podman.socket

# 4. Wait for service
sleep 5

# 5. Start critical containers
echo "Starting critical containers..."
podman start critical-app

# 6. Verify
echo "Verifying containers..."
podman ps
```

### Data Recovery

```bash
# 1. List volumes
podman volume ls

# 2. Inspect specific volume
podman volume inspect myvolume

# 3. Create backup
podman run --rm \
  -v myvolume:/source:ro \
  -v $(pwd):/backup:rw \
  alpine \
  tar czf /backup/volume-backup.tar.gz -C /source .

# 4. Restore from backup
podman run --rm \
  -v myvolume:/target:rw \
  -v $(pwd):/backup:ro \
  alpine \
  tar xzf /backup/volume-backup.tar.gz -C /target
```

### Rollback Procedures

```bash
# 1. List available images (by date)
podman images --format '{{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}'

# 2. Tag previous version
podman tag myregistry/myapp:previous myregistry/myapp:rollback

# 3. Stop current container
podman stop myapp

# 4. Remove current container
podman rm myapp

# 5. Start with previous image
podman run -d --name myapp myregistry/myapp:rollback
```

### Network Reset

```bash
# 1. Stop all containers using network
podman stop $(podman ps -q)

# 2. Remove all custom networks
podman network rm $(podman network ls -q) 2>/dev/null || true

# 3. Recreate default network
podman network create podman

# 4. Restart Podman socket
systemctl --user restart podman.socket

# 5. Start containers
podman start $(podman ps -aq)
```

## Rollback Procedures

### Application Rollback

```bash
# rollback.sh - Rollback to previous version

# Get previous image tag
PREVIOUS_TAG="${APP_REGISTRY}/${APP_NAME}:${PREVIOUS_VERSION}"

# Stop current container
podman stop $APP_NAME

# Remove current container
podman rm $APP_NAME

# Run previous version
podman run -d \
  --name $APP_NAME \
  --network $APP_NETWORK \
  -p $APP_PORT:$APP_PORT \
  $PREVIOUS_TAG

# Verify
podman logs --tail 50 $APP_NAME
```

### Database Rollback

```bash
# 1. Stop application
podman stop myapp

# 2. Create database backup before rollback
podman exec mydb pg_dump -U postgres mydb > /backup/pre-rollback.sql

# 3. Restore from backup
podman exec -i mydb psql -U postgres mydb < /backup/previous-backup.sql

# 4. Start application
podman start myapp
```

## Links

### Templates and Tools

- [Postmortem Template](https://github.com/dastergon/postmortem-templates)
- [Incident Response Guide](../incident-response/README.md)
- [Monitoring Setup](../monitoring/README.md)
