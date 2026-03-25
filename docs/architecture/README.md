# Architecture Overview

System design, technology choices, and infrastructure patterns.

## Design Principles

### Core Principles

1. **Rootless by Default**
   - All containers run as non-root users
   - User namespace mapping enabled
   - Reduced attack surface

2. **Immutability**
   - Containers are ephemeral and replaceable
   - State stored in persistent volumes
   - Configuration via environment variables

3. **Declarative Configuration**
   - Infrastructure as code using Quadlets
   - Version controlled configurations
   - Reproducible deployments

4. **Observability**
   - Structured logging
   - Health checks on all services
   - Metrics exposed for monitoring

### Architecture Patterns

```
┌─────────────────────────────────────────────────────────────┐
│                      Client Requests                         │
└──────────────────────────┬──────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │  Load       │
                    │  Balancer   │
                    └──────┬──────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
   ┌─────▼─────┐    ┌─────▼─────┐    ┌─────▼─────┐
   │ Container │    │ Container │    │ Container │
   │   (App)   │    │   (App)   │    │   (App)   │
   └─────┬─────┘    └─────┬─────┘    └─────┬─────┘
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
                    ┌──────▼──────┐
                    │   Volume    │
                    │  (Storage)  │
                    └─────────────┘
```

## Technology Choices Explained

### Why Podman?

| Feature | Podman | Docker |
|---------|--------|--------|
| Rootless | Native | Requires Docker daemon |
| Daemon-less | Yes | No |
| systemd integration | Native Quadlets | Requires wrapper |
| CRI compatible | Yes | Yes |
| Buildah integration | Yes | No |

### Why Ceph for Storage?

- **Distributed**: Data replicated across nodes
- **Self-healing**: Automatic recovery from failures
- **Scalable**: Add nodes without downtime
- **Consistent**: Strong consistency guarantees

### Why WireGuard for Networking?

- **Performance**: Kernel-level encryption
- **Simplicity**: Single binary, minimal config
- **Security**: Modern cryptography (Curve25519, ChaCha20)
- **Mesh support**: Peer-to-peer connectivity

## Security Model

### Container Security

```bash
# Run container with security restrictions
podman run \
  --security-opt seccomp=/path/to/seccomp.json \
  --security-opt no-new-privileges:true \
  --read-only \
  --tmpfs /tmp \
  myapp:latest
```

### User Namespace Mapping

```bash
# Map container root to unprivileged host user
podman run --map-root-user myapp:latest

# Custom UID/GID mapping
podman run --userns=keep-id:uid=1000,gid=1000 myapp:latest
```

### Network Policies

```yaml
# podman network with isolation
podman network create \
  --subnet 10.0.0.0/24 \
  --gateway 10.0.0.1 \
  --internal \
  isolated-network
```

### Secret Management

```bash
# Create secret from file
podman secret create db-pass /path/to/password.txt

# Use secret in container
podman run -d --secret db-pass myapp:latest
```

## Network Architecture

### Network Layers

```
┌─────────────────────────────────────────────┐
│             Public Internet                 │
└─────────────────┬───────────────────────────┘
                  │
         ┌────────▼────────┐
         │   Load Balancer  │
         │   (HAProxy)      │
         └────────┬────────┘
                  │
    ┌─────────────┼─────────────┐
    │             │             │
┌───▼───┐    ┌───▼───┐    ┌───▼───┐
│ Node1 │    │ Node2 │    │ Node3 │
│ Podman│    │Podman │    │Podman │
└───┬───┘    └───┬───┘    └───┬───┘
    │             │             │
    └─────────────┼─────────────┘
                  │
         ┌────────▼────────┐
         │  WireGuard Mesh │
         │  (10.200.0.0/24)│
         └─────────────────┘
```

### Port Configuration

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| SSH | 22 | TCP | Management |
| HTTP | 80 | TCP | Web traffic |
| HTTPS | 443 | TCP | Secure web |
| WireGuard | 51820 | UDP | VPN mesh |
| Ceph MON | 6789 | TCP | Storage cluster |
| Ceph OSD | 6800-7300 | TCP | Storage OSDs |

## Storage Architecture

### Volume Types

| Type | Use Case | Persistence |
|------|----------|-------------|
| bind-mount | Config files | Host-dependent |
| named volume | Application data | Container lifecycle |
| tmpfs | Sensitive data | RAM only |
| CephFS | Shared state | Cluster lifetime |

### Storage Flow

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Application │────▶│   Podman    │────▶│   Volume    │
│   Container  │     │   Storage   │     │   Driver    │
└──────────────┘     └──────────────┘     └──────────────┘
                                                  │
                    ┌─────────────────────────────┼─────────────┐
                    │                             │             │
              ┌─────▼─────┐               ┌──────▼─────┐ ┌──────▼─────┐
              │   Local   │               │   CephFS   │ │   tmpfs    │
              │   Disk    │               │   Cluster  │ │   Memory   │
              └───────────┘               └────────────┘ └─────────────┘
```

## High Availability Patterns

### Container HA

```yaml
# docker-compose.yml with replicas
version: "3.8"

services:
  app:
    image: myapp:latest
    deploy:
      replicas: 3
    restart_policy:
      condition: on-failure
      delay: 5s
      max_attempts: 3
```

### Health Check HA

```bash
# Container with health check
podman run -d \
  --health-cmd="curl -f http://localhost:8080/health" \
  --health-interval=30s \
  --health-retries=3 \
  --health-start-period=10s \
  myapp:latest
```

### Multi-Node Deployment

For production HA deployments, see [Multi-Node HA Deployment](multi-node-deployment.md) which covers:

- 3-node cluster setup
- Ceph distributed storage
- WireGuard mesh networking
- Load balancer configuration

## Multi-Cloud Considerations

### Cloud-Agnostic Design

| Layer | Technology | Cloud Independence |
|-------|------------|---------------------|
| Compute | Podman | Full |
| Storage | Ceph | Full |
| Network | WireGuard | Full |
| Orchestration | systemd | Full |

### Portability Guidelines

```bash
# Export container to OCI format
podman save myapp:latest -o myapp.tar

# Import on different system
podman load -i myapp.tar

# Use bind mounts for portability
podman run -v /data:/app/data:ro myapp:latest
```

### Hybrid Cloud Patterns

```
┌─────────────────────────────────────────────────────────────┐
│                     On-Premise Infrastructure              │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                     │
│  │ Node 1  │  │ Node 2  │  │ Node 3  │                     │
│  └────┬────┘  └────┬────┘  └────┬────┘                     │
│       └────────────┼────────────┘                          │
│              ┌─────▼─────┐                                  │
│              │  WireGuard│                                  │
│              │  Tunnel   │                                  │
│              └─────┬─────┘                                  │
└────────────────────┼────────────────────────────────────────┘
                     │
         ┌───────────▼───────────┐
         │    Cloud Provider     │
         │  (Backup/DR Site)     │
         └───────────────────────┘
```

## Related Documentation

- [Quickstart Guide](../quickstart/README.md) - Getting started
- [Operations Runbook](../runbook/README.md) - Daily operations
- [Monitoring Setup](../monitoring/README.md) - Observability
- [Incident Response](../incident-response/README.md) - Emergency procedures
- [Multi-Node Deployment](multi-node-deployment.md) - HA cluster setup
