# Rootless Podman Guide
# Running containers without root privileges

## Overview

Rootless Podman allows running containers as an unprivileged user, providing:
- **Enhanced Security**: Container processes run as your user
- **No Root Access Required**: Works on systems without sudo
- **User Namespace Isolation**: Complete UID/GID separation
- **Audit Trail**: Container actions attributed to user

## Architecture

```
Traditional (Rootful)          Rootless
┌─────────────────┐           ┌─────────────────┐
│     root        │           │    user (1000)  │
│  ┌───────────┐  │           │  ┌───────────┐  │
│  │  Podman   │  │           │  │  Podman   │  │
│  │  (root)   │  │           │  │(user 1000)│  │
│  └─────┬─────┘  │           │  └─────┬─────┘  │
│        ▼        │           │        ▼        │
│  ┌───────────┐  │           │  ┌───────────┐  │
│  │ Container │  │           │  │ Container │  │
│  │   root    │  │           │  │user mapped│  │
│  │  (UID 0)  │  │           │  │ UID 100000│  │
│  └───────────┘  │           │  └───────────┘  │
└─────────────────┘           └─────────────────┘
```

## Quick Start

### 1. Verify User Namespace Support

```bash
# Check if user namespaces are enabled
cat /proc/sys/user/max_user_namespaces
# Should be > 0

# Check current user namespace limit
sysctl user.max_user_namespaces

# Enable if needed (requires root)
sudo sysctl user.max_user_namespaces=28633
echo "user.max_user_namespaces = 28633" | sudo tee /etc/sysctl.d/99-userns.conf
```

### 2. Configure SubUID/GID Ranges

```bash
# Check current mappings
cat /etc/subuid
cat /etc/subgid

# Add mappings for your user (run as root)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER

# Verify
newuidmap
newgidmap
```

### 3. Enable Rootless Podman

```bash
# Initialize rootless storage
podman system migrate

# Verify installation
podman info

# Run a test container
podman run --rm hello-world
```

## SubUID/GID Mapping

### Understanding Mappings

```
Container UID   Host UID
     0     →   100000  (root in container = user on host)
     1     →   100001
   1000    →   101000
```

### Configuration Files

**System-wide: `/etc/subuid` and `/etc/subgid`**
```
user:100000:65536
# username:start_uid:count
```

**User-specific: `~/.config/containers/storage.conf`**
```toml
[storage]
driver = "overlay"
runroot = "/run/user/1000/containers"
graphroot = "/home/user/.local/share/containers/storage"

[storage.options]
size = ""
remap-uids = "0:100000:65536"
remap-gids = "0:100000:65536"
```

### Custom Mappings

**Container-specific mapping:**
```bash
podman run --uidmap 0:100000:500 --gidmap 0:100000:500 alpine id
```

**Mapping explanation:**
- `--uidmap 0:100000:500` = Container UID 0 maps to host UID 100000, for 500 IDs
- Container root (0) → Host UID 100000
- Container UID 1 → Host UID 100001
- ... up to Container UID 499 → Host UID 100499

## Running Rootless Containers

### Basic Usage

```bash
# No sudo needed!
podman run -d --name myapp -p 8080:80 nginx:alpine

# Check process ownership
ps aux | grep nginx
# Shows: 100000 (mapped UID) not root!

# Access container as your user
podman exec -it myapp sh
```

### Port Binding (Unprivileged Ports)

```bash
# Can only bind ports >= 1024 as non-root
podman run -d -p 8080:80 nginx:alpine  # ✓ Works
podman run -d -p 80:80 nginx:alpine    # ✗ Fails

# Solution: Use rootful helper or different port
```

### Volume Mounts

```bash
# User-owned directories work fine
podman run -v ~/mydata:/data:Z alpine ls /data

# System directories require proper permissions
# Container runs as mapped UID, needs access
```

## Networking

### Slirp4netns (Default)

```bash
# User-mode networking (no root required)
podman run -d -p 8080:80 nginx:alpine

# Features:
# - Port forwarding
# - Outbound internet access
# - Container-to-container communication
```

### Pasta (Newer, Faster)

```bash
# Enable pasta networking
export PODMAN_USERNS=keep-id
podman run --network pasta -d -p 8080:80 nginx:alpine
```

### Custom Networks

```bash
# Create rootless network
podman network create mynet

# Use in container
podman run -d --network mynet --name app1 alpine
podman run -d --network mynet --name app2 alpine

# Containers can communicate by name
podman exec app2 ping app1
```

### Exposing to LAN

```bash
# Container only accessible to host by default
# To expose to network, use:

# Option 1: SSH tunnel
ssh -L 0.0.0.0:8080:localhost:8080 user@localhost

# Option 2: Rootful port forward (requires root)
sudo sysctl net.ipv4.ip_unprivileged_port_start=80

# Option 3: Use higher ports and reverse proxy
```

## Storage

### Rootless Storage Location

```
~/.local/share/containers/storage/    # Images and layers
/run/user/$(id - u)/containers/       # Runtime state
~/.config/containers/                 # Configuration
```

### Storage Drivers

```bash
# Check current driver
podman info | grep graphDriverName

# Rootless supports:
# - overlay (with fuse-overlayfs)
# - vfs (slower, no kernel support needed)

# Install fuse-overlayfs for better performance
sudo dnf install fuse-overlayfs
```

### Disk Usage

```bash
# Check storage usage
podman system df

# Clean up unused data
podman system prune -a

# Reset all rootless storage
podman system reset
```

## Security Hardening

### Seccomp Profiles

```bash
# Default profile is applied automatically
podman run --security-opt seccomp=default.json nginx:alpine

# Custom profile
cat > nginx-seccomp.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "archMap": [
    {
      "architecture": "SCMP_ARCH_X86_64",
      "subArchitectures": ["SCMP_ARCH_X86", "SCMP_ARCH_X32"]
    }
  ],
  "syscalls": [
    {
      "names": ["accept", "accept4", "bind", "clone", "close"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF

podman run --security-opt seccomp=nginx-seccomp.json nginx:alpine
```

### AppArmor/SELinux

```bash
# SELinux labels work in rootless
podman run -v ~/data:/data:Z alpine touch /data/file

# Check labels
ls -Z ~/data/file
```

### Capabilities

```bash
# Drop all capabilities (default in rootless)
podman run --cap-drop=all nginx:alpine

# Add specific capabilities if needed
podman run --cap-add=net_bind_service nginx:alpine
```

## Systemd Integration

### User-Scoped Services

```bash
# Generate systemd unit
podman generate systemd --new --name myapp > ~/.config/systemd/user/myapp.service

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now myapp

# Check status
systemctl --user status myapp
```

### Lingering Mode

```bash
# Enable services to run after logout
loginctl enable-linger $USER

# Now user services persist after logout
```

### Auto-Start on Boot

```bash
# User services start on user login
# For system boot:

# Enable linger
sudo loginctl enable-linger $USER

# Create service
cat > ~/.config/systemd/user/myapp.service << 'EOF'
[Unit]
Description=My Rootless Container
After=network.target

[Service]
Restart=always
ExecStart=/usr/bin/podman run --name myapp -p 8080:80 myimage
ExecStop=/usr/bin/podman stop -t 10 myapp
ExecStopPost=/usr/bin/podman rm myapp

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable myapp
```

## Troubleshooting

### Permission Denied

```bash
# Check subuid/subgid
cat /etc/subuid
grep $USER /etc/subuid

# Verify newuidmap works
newuidmap

# Check if userns is enabled
cat /proc/sys/user/max_user_namespaces
```

### Cannot Bind to Port < 1024

```bash
# Expected behavior - unprivileged users can't bind low ports
# Solutions:

# 1. Use higher port
podman run -p 8080:80 nginx:alpine

# 2. Use rootful port forwarding
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080

# 3. Use systemd socket activation (advanced)
```

### Storage Issues

```bash
# Reset storage
podman system reset

# Fix permissions
rm -rf ~/.local/share/containers/storage/overlay-layers
podman system migrate
```

### Network Issues

```bash
# Check slirp4netns
which slirp4netns

# Verify network
cat /etc/resolv.conf
ip addr show

# Test connectivity
podman run --rm alpine ping -c 3 8.8.8.8
```

## Best Practices

1. **Always use unprivileged images** when possible
   - nginxinc/nginx-unprivileged instead of nginx
   - bitnami/postgresql instead of postgres

2. **Map to appropriate host UIDs**
   ```bash
   podman run --uidmap 0:100000:1000 myimage
   ```

3. **Use specific user IDs**
   ```bash
   podman run --user 1000:1000 myimage
   ```

4. **Limit capabilities**
   ```bash
   podman run --cap-drop=all --cap-add=chown myimage
   ```

5. **Read-only root filesystem**
   ```bash
   podman run --read-only --tmpfs /tmp --tmpfs /var/run myimage
   ```

6. **Security profiles**
   ```bash
   podman run --security-opt seccomp=profile.json myimage
   ```

## Example: Complete Rootless Stack

```yaml
# docker-compose.yml
version: "3.8"

services:
  web:
    image: nginxinc/nginx-unprivileged:alpine
    user: "101:101"
    ports:
      - "8080:8080"
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp
      - /var/cache/nginx
      - /var/run
    security_opt:
      - no-new-privileges:true

  db:
    image: bitnami/postgresql:16
    user: "1001:1001"
    environment:
      POSTGRESQL_PASSWORD: secret
    volumes:
      - pgdata:/bitnami/postgresql
    cap_drop:
      - ALL

volumes:
  pgdata:
```

Run with:
```bash
podman-compose up -d
```
