# Blue-Green Deployment with Podman

Zero-downtime deployment pattern using two identical production environments (blue and green) with instant traffic switching.

## Architecture

```
                    ┌─────────────────┐
                    │   HAProxy       │
                    │  Load Balancer  │
                    │  Port 80/443    │
                    └────────┬────────┘
                             │
            ┌────────────────┴────────────────┐
            │                                 │
     ┌──────▼──────┐                 ┌───────▼──────┐
     │   BLUE      │                 │    GREEN     │
     │ Environment │◄───────────────►│ Environment  │
     │             │                 │              │
     │  ┌───────┐  │                 │  ┌───────┐   │
     │  │  App  │  │                 │  │  App  │   │
     │  │ :8080 │  │                 │  │ :8080 │   │
     │  └───┬───┘  │                 │  └───┬───┘   │
     │      │      │                 │      │       │
     │  ┌───▼───┐  │                 │  ┌───▼───┐   │
     │  │PostgreSQL│                 │  │PostgreSQL│  │
     │  │ :5432 │  │                 │  │ :5432 │   │
     │  └───────┘  │                 │  └───────┘   │
     │      │      │                 │      │       │
     │  ┌───▼───┐  │                 │  ┌───▼───┐   │
     │  │ Redis │  │                 │  │ Redis │   │
     │  │ :6379 │  │                 │  │ :6379 │   │
     │  └───────┘  │                 │  └───────┘   │
     └─────────────┘                 └──────────────┘
```

## How It Works

1. **Blue Environment**: Currently serving production traffic
2. **Green Environment**: Staged with new version, not receiving traffic
3. **HAProxy**: Routes all traffic to the active environment
4. **Switch**: Instant traffic cutover from blue to green (or vice versa)
5. **Rollback**: Immediate revert if issues detected

## Quick Start

### 1. Initial Setup

```bash
cd blue-green

# Setup script creates network and starts blue environment
chmod +x scripts/switch.sh
./scripts/switch.sh setup

# Configure environment
cp .env.example .env
nano .env  # Set your passwords
```

### 2. Deploy New Version

```bash
# Full automated pipeline (deploys to inactive, switches, cleans up old)
./scripts/switch.sh pipeline v2.0.0

# Or manual steps:
# 1. Deploy to inactive environment
./scripts/switch.sh deploy green v2.0.0

# 2. Verify health
./scripts/switch.sh health green

# 3. Switch traffic
./scripts/switch.sh switch green

# 4. (Optional) Clean up old environment after grace period
./scripts/switch.sh cleanup blue
```

### 3. Emergency Rollback

```bash
# Instant rollback to previous environment
./scripts/switch.sh rollback
```

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/switch.sh setup` | Initial setup |
| `./scripts/switch.sh status` | Show current status |
| `./scripts/switch.sh pipeline [tag]` | Full deployment pipeline |
| `./scripts/switch.sh deploy <color> [tag]` | Deploy to specific color |
| `./scripts/switch.sh switch <color>` | Switch traffic |
| `./scripts/switch.sh rollback` | Emergency rollback |
| `./scripts/switch.sh health [color]` | Check health |
| `./scripts/switch.sh cleanup <color>` | Remove environment |

## Health Check Endpoints

Each application exposes:
- `GET /health` - Basic health status
- `GET /health?color=blue` - Blue environment check
- `GET /health?color=green` - Green environment check

Response format:
```json
{
  "status": "healthy",
  "color": "blue",
  "timestamp": "2024-01-15T10:30:00Z",
  "version": "1.0.0"
}
```

## Database Strategy

### Option 1: Separate Databases (Default)
Each environment has its own database. Data migration required during deployment.

**Pros:**
- Complete isolation
- No migration downtime
- Easy rollback

**Cons:**
- Data synchronization needed
- More resource usage

### Option 2: Shared Database
Both environments connect to the same database.

**Pros:**
- Single source of truth
- No data migration
- Lower resource usage

**Cons:**
- Database migrations affect both
- More complex rollback

## Configuration Files

- `docker-compose-blue.yml` - Blue environment services
- `docker-compose-green.yml` - Green environment services
- `docker-compose-proxy.yml` - HAProxy and monitoring
- `haproxy/haproxy.cfg` - Load balancer configuration
- `scripts/switch.sh` - Deployment automation
- `.env` - Environment variables

## Monitoring

### HAProxy Stats
Visit: `http://localhost:8404/stats`

Shows:
- Active backend status
- Request rates
- Connection counts
- Health check status

### Health Aggregation
Check overall status:
```bash
curl http://localhost/health
```

### Container Status
```bash
./scripts/switch.sh status
```

## Production Considerations

### SSL/TLS
1. Place certificates in `haproxy/certs/`
2. Update `haproxy/haproxy.cfg` with certificate paths
3. HAProxy automatically handles SSL termination

### Database Migrations
With separate databases:
```bash
# 1. Backup current database
pg_dump -h localhost -U appuser appdb > backup.sql

# 2. Deploy and run migrations on green
./scripts/switch.sh deploy green v2.0.0
podman exec -it postgres-green psql -U appuser -d appdb -f /migrations/v2.0.0.sql

# 3. Verify and switch
./scripts/switch.sh health green
./scripts/switch.sh switch green
```

### Session Handling
Option 1: Sticky Sessions (configured in HAProxy)
Option 2: Shared Session Store (Redis)
Option 3: Stateless JWT tokens

### Grace Period
After switching, old environment stays running for 60 seconds (configurable) before cleanup to handle in-flight requests.

## Security

- **Network Isolation**: Each environment on separate internal network
- **No Root**: Containers run with minimal privileges
- **Secrets**: Database passwords via environment variables
- **Headers**: Security headers added by HAProxy

## Troubleshooting

### Switch Failed
```bash
# Check environment health
./scripts/switch.sh health green

# View logs
podman-compose -f docker-compose-green.yml logs

# Manual switch investigation
./scripts/switch.sh status
```

### Health Check Failing
```bash
# Check individual containers
podman healthcheck run app-green
podman healthcheck run postgres-green

# View detailed logs
podman logs app-green
```

### HAProxy Issues
```bash
# Check HAProxy configuration
podman exec blue-green-proxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg

# View HAProxy logs
podman logs blue-green-proxy
```

## Testing

```bash
# Simulate traffic while switching
while true; do curl -s http://localhost/health | jq .color; sleep 1; done

# Test specific environment
curl -H "X-Deployment-Color: green" http://localhost/

# Test with cookie
curl -b "DEPLOYMENT_COLOR=green" http://localhost/
```

## Cleanup

```bash
# Stop everything
podman-compose -f docker-compose-blue.yml down
podman-compose -f docker-compose-green.yml down
podman-compose -f docker-compose-proxy.yml down

# Remove volumes (DATA LOSS!)
podman-compose -f docker-compose-blue.yml down -v
podman-compose -f docker-compose-green.yml down -v

# Remove network
podman network rm blue-green-shared
```
