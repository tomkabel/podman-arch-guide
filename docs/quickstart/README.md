# Quickstart Guide

Get started with Podman on Arch Linux in 15 minutes.

## Prerequisites

### System Requirements

| Requirement | Specification |
|-------------|---------------|
| OS | Arch Linux (latest) |
| Kernel | 5.15+ |
| RAM | 2 GB minimum, 4 GB recommended |
| Disk | 10 GB available |
| Network | Internet connection |

### Install Podman

```bash
# Update package database
sudo pacman -Sy

# Install Podman
sudo pacman -S podman

# Install Podman Compose (optional but recommended)
sudo pacman -S python-pip
pip install podman-compose

# Verify installation
podman --version
# Output: podman version 5.x.x

# Verify rootless Podman works
podman run --rm hello-world
```

### Configure Podman for Rootless Operation

```bash
# Ensure user has necessary groups
sudo usermod -aG podman $USER

# Log out and back in, or run:
newgrp podman

# Test rootless mode
podman info
```

## First Container in 5 Minutes

### Running Your First Container

```bash
# Pull and run a simple container
podman run -d --name myapp nginx:latest

# Check status
podman ps

# View logs
podman logs myapp

# Access the container
podman exec -it myapp /bin/bash

# Stop and remove
podman stop myapp
podman rm myapp
```

### Basic Container Management

```bash
# List running containers
podman ps

# List all containers (including stopped)
podman ps -a

# List images
podman images

# Pull an image
podman pull alpine:latest

# Remove an image
podman rmi alpine:latest
```

## Setting Up Podman-Compose

### Installation Verification

```bash
# Check podman-compose version
podman-compose --version

# Show help
podman-compose --help
```

### Create Your First Compose File

```yaml
# docker-compose.yml
version: "3.8"

services:
  web:
    image: nginx:latest
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped

  redis:
    image: redis:alpine
    restart: unless-stopped
    volumes:
      - redis-data:/data

volumes:
  redis-data:
```

### Run With Compose

```bash
# Start all services
podman-compose up -d

# View logs
podman-compose logs -f

# Stop all services
podman-compose down

# Scale a service
podman-compose up -d --scale web=3
```

## Deploying a Simple Web App with Nginx

### Project Structure

```
mywebapp/
├── docker-compose.yml
├── html/
│   └── index.html
└── nginx.conf
```

### Create the Compose File

```yaml
# docker-compose.yml
version: "3.8"

services:
  nginx:
    image: nginx:alpine
    container_name: mywebapp
    ports:
      - "80:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
```

### Create the HTML Content

```html
<!-- html/index.html -->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>My Podman App</title>
</head>
<body>
    <h1>Hello from Podman!</h1>
    <p>Container is running successfully.</p>
</body>
</html>
```

### Deploy

```bash
# Create directory
mkdir -p mywebapp/html

# Start the application
cd mywebapp
podman-compose up -d

# Verify it's running
curl http://localhost:80
```

## Health Checks

### Container Health Checks

```bash
# Check container health status
podman inspect --format='{{.State.Health.Status}}' myapp

# View health check logs
podman inspect myapp | jq '.[0].State.Health.Log'
```

### Adding Health Checks to Containers

```bash
# Run container with health check
podman run -d \
  --name myapp \
  --health-cmd="curl -f http://localhost:8080/health || exit 1" \
  --health-interval=30s \
  --health-timeout=10s \
  --health-retries=3 \
  --health-start-period=5s \
  myimage:latest
```

### Health Check with Quadlet

```ini
# ~/.config/containers/systemd/myapp/myapp.container
[Container]
ContainerName=myapp
Image=myimage:latest
HealthCheckCmd=curl -f http://localhost:8080/health
HealthCheckInterval=30s
HealthCheckTimeout=10s
HealthCheckRetries=3
HealthCheckStartPeriod=5s

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

## Basic Monitoring

### Using Podman Stats

```bash
# Real-time container statistics
podman stats --no-stream

# Specific container
podman stats myapp

# All containers with format
podman stats --no-trunc --format "table {{.Name}}\t{{.CPU}}\t{{.MemUsage}}\t{{.NetIO}}"
```

### Using CAdvisor for Monitoring

```yaml
# docker-compose.yml
version: "3.8"

services:
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    ports:
      - "8081:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    restart: unless-stopped
```

### Accessing Metrics

```bash
# View container logs
podman logs myapp

# View system information
podman system info

# View events
podman system events --filter event=health_check_failure
```

## Cleanup

### Stopping and Removing Containers

```bash
# Stop all running containers
podman stop $(podman ps -q)

# Remove all stopped containers
podman rm $(podman ps -aq)

# Remove all containers (running and stopped)
podman rm -f $(podman ps -aq)
```

### Cleaning Up Images and Volumes

```bash
# Remove unused images
podman image prune -a

# Remove unused volumes
podman volume prune

# Remove all unused data
podman system prune -a --volumes
```

### Complete Cleanup Script

```bash
#!/bin/bash
# cleanup.sh

echo "Stopping all containers..."
podman stop $(podman ps -q) 2>/dev/null || true

echo "Removing all containers..."
podman rm $(podman ps -aq) 2>/dev/null || true

echo "Removing unused images..."
podman image prune -a -f

echo "Removing unused volumes..."
podman volume prune -f

echo "Cleaning system..."
podman system prune -a --volumes -f

echo "Cleanup complete!"
```

## Next Steps

### Deeper Documentation

- [Architecture Overview](../architecture/README.md) - System design and patterns
- [Operations Runbook](../runbook/README.md) - Common tasks and procedures
- [Monitoring Setup](../monitoring/README.md) - Prometheus and Grafana configuration
- [Incident Response](../incident-response/README.md) - Response procedures

### Advanced Topics

- [Multi-Node HA Deployment](../architecture/multi-node-deployment.md) - Cluster setup
- [Capacity Planning](../capacity-planning/README.md) - Resource planning
- [Chaos Engineering](../chaos-engineering/game-days.md) - Resilience testing
- [Cost Optimization](../cost-optimization/README.md) - Resource optimization
