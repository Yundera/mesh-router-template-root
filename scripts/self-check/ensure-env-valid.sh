#!/bin/bash
# Validate the stack .env and backfill missing optional keys with defaults.
#
# Fails (non-zero) only when the stack cannot run: .env missing, or the
# required PROVIDER / DOMAIN keys are empty. Optional keys are repaired
# in place. User-set values are never overwritten.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found - re-run install.sh"
    exit 1
fi

if [ -z "${PROVIDER:-}" ]; then
    echo "ERROR: PROVIDER is not set in $ENV_FILE"
    exit 1
fi
if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN is not set in $ENV_FILE"
    exit 1
fi

FIXED=0

ensure_default() {
    local key="$1" default="$2"
    if [ -z "$(get_env_value "$key")" ]; then
        set_env_value "$key" "$default"
        echo "Added missing $key=$default"
        FIXED=1
    fi
}

ensure_default "DATA_ROOT" "/DATA"
ensure_default "DEFAULT_SERVICE_HOST" "casaos"
ensure_default "DEFAULT_SERVICE_PORT" "8080"
ensure_default "PUID" "1000"
ensure_default "PGID" "1000"
ensure_default "EMAIL" "admin@${DOMAIN}"
ensure_default "MESH_AUTO_UPDATE" "true"

# Platform secret consumed by app-store apps. Generate once, never rotate —
# regenerating would invalidate every app's DB password and admin token.
if [ -z "$(get_env_value DEFAULT_PASSWORD)" ]; then
    GENERATED=$(LC_ALL=C head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)
    set_env_value "DEFAULT_PASSWORD" "$GENERATED"
    echo "Generated missing DEFAULT_PASSWORD"
    FIXED=1
fi

# Keep PUBLIC_IP_DASH consistent with PUBLIC_IP (used for sslip.io/nip.io routes)
CURRENT_IP=$(get_env_value PUBLIC_IP)
if [ -n "$CURRENT_IP" ]; then
    EXPECTED_DASH=$(echo "$CURRENT_IP" | tr '.:' '-')
    if [ "$(get_env_value PUBLIC_IP_DASH)" != "$EXPECTED_DASH" ]; then
        set_env_value "PUBLIC_IP_DASH" "$EXPECTED_DASH"
        echo "Fixed PUBLIC_IP_DASH=$EXPECTED_DASH"
        FIXED=1
    fi
fi

chmod 600 "$ENV_FILE"

if [ "$FIXED" -eq 0 ]; then
    echo ".env is valid"
fi
