#!/bin/bash
# Bring the mesh stack up. Recreates containers when the compose file, the
# pulled images, or interpolated .env values changed earlier in this run.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
    echo "ERROR: $APP_DIR/docker-compose.yml not found"
    exit 1
fi

# The compose file bind-mounts $MESH_ROOT/Caddyfile as a SINGLE FILE into
# mesh-router-caddy. Docker materialises a missing bind source as a directory,
# which Caddy cannot read — so the stack must never be brought up without it.
#
# ensure-template-sync.sh is the normal owner of this file, but it is not
# guaranteed to have run: it exits at the top when MESH_AUTO_UPDATE=false (every
# --local install), and a failed download leaves it unpropagated while
# self-check.sh carries on to this script regardless. Restoring from the local
# template/ copy covers both without going to the network, and honours a pinned
# box: template/ is whatever that box chose to pin.
if [ ! -f "$MESH_ROOT/Caddyfile" ] || [ -d "$MESH_ROOT/Caddyfile" ]; then
    if [ -d "$MESH_ROOT/Caddyfile" ]; then
        echo "Removing stray Caddyfile directory (bind mount with no source file)"
        rm -rf "$MESH_ROOT/Caddyfile"
    fi
    if [ ! -f "$TEMPLATE_DIR/Caddyfile" ]; then
        echo "ERROR: $MESH_ROOT/Caddyfile is missing and $TEMPLATE_DIR/Caddyfile has no copy to restore from"
        exit 1
    fi
    echo "Restoring $MESH_ROOT/Caddyfile from $TEMPLATE_DIR"
    cp "$TEMPLATE_DIR/Caddyfile" "$MESH_ROOT/Caddyfile"
fi

cd "$APP_DIR"
docker compose up -d --remove-orphans
echo "Stack is up"
