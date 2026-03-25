---
layout: default
title: Quick Start Guide
nav_order: 1
---

<span class="section-label">// 01_getting-started.sh</span>

# Quick Start Guide

Get up and running with Podman on Arch Linux in 15 minutes.

---

## System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Arch Linux (rolling) | Arch Linux (rolling) |
| Kernel | 5.15+ | 6.x+ |
| RAM | 4 GB | 8 GB |
| Storage | 20 GB | 50 GB |
| Network | Internet | Internet |

---

## Installation

```bash
# Install Podman and compose
sudo pacman -Syu podman podman-compose

# Verify installation
podman --version
podman-compose --version
```

---

## First Container

### Pull & Run Interactive

```bash
# Pull image from registry
podman pull docker.io/library/alpine:latest

# Run interactive shell
podman run -it --name my-alpine alpine:latest /bin/sh
```

### Run Detached

```bash
# Start nginx in background
podman run -d --name web nginx:alpine

# List running containers
podman ps
```

---

## Deploy with Compose

Create `docker-compose.yml`:

```yaml
version: '3'
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
```

Deploy:

```bash
# Start services
podman-compose up -d

# View status
podman-compose ps

# Check health
podman healthcheck run web
```

---

## Monitoring

```bash
# Real-time stats
podman stats --all

# View logs
podman logs -f web

# Inspect container
podman inspect web

# System info
podman system info
```

---

## Cleanup

```bash
# Stop services
podman-compose down

# Remove unused resources
podman system prune -af
```

---

## Next Steps

- [Operations Runbook](../runbook/) — Incident response & daily tasks
- [Architecture Guide](../architecture/) — Design patterns & decisions
- [Multi-Node Deployment](../architecture/multi-node-deployment/) — HA cluster setup

---

```bash
# You're ready to deploy!
podman run --rm -it archlinux:latest /bin/bash
```