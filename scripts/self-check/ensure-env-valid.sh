#!/bin/bash
# Validate the stack .env and backfill missing optional keys with defaults.
#
# Fails (non-zero) only when the stack cannot run: .env missing, or the
# required PROVIDER_STR / DOMAIN keys are empty. Optional keys are repaired
# in place. User-set values are never overwritten.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found - re-run install.sh"
    exit 1
fi

FIXED=0

# Key renames (see scripts/migrations/2026-08-02-01-rename-env-keys.sh). The
# migration is the normal path; this is the self-healing one, for a box whose
# marker exists but whose .env was later restored from a backup, or where the
# sync is pinned off (MESH_AUTO_UPDATE=false) so migrations never run. Values
# are moved, never regenerated — DEFAULT_PWD is the platform secret every
# installed app derived its credentials from.
heal_renamed_key() {
    local old="$1" new="$2" old_val
    [ -n "$(get_env_value "$new")" ] && return 0
    old_val="$(get_env_value "$old")"
    [ -z "$old_val" ] && return 0

    set_env_value "$new" "$old_val"
    bash "$ENV_MGR" delete "$old" "$ENV_FILE"
    # Make it visible to the rest of THIS run: common.sh sourced .env before the
    # rename, so the new name is not in the environment yet.
    printf -v "$new" '%s' "$old_val"
    echo "Migrated $old -> $new"
    FIXED=1
}

heal_renamed_key PROVIDER             PROVIDER_STR
heal_renamed_key DEFAULT_PASSWORD     DEFAULT_PWD
heal_renamed_key MESH_SELF_CHECK_CRON SELF_CHECK_CRON

if [ -z "${PROVIDER_STR:-}" ]; then
    echo "ERROR: PROVIDER_STR is not set in $ENV_FILE"
    exit 1
fi
if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN is not set in $ENV_FILE"
    exit 1
fi

ensure_default() {
    local key="$1" default="$2"
    if [ -z "$(get_env_value "$key")" ]; then
        set_env_value "$key" "$default"
        echo "Added missing $key=$default"
        FIXED=1
    fi
}

ensure_default "DATA_ROOT" "/DATA"
ensure_default "DEFAULT_SERVICE_HOST" "maison"
ensure_default "DEFAULT_SERVICE_PORT" "80"
ensure_default "PUID" "1000"
ensure_default "PGID" "1000"
ensure_default "EMAIL" "admin@${DOMAIN}"
ensure_default "MESH_AUTO_UPDATE" "true"

# Dead value, not a preference: CasaOS is not in this template's compose file, so
# `casaos` can never resolve on the `pcs` network again. A box still carrying it 502s
# on ${DOMAIN}, on both bare-IP hostnames and on the catch-all — all three come from
# this key via the Caddyfile — with nothing else to indicate why. An operator who
# pointed the root domain at some other service keeps their choice.
#
# scripts/migrations/2026-08-02-03-authelia-maison.sh is the normal path; this is the
# self-healing one, for the same reasons as heal_renamed_key above, plus a box with
# MESH_AUTO_UPDATE=false, where no migration ever runs at all.
if [ "$(get_env_value DEFAULT_SERVICE_HOST)" = "casaos" ]; then
    set_env_value "DEFAULT_SERVICE_HOST" "maison"
    set_env_value "DEFAULT_SERVICE_PORT" "80"
    echo "Repointed root domain: casaos:8080 -> maison:80"
    FIXED=1
fi

# Deprecated update-source key (see scripts/migrations/2026-08-02-02-rename-update-url.sh).
# Left in place it silently pins the box to whatever branch it names, because
# mesh_template_url() falls through to it when UPDATE_URL is absent — which is how a
# box installed with --channel main ends up updating from stable.
if [ -n "$(get_env_value MESH_UPDATE_CHANNEL)" ]; then
    if [ -z "$(get_env_value UPDATE_URL)" ]; then
        set_env_value "UPDATE_URL" "$(mesh_channel_url "$(get_env_value MESH_UPDATE_CHANNEL)")"
        echo "Expanded MESH_UPDATE_CHANNEL into UPDATE_URL"
    fi
    bash "$ENV_MGR" delete MESH_UPDATE_CHANNEL "$ENV_FILE"
    echo "Dropped deprecated MESH_UPDATE_CHANNEL"
    FIXED=1
fi

# Platform secret consumed by app-store apps. Generate once, never rotate —
# regenerating would invalidate every app's DB password and admin token.
if [ -z "$(get_env_value DEFAULT_PWD)" ]; then
    GENERATED=$(LC_ALL=C head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)
    set_env_value "DEFAULT_PWD" "$GENERATED"
    echo "Generated missing DEFAULT_PWD"
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
