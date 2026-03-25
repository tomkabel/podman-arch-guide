---
layout: default
title: Quick Start Guide
nav_order: 1
---

# Quick Start Guide

Get started with Podman on Arch Linux in 15 minutes.

## Prerequisites

### System Requirements

| Requirement | Specification |
|-------------|---------------|
| OS | Arch Linux (rolling release) |
| Kernel | 5.15+ |
| RAM | 4GB minimum, 8GB recommended |
| Storage | 20GB available space |
| Network | Internet connectivity |

### Install Podman

```bash
sudo pacman -S podman podman-compose
```

Verify installation:
```bash
podman --version
podman-compose --version
```

## First Container (5 min)

### Pull and Run

```bash
# Pull an image
podman pull docker.io/library/alpine:latest

# Run a container
podman run -it --name my-alpine alpine:latest /bin/sh
```

### Run in Detached Mode

```bash
podman run -d --name web nginx:alpine
podman ps
```

## Deploy a Web App (10 min)

### Using podman-compose

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
```

```bash
podman-compose up -d
```

### Health Checks

```bash
podman healthcheck run web
curl http://localhost:8080
```

## Basic Monitoring

```bash
# Check container stats
podman stats --all

# View logs
podman logs web

# Inspect container
podman inspect web
```

## Cleanup

```bash
podman-compose down
podman system prune -a
```

## Next Steps

- [Operations Runbook](../runbook/) - Incident response procedures
- [Architecture Guide](../architecture/) - Design patterns
- [Multi-Node Deployment](../architecture/multi-node-deployment/) - HA setup
