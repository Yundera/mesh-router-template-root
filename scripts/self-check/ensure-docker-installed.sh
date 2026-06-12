#!/bin/bash
# Ensure Docker + Compose plugin are installed (same path as install.sh).

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping."
    exit 0
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker is installed: $(docker --version)"
    exit 0
fi

echo "Docker not found, installing..."
curl -fsSL https://get.docker.com | sh
echo "Docker installed: $(docker --version)"
