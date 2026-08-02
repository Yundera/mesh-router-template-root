#!/bin/bash
# Shared setup for mesh-router self-check scripts. Source this first.
#
# Layout (see README.md "Self-check & auto-update"):
#   /DATA/AppData/casaos/apps/mesh/   — CasaOS-visible surface: docker-compose.yml + .env only
#   ${DATA_ROOT}/AppData/mesh/        — everything else: template/, scripts/, log/, data/

APP_DIR="/DATA/AppData/casaos/apps/mesh"
ENV_FILE="$APP_DIR/.env"

# Load the stack .env (PROVIDER_STR, DOMAIN, DATA_ROOT, MESH_AUTO_UPDATE, ...).
#
# Parsed, NOT sourced. The .env is the one user-owned file in this layout, and
# `source` executes it: a value with a space in it — `SELF_CHECK_CRON=0 3 * * *`
# is the obvious one, and it is exactly what the old writer produced — parses as
# an assignment followed by a command, fails, and takes down every script that
# sources this file, since they all run under `set -e`. That turned a hand-edit
# into a box that silently stops self-checking (and, once migrations run here,
# stops updating).
#
# Same rules docker compose applies to a .env, so the two agree on what a value
# is: split on the first `=`, ignore blanks/comments and non-identifier keys,
# strip at most one layer of surrounding quotes. No expansion, no execution.
load_env_file() {
    local file="$1" line key value
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"          # tolerate a .env saved with CRLF
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [ "${#value}" -ge 2 ]; then
            case "$value" in
                \"*\") value="${value:1:${#value}-2}" ;;
                \'*\') value="${value:1:${#value}-2}" ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done < "$file"
}

load_env_file "$ENV_FILE"

# TRANSITION SHIM — remove together with the ${OLD} fallbacks in docker-compose.yml.
#
# In-memory only: no file is written, so ensure-env-valid.sh's heal_renamed_key and
# the rename migration (both of which read the FILE) still see the real state and
# still do the rename.
#
# Needed for exactly one cycle. A box updating from a pre-rename template installs
# the new scripts and runs them in the SAME pass, while .env still holds the old
# names — the migration cannot have run yet. Without this, every script reading
# PROVIDER_STR fails in that window; ensure-route-registered.sh logged a bare
# "ERROR: PROVIDER_STR not set" on a box whose provider was perfectly fine, which
# is exactly the kind of message that sends someone debugging the wrong thing
# during a fleet rollout.
: "${PROVIDER_STR:=${PROVIDER:-}}"
: "${DEFAULT_PWD:=${DEFAULT_PASSWORD:-}}"
: "${SELF_CHECK_CRON:=${MESH_SELF_CHECK_CRON:-}}"
export PROVIDER_STR DEFAULT_PWD SELF_CHECK_CRON

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

# .env accessors. Both delegate to tools/env-file-manager.sh, which writes
# atomically AND restores the file's pre-existing mode and owner afterwards.
# That last part is load-bearing: the .env is owned by PUID:PGID (the dashboard
# uid) so the dashboard can read it and group the stack, rather than showing the
# mesh containers as individual "External Apps". The hand-rolled mktemp+mv this
# replaced re-chowned the file to whoever ran the script — root, under cron.
ENV_MGR="$_COMMON_DIR/../tools/env-file-manager.sh"

# Read KEY from the stack .env (raw value, empty if absent).
get_env_value() {
    bash "$ENV_MGR" get "$1" "$ENV_FILE"
}

# Set KEY=VALUE in the stack .env.
set_env_value() {
    # A first-ever write has no file to inherit metadata from, so seed it here.
    if [ ! -f "$ENV_FILE" ]; then
        install -m 600 -o "${PUID:-1000}" -g "${PGID:-1000}" /dev/null "$ENV_FILE" 2>/dev/null \
            || { touch "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
    fi
    bash "$ENV_MGR" set "$1" "$2" "$ENV_FILE"
}

# Resolve the template tarball URL from the configured update channel.
#
# Precedence (highest first):
#   1. MESH_TEMPLATE_URL — explicit full URL override (forks, tags, custom builds).
#   2. MESH_UPDATE_CHANNEL — a branch/channel name (stable | main | <other>).
#   3. default: stable.
#
# Both vars come from the stack .env (sourced above), so a channel chosen at
# install time is honoured by the nightly self-check without any extra wiring.
# install.sh carries an inline copy of this logic because it bootstraps before
# this library is on disk — keep the two in sync.
mesh_template_url() {
    if [ -n "${MESH_TEMPLATE_URL:-}" ]; then
        printf '%s\n' "$MESH_TEMPLATE_URL"
        return 0
    fi
    local channel="${MESH_UPDATE_CHANNEL:-stable}"
    [ -n "$channel" ] || channel="stable"
    printf 'https://github.com/yundera/mesh-router-template-root/archive/refs/heads/%s.tar.gz\n' "$channel"
}
