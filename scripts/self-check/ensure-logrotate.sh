#!/bin/bash
# Configure logrotate for the mesh self-check log.

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping logrotate setup."
    exit 0
fi

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

LOGROTATE_CONFIG="/etc/logrotate.d/mesh-router"

if ! command -v logrotate >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing logrotate..."
        apt-get update -qq && apt-get install -y -qq logrotate
    else
        echo "WARN: logrotate not available and apt-get not found - skipping"
        exit 0
    fi
fi

cat > "$LOGROTATE_CONFIG" <<EOF
$MESH_ROOT/log/mesh.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    dateext
    dateformat -%Y-%m-%d
    copytruncate
}
EOF

echo "Logrotate configured for $MESH_ROOT/log/mesh.log (daily, 7 days retention)"
