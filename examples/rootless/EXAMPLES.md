# Rootless Container Examples
# Common patterns and configurations for rootless Podman

## 1. Running a Simple Web Server

```bash
# Run nginx on unprivileged port
podman run -d \
  --name web \
  -p 8080:8080 \
  -v ~/www:/usr/share/nginx/html:ro,Z \
  nginxinc/nginx-unprivileged:alpine

# Access at http://localhost:8080
```

## 2. Database with Persistent Storage

```bash
# Create volume directory
mkdir -p ~/podman-data/postgres

# Run PostgreSQL
podman run -d \
  --name db \
  -e POSTGRES_PASSWORD=mysecretpassword \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_DB=mydb \
  -v ~/podman-data/postgres:/var/lib/postgresql/data:Z \
  -p 5432:5432 \
  docker.io/library/postgres:16-alpine

# Connect
psql -h localhost -U myuser -d mydb
```

## 3. Multi-Container App with Pod

```bash
# Create a pod
podman pod create --name myapp -p 8080:80

# Add database
podman run -d \
  --pod myapp \
  --name myapp-db \
  -e MYSQL_ROOT_PASSWORD=secret \
  -e MYSQL_DATABASE=app \
  -v ~/podman-data/mysql:/var/lib/mysql:Z \
  docker.io/library/mysql:8

# Add application
podman run -d \
  --pod myapp \
  --name myapp-web \
  -e DB_HOST=localhost \
  -e DB_NAME=app \
  myapp-image:latest

# View pod
podman pod ps
podman pod inspect myapp
```

## 4. Development Environment

```bash
# Node.js development container
podman run -it --rm \
  --name node-dev \
  -v $(pwd):/app:Z \
  -w /app \
  -p 3000:3000 \
  -e NODE_ENV=development \
  node:18-alpine \
  sh -c "npm install && npm run dev"
```

## 5. Build and Run Custom Image

```bash
# Dockerfile
FROM alpine:latest
RUN adduser -D -u 1000 appuser
USER appuser
WORKDIR /home/appuser
COPY --chown=appuser:appuser . .
CMD ["./myapp"]

# Build
podman build -t myapp:latest .

# Run
podman run -d \
  --name myapp \
  -p 8080:8080 \
  -v ~/app-data:/home/appuser/data:Z \
  myapp:latest
```

## 6. Systemd Integration

```bash
# Generate systemd unit
podman generate systemd --new --name myapp > ~/.config/systemd/user/myapp.service

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now myapp

# Check logs
journalctl --user -u myapp -f
```

## 7. Network Configuration

```bash
# Create custom network
podman network create mynet

# Run containers on network
podman run -d --name web --network mynet nginx:alpine
podman run -d --name api --network mynet myapi:latest

# Test connectivity
podman exec api ping web
```

## 8. Secret Management

```bash
# Create secret
echo "mysecretpassword" | podman secret create db_password -

# Use in container
podman run -d \
  --name db \
  --secret db_password,type=env,target=POSTGRES_PASSWORD \
  postgres:16-alpine
```

## 9. Resource Limits

```bash
# Run with resource constraints
podman run -d \
  --name limited-app \
  --memory=512m \
  --memory-swap=512m \
  --cpus=1.0 \
  --pids-limit=100 \
  myapp:latest
```

## 10. Health Checks

```bash
# Run with health check
podman run -d \
  --name healthy-app \
  --health-cmd="wget --quiet --tries=1 --spider http://localhost:8080/health || exit 1" \
  --health-interval=30s \
  --health-timeout=10s \
  --health-retries=3 \
  --health-start-period=40s \
  myapp:latest

# Check health
podman healthcheck run healthy-app
```

## 11. Read-Only Root Filesystem

```bash
# Run with read-only root
podman run -d \
  --name secure-app \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /var/run \
  --tmpfs /app/cache \
  myapp:latest
```

## 12. Using Different UID/GID

```bash
# Run as specific user
podman run -d \
  --name user-app \
  --user 1000:1000 \
  --group-add 1000 \
  --group-add 2000 \
  -v ~/app-data:/data:Z \
  myapp:latest

# Or with UID mapping
podman run -d \
  --name mapped-app \
  --uidmap 0:100000:1000 \
  --gidmap 0:100000:1000 \
  myapp:latest
```

## 13. Port Forwarding to Host

```bash
# Since we can't bind to ports < 1024, use workarounds:

# Option 1: Use higher port
podman run -d -p 8080:80 nginx:alpine

# Option 2: socat forwarding
socat TCP-LISTEN:80,fork TCP:localhost:8080 &

# Option 3: iptables (requires root)
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
```

## 14. Backup and Restore

```bash
# Backup container data
podman run --rm \
  -v myapp_data:/data:ro \
  -v $(pwd)/backup:/backup \
  alpine \
  tar czf /backup/myapp-data-$(date +%Y%m%d).tar.gz -C /data .

# Restore
tar xzf backup/myapp-data-20240101.tar.gz -C ~/podman-data/myapp/
```

## 15. Compose File Example

```yaml
version: "3.8"

services:
  web:
    image: nginxinc/nginx-unprivileged:alpine
    user: "101:101"
    ports:
      - "8080:8080"
    volumes:
      - ./html:/usr/share/nginx/html:ro,Z
      - web-cache:/var/cache/nginx
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3

  api:
    build: ./api
    user: "1000:1000"
    environment:
      - DB_HOST=db
      - DB_NAME=app
    depends_on:
      - db
    cap_drop:
      - ALL

  db:
    image: bitnami/postgresql:16
    user: "1001:1001"
    environment:
      POSTGRESQL_PASSWORD: secret
      POSTGRESQL_DATABASE: app
    volumes:
      - db-data:/bitnami/postgresql
    cap_drop:
      - ALL

volumes:
  web-cache:
  db-data:
```

Run with:
```bash
podman-compose up -d
```

## 16. Cleaning Up

```bash
# Stop all containers
podman stop -a

# Remove all stopped containers
podman container prune

# Remove unused images
podman image prune -a

# Remove unused volumes
podman volume prune

# Complete cleanup (DANGER - removes everything!)
podman system reset
```
