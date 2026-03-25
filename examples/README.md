# Podman Deployment Examples

Production-ready example configurations for Podman container deployments.

## Overview

This repository contains four complete deployment scenarios:

| Example | Description | Use Case |
|---------|-------------|----------|
| [single-node](single-node/) | Complete single-node stack | Small deployments, development |
| [blue-green](blue-green/) | Blue-green deployment pattern | Zero-downtime updates |
| [multi-node](multi-node/) | 3-node HA cluster | Production HA requirements |
| [rootless](rootless/) | Rootless container configs | Enhanced security |

## Quick Start

### Single-Node Deployment

```bash
cd single-node
cp .env.example .env
# Edit .env with your settings
make setup
make start
```

### Blue-Green Deployment

```bash
cd blue-green
./scripts/switch.sh setup
./scripts/switch.sh pipeline v2.0.0
```

### Multi-Node Cluster

```bash
cd multi-node
./setup-cluster.sh
# Follow generated deployment guide
```

### Rootless Containers

```bash
cd rootless
./setup-rootless.sh
podman-compose up -d
```

## Common Features

All examples include:

- **Production-ready** configurations
- **Security hardening** (seccomp, AppArmor/SELinux, capabilities)
- **Health checks** for all services
- **Resource limits** (CPU, memory)
- **Network isolation**
- **Volume management**
- **Restart policies**
- **Comprehensive documentation**

## Directory Structure

```
examples/
├── single-node/          # Single node deployment
│   ├── docker-compose.yml
│   ├── quadlets/         # Systemd Quadlet files
│   ├── nginx/            # Reverse proxy config
│   ├── redis/            # Cache configuration
│   ├── init-scripts/     # Database initialization
│   ├── .env.example
│   ├── Makefile
│   └── README.md
│
├── blue-green/           # Blue-green deployment
│   ├── docker-compose-blue.yml
│   ├── docker-compose-green.yml
│   ├── docker-compose-proxy.yml
│   ├── haproxy/          # Load balancer config
│   ├── scripts/          # Deployment automation
│   ├── .env.example
│   └── README.md
│
├── multi-node/           # 3-node HA cluster
│   ├── docker-compose.yml
│   ├── wireguard/        # Mesh VPN configs
│   ├── ceph/             # Distributed storage
│   ├── keepalived/       # VIP management
│   ├── haproxy/          # Load balancing
│   ├── setup-cluster.sh
│   └── README.md
│
└── rootless/             # Rootless containers
    ├── docker-compose.yml
    ├── nginx/            # Unprivileged nginx
    ├── seccomp/          # Seccomp profiles
    ├── setup-rootless.sh
    ├── EXAMPLES.md
    └── README.md
```

## Requirements

- Podman 4.0+
- podman-compose (for compose files)
- Systemd (for Quadlet)

### Optional

- WireGuard tools (for multi-node)
- Keepalived (for HA)
- Ceph tools (for storage)

## Security

All examples implement:

- **Non-root users** where possible
- **Minimal capabilities** (cap_drop ALL, add only needed)
- **No new privileges** (no-new-privileges:true)
- **Read-only root filesystems** where applicable
- **Security profiles** (seccomp, AppArmor, SELinux)
- **Network policies** and isolation
- **Secret management**

## License

MIT - See individual example directories for details.
