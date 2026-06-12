#!/bin/bash
# Pull the image versions pinned by the (possibly just-synced) compose file.
# Separate from ensure-stack-up.sh so the log distinguishes registry-side
# failures from container-side failures.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
    echo "ERROR: $APP_DIR/docker-compose.yml not found"
    exit 1
fi

cd "$APP_DIR"
docker compose pull -q
echo "Images pulled"
