# Single-Node Podman Deployment

Complete production-ready single-node container stack using Podman with PostgreSQL, Redis, Nginx reverse proxy, and application containers.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Host System                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                 Nginx Reverse Proxy                  │   │
│  │              (Ports 80, 443 exposed)                 │   │
│  └──────────────────────┬──────────────────────────────┘   │
│                         │                                   │
│  ┌──────────────────────▼──────────────────────────────┐   │
│  │              Internal Backend Network                │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │   │
│  │  │   App       │  │  PostgreSQL │  │    Redis    │ │   │
│  │  │  Container  │  │  Database   │  │    Cache    │ │   │
│  │  │  (Port 8080)│  │ (Port 5432) │  │ (Port 6379) │ │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘ │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Prerequisites

```bash
# Install Podman and podman-compose
# Fedora/RHEL/CentOS
sudo dnf install podman podman-compose

# Ubuntu/Debian
sudo apt-get install podman podman-compose

# macOS
brew install podman podman-compose
```

### 2. Initial Setup

```bash
# Clone or navigate to the single-node directory
cd /path/to/single-node

# Run setup (creates directories and copies environment template)
make setup

# Edit environment configuration
nano .env

# IMPORTANT: Change the default passwords!
```

### 3. Start the Stack

```bash
# Start all services
make start

# Or using podman-compose directly
podman-compose up -d
```

### 4. Verify Deployment

```bash
# Check container status
make ps

# Check health
make health

# View logs
make logs
```

## Configuration

### Environment Variables

Copy `.env.example` to `.env` and configure:

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_USER` | Database username | appuser |
| `POSTGRES_PASSWORD` | Database password (required) | - |
| `POSTGRES_DB` | Database name | appdb |
| `REDIS_PASSWORD` | Redis password (required) | - |
| `APP_ENV` | Application environment | production |

### Networking

- **Frontend Network**: `172.20.1.0/24` - External access via Nginx
- **Backend Network**: `172.20.2.0/24` - Internal only, no external access

### Volumes

| Volume | Purpose | Backup |
|--------|---------|--------|
| `postgres_data` | Database files | Yes |
| `redis_data` | Cache persistence | Optional |
| `nginx_certs` | SSL certificates | Yes |
| `app_data` | Application files | Yes |

## Management Commands

### Daily Operations

```bash
# View logs
make logs
make logs-app
make logs-db

# Restart services
make restart

# Check health
make health

# View statistics
make stats
```

### Database Operations

```bash
# Open PostgreSQL shell
make db-shell

# Create backup
make db-backup

# Restore backup
make db-restore FILE=backups/postgres-20240101-120000.sql.gz

# Redis CLI
make redis-cli
```

### Maintenance

```bash
# Update images and restart
make update

# Full backup
make backup

# Clean up (preserves volumes)
make clean

# Clean everything including data
make clean-volumes
```

## Quadlet Deployment (Systemd)

For production deployments using systemd:

### 1. Install Quadlet Files

```bash
make setup-quadlet
```

### 2. Start Services

```bash
# Start all services
systemctl --user start nginx-proxy
systemctl --user start app-server
systemctl --user start postgres-db
systemctl --user start redis-cache

# Enable auto-start
systemctl --user enable nginx-proxy
systemctl --user enable app-server
systemctl --user enable postgres-db
systemctl --user enable redis-cache
```

### 3. Check Status

```bash
systemctl --user status nginx-proxy
journalctl --user -u nginx-proxy -f
```

## Security Features

- **No New Privileges**: All containers run with `no-new-privileges`
- **Capability Dropping**: Minimal capabilities granted
- **Read-Only Root**: Where applicable (nginx configs mounted read-only)
- **Network Isolation**: Backend network is internal-only
- **Secrets Management**: Passwords via environment or Podman secrets
- **Health Checks**: All services have configured health checks
- **Resource Limits**: CPU and memory limits defined

## Backup Strategy

### Automated Backups

The backup service runs daily at 2 AM:

```bash
# Configure in .env
BACKUP_S3_BUCKET=my-backups
BACKUP_AWS_ACCESS_KEY=xxx
BACKUP_AWS_SECRET_KEY=xxx
```

### Manual Backups

```bash
# Database backup
make db-backup

# Full backup (volumes + database)
make backup
```

### Restore

```bash
# Restore database
make db-restore FILE=backups/postgres-20240101-120000.sql.gz
```

## Monitoring

### Health Endpoints

- Nginx: `http://localhost/health`
- Application: `http://localhost/health` (proxied)

### Container Health

```bash
# Check all containers
make health

# View logs
make logs

# Statistics
make stats
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs
make logs

# Verify environment
make ps

# Check for port conflicts
sudo ss -tlnp | grep -E ':80|:443'
```

### Database Connection Issues

```bash
# Verify database is healthy
podman healthcheck run postgres-db

# Check logs
make logs-db

# Test connection
make db-shell
```

### Network Issues

```bash
# Inspect networks
podman network ls
podman network inspect single-node-stack_backend

# Test connectivity
podman exec nginx-proxy ping -c 1 app-server
```

## SSL/TLS Configuration

### Using Let's Encrypt

1. Install certbot:
```bash
sudo dnf install certbot
```

2. Obtain certificates:
```bash
sudo certbot certonly --standalone -d example.com -d www.example.com
```

3. Copy to volume:
```bash
sudo cp /etc/letsencrypt/live/example.com/*.pem /var/lib/containers/storage/volumes/single-node-stack_nginx_certs/_data/
sudo chown $(id -u):$(id -g) /var/lib/containers/storage/volumes/single-node-stack_nginx_certs/_data/*
```

4. Uncomment SSL section in `nginx/conf.d/default.conf`

5. Restart:
```bash
make restart
```

## Production Checklist

- [ ] Change all default passwords in `.env`
- [ ] Configure SSL certificates
- [ ] Set up automated backups
- [ ] Configure monitoring/alerting
- [ ] Review resource limits
- [ ] Test failover procedures
- [ ] Document custom configurations
- [ ] Set up log rotation
- [ ] Configure firewall rules
- [ ] Enable SELinux if applicable

## Directory Structure

```
single-node/
├── docker-compose.yml      # Main compose file
├── .env.example            # Environment template
├── .env                    # Your configuration (not in git)
├── Makefile                # Management commands
├── README.md               # This file
├── nginx/
│   ├── nginx.conf          # Main nginx config
│   └── conf.d/
│       └── default.conf    # Virtual host config
├── redis/
│   └── redis.conf          # Redis configuration
├── init-scripts/
│   └── 01-init.sql         # Database initialization
├── quadlets/               # Systemd Quadlet files
│   ├── nginx-proxy.container
│   ├── app-server.container
│   ├── postgres-db.container
│   ├── redis-cache.container
│   ├── frontend.network
│   ├── backend.network
│   └── volumes.volume
└── backups/                # Backup storage
```

## License

MIT - See LICENSE file for details.
