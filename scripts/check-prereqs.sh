#!/bin/bash
# check-prereqs.sh - Verify Podman prerequisites are installed

set -euo pipefail

echo "Checking Podman prerequisites..."

# Check podman is installed
if ! command -v podman &> /dev/null; then
    echo "ERROR: podman is not installed"
    exit 1
fi

# Check podman-compose is installed
if ! command -v podman-compose &> /dev/null; then
    echo "WARNING: podman-compose is not installed"
fi

# Check podman version
echo "Podman version: $(podman --version)"

# Check available storage
echo "Checking storage..."
df -h / | tail -1

# Check network connectivity
echo "Checking network connectivity..."
ping -c 1 8.8.8.8 &>/dev/null || echo "WARNING: No internet connectivity"

echo "Prerequisites check complete!"
exit 0