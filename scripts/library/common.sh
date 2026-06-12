#!/bin/bash
# Shared setup for mesh-router self-check scripts. Source this first.
#
# Layout (see README.md "Self-check & auto-update"):
#   /DATA/AppData/casaos/apps/mesh/   — CasaOS-visible surface: docker-compose.yml + .env only
#   ${DATA_ROOT}/AppData/mesh/        — everything else: template/, scripts/, log/, data/

APP_DIR="/DATA/AppData/casaos/apps/mesh"
ENV_FILE="$APP_DIR/.env"

# Load the stack .env (PROVIDER, DOMAIN, DATA_ROOT, MESH_AUTO_UPDATE, ...).
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

MESH_ROOT="${DATA_ROOT:-/DATA}/AppData/mesh"
SCRIPTS_DIR="$MESH_ROOT/scripts"
TEMPLATE_DIR="$MESH_ROOT/template"
LOG_FILE="${LOG_FILE:-$MESH_ROOT/log/mesh.log}"

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_COMMON_DIR/log.sh"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Read KEY from the stack .env (raw value, empty if absent).
get_env_value() {
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^${1}=" "$ENV_FILE" | head -n1 | cut -d= -f2-
}

# Set KEY=VALUE in the stack .env (atomic: temp file + mv, preserves 600).
set_env_value() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp "$APP_DIR/.env.XXXXXX")
    if [ -f "$ENV_FILE" ]; then
        grep -v -E "^${key}=" "$ENV_FILE" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
}
