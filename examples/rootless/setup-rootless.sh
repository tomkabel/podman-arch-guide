#!/bin/bash
# Rootless Podman Setup Script
# Configures user namespaces and storage for rootless containers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME=$(whoami)
USER_ID=$(id -u)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        error "This script should NOT be run as root"
        exit 1
    fi

    # Check for user namespace support
    if [[ ! -f /proc/sys/user/max_user_namespaces ]]; then
        error "Kernel does not support user namespaces"
        exit 1
    fi

    local max_ns
    max_ns=$(cat /proc/sys/user/max_user_namespaces)
    if [[ "$max_ns" -eq 0 ]]; then
        error "User namespaces are disabled (max_user_namespaces = 0)"
        exit 1
    fi

    log "User namespaces enabled (max: $max_ns)"

    # Check for newuidmap/newgidmap
    if ! command -v newuidmap &> /dev/null; then
        error "newuidmap not found. Install uidmap package:"
        error "  sudo dnf install uidmap"
        error "  sudo apt-get install uidmap"
        exit 1
    fi

    success "Prerequisites check passed"
}

# Configure subUID/GID ranges
configure_subids() {
    log "Configuring subUID/GID ranges..."

    # Check current mappings
    local current_subuid
    current_subuid=$(grep "^${USER_NAME}:" /etc/subuid 2>/dev/null || echo "")
    local current_subgid
    current_subgid=$(grep "^${USER_NAME}:" /etc/subgid 2>/dev/null || echo "")

    if [[ -n "$current_subuid" && -n "$current_subgid" ]]; then
        log "SubUID/GID mappings already exist:"
        log "  UID: $current_subuid"
        log "  GID: $current_subgid"
        return 0
    fi

    warning "SubUID/GID mappings not found for $USER_NAME"
    log "To configure, run the following as root:"
    log "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER_NAME"
    log ""
    log "Or manually edit /etc/subuid and /etc/subgid:"
    log "  echo '$USER_NAME:100000:65536' | sudo tee -a /etc/subuid"
    log "  echo '$USER_NAME:100000:65536' | sudo tee -a /etc/subgid"

    read -p "Attempt to configure automatically? (requires sudo) [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER_NAME" 2>/dev/null; then
            success "SubUID/GID ranges configured"
        else
            error "Failed to configure subUID/GID ranges"
            return 1
        fi
    else
        warning "Please configure subUID/GID ranges manually and re-run"
        return 1
    fi
}

# Setup storage directories
setup_storage() {
    log "Setting up storage directories..."

    # Create directories
    mkdir -p ~/.local/share/containers/storage
    mkdir -p ~/.config/containers
    mkdir -p ~/.local/share/containers/cache
    mkdir -p /run/user/$USER_ID/containers

    # Set storage configuration
    cat > ~/.config/containers/storage.conf << EOF
[storage]
driver = "overlay"
runroot = "/run/user/$USER_ID/containers"
graphroot = "$HOME/.local/share/containers/storage"
rootless_storage_path = "$HOME/.local/share/containers/storage"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
size = ""
remap-uids = "0:100000:65536"
remap-gids = "0:100000:65536"

[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF

    success "Storage configuration created"
}

# Setup registries
setup_registries() {
    log "Setting up registries..."

    mkdir -p ~/.config/containers

    cat > ~/.config/containers/registries.conf << EOF
[registries.search]
registries = ['docker.io', 'quay.io', 'registry.fedoraproject.org']

[registries.insecure]
registries = []

[registries.block]
registries = []
EOF

    success "Registries configuration created"
}

# Setup policy.json
setup_policy() {
    log "Setting up image policy..."

    mkdir -p ~/.config/containers

    cat > ~/.config/containers/policy.json << 'EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {
        "docker": {
            "registry.access.redhat.com": [
                {
                    "type": "insecureAcceptAnything"
                }
            ],
            "registry.redhat.io": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        },
        "docker-daemon": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        }
    }
}
EOF

    success "Policy configuration created"
}

# Create systemd user directory
setup_systemd() {
    log "Setting up systemd user directory..."

    mkdir -p ~/.config/systemd/user

    # Enable lingering if not already
    if [[ ! -f /var/lib/systemd/linger/$USER_NAME ]]; then
        log "Enabling linger mode (containers survive logout)..."
        log "Run: sudo loginctl enable-linger $USER_NAME"
    fi

    success "Systemd user directory created"
}

# Test rootless podman
test_rootless() {
    log "Testing rootless podman..."

    # Test basic run
    if podman run --rm hello-world 2>/dev/null; then
        success "Rootless podman is working!"
    else
        error "Rootless podman test failed"
        return 1
    fi

    # Test user namespace mapping
    log "Testing user namespace mapping..."
    local container_uid
    container_uid=$(podman run --rm alpine id -u)

    if [[ "$container_uid" == "0" ]]; then
        success "User namespace mapping works (root in container)"
    else
        warning "Unexpected UID in container: $container_uid"
    fi

    # Test with specific mapping
    log "Testing custom UID mapping..."
    local mapped_uid
    mapped_uid=$(podman run --rm --uidmap 0:100000:1000 alpine id -u)

    if [[ "$mapped_uid" == "0" ]]; then
        success "Custom UID mapping works"
    else
        warning "Custom mapping test returned: $mapped_uid"
    fi
}

# Create helper scripts
create_helpers() {
    log "Creating helper scripts..."

    mkdir -p ~/.local/bin

    # Create podman-compose helper
    cat > ~/.local/bin/rootless-compose << 'EOF'
#!/bin/bash
# Rootless Podman Compose Helper

export PODMAN_USERNS=keep-id
export XDG_RUNTIME_DIR=/run/user/$(id -u)

exec podman-compose "$@"
EOF

    chmod +x ~/.local/bin/rootless-compose

    # Create cleanup script
    cat > ~/.local/bin/rootless-cleanup << 'EOF'
#!/bin/bash
# Cleanup rootless podman resources

echo "Cleaning up rootless podman..."
podman system prune -a -f
echo "Cleanup complete"
EOF

    chmod +x ~/.local/bin/rootless-cleanup

    success "Helper scripts created in ~/.local/bin/"
}

# Main setup
main() {
    cat << 'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║          Rootless Podman Setup                                ║
║          User Namespace Configuration                         ║
╚═══════════════════════════════════════════════════════════════╝
BANNER

    log "Setting up rootless podman for user: $USER_NAME (UID: $USER_ID)"

    check_prerequisites
    configure_subids
    setup_storage
    setup_registries
    setup_policy
    setup_systemd
    create_helpers
    test_rootless

    cat << 'SUMMARY'

╔═══════════════════════════════════════════════════════════════╗
║          Setup Complete!                                      ║
╚═══════════════════════════════════════════════════════════════╝

Rootless Podman is now configured. You can:

  1. Run containers without sudo:
     podman run -d -p 8080:80 nginx:alpine

  2. Use podman-compose:
     podman-compose up -d

  3. Manage containers with systemd:
     systemctl --user status container-myapp

  4. Clean up when needed:
     podman system prune

Important Notes:
  - Containers run as mapped UIDs (100000+)
  - Can only bind to ports >= 1024 without root
  - Storage is in ~/.local/share/containers/
  - Use 'rootless-compose' for easier compose operations

To enable containers to survive logout:
  sudo loginctl enable-linger $USER

SUMMARY
}

# Run main
main "$@"
