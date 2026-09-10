#!/bin/bash
# Shared setup for mesh-router self-check scripts. Source this first.
#
# Layout (see README.md "Self-check & auto-update"):
#   /DATA/AppData/mesh/   — everything: docker-compose.yml, .env, template/, scripts/,
#                           log/, data/, dex/, auth/, migration-markers/
#
# The compose file and .env used to live in a separate /DATA/AppData/casaos/apps/mesh —
# a CasaOS-visible surface. CasaOS is gone, and Maison's managed-app scan looks for
# ${DATA_ROOT}/AppData/<name>/docker-compose.yml, so collapsing the two directories is
# what makes this stack a managed tile instead of an "UNMANAGED" one.

APP_DIR="/DATA/AppData/mesh"

# TRANSITION SHIM — remove with the other shims, once the fleet has migrated.
#
# Resolve the pre-move location when the new one has no .env yet. Without this the
# ordering between migrations becomes load-bearing: migrations source THIS file, so on
# a box that runs the whole backlog in one cycle, the earlier migrations would resolve
# ENV_FILE to a path the move migration has not created yet, find no .env, and mark
# themselves applied having done nothing. With the fallback, every script works either
# side of the move and the migrations can run in any order.
if [ ! -f "$APP_DIR/.env" ] && [ -f "/DATA/AppData/casaos/apps/mesh/.env" ]; then
    APP_DIR="/DATA/AppData/casaos/apps/mesh"
fi
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

# Default branch when nothing is configured.
MESH_DEFAULT_CHANNEL="stable"
mesh_channel_url() {
    printf 'https://github.com/yundera/mesh-router-template-root/archive/refs/heads/%s.tar.gz\n' "$1"
}

# Resolve the template tarball URL.
#
# UPDATE_URL is the canonical key and holds a FULL URL — the same name and shape
# Yundera/template-root uses, and the same one settings-center-app's
# /api/admin/update-channel reads and writes via env-file-manager. Aligning on it
# is what lets that panel drive this template unmodified (alignment doc, phase 4).
#
# Precedence (highest first):
#   1. UPDATE_URL          — canonical, full URL.
#   2. MESH_TEMPLATE_URL   — DEPRECATED alias, same meaning. Migrated by
#                            scripts/migrations/2026-08-02-02-rename-update-url.sh.
#   3. MESH_UPDATE_CHANNEL — DEPRECATED branch name; expanded to a branch URL.
#   4. default: the stable branch.
#
# The two deprecated keys are read for one release so a box that has not yet run
# the migration keeps updating from the source it was installed with. Drop them
# together with the other transition shims.
#
# install.sh carries an inline copy of this resolution because it bootstraps
# before this library exists on disk — keep the two in sync.
mesh_template_url() {
    if [ -n "${UPDATE_URL:-}" ]; then
        printf '%s\n' "$UPDATE_URL"
        return 0
    fi
    if [ -n "${MESH_TEMPLATE_URL:-}" ]; then
        printf '%s\n' "$MESH_TEMPLATE_URL"
        return 0
    fi
    local channel="${MESH_UPDATE_CHANNEL:-$MESH_DEFAULT_CHANNEL}"
    [ -n "$channel" ] || channel="$MESH_DEFAULT_CHANNEL"
    mesh_channel_url "$channel"
}

# Never start Authelia on an image older than its database.
#
# Authelia migrates db.sqlite FORWARD on every start, and an older binary cannot
# open what a newer one wrote. It does not say so: v4.39.21 added V0025
# StorageAAD (encrypted rows gain associated data), and v4.39.20 pointed at that
# database exits with
#     the configured encryption key does not appear to be valid for this database
# about a key that is perfectly fine. Dex crash-loops behind it (its only
# connector answers 503) and every interactive login on the box is gone.
#
# Not hypothetical. The compose file tracked the floating `4.39` tag, so nightly
# pulls took boxes to 4.39.21/.22; pinning 4.39.20 on 2026-09-07 downgraded every
# one of them the following night. The error text points at rotating the storage
# key, which would have thrown the database away for nothing.
#
# `storage migrate history` records the Authelia version that applied each
# migration. Its last row is a binary known to open this exact database, so a pin
# older than that is raised to it — never to anything newer, never lowered.
#
# Read-only and secret-free: the history query does not check the encryption key,
# so the probe mounts the auth dir :ro, with no network and a throwaway key. Fails
# open (changes nothing) whenever it cannot tell: no database yet, a pin that is
# not an exact X.Y.Z (a floating tag or a digest), or a probe that errors.
# Returns non-zero only when it found a downgrade and could not rewrite the pin.
#
# Usage: authelia_enforce_db_floor <compose-file> <auth-dir>
authelia_enforce_db_floor() {
    local compose="$1" auth_dir="$2"
    local pinned pinned_ver probe_dir out db_ver

    [ -f "$auth_dir/db.sqlite" ] && [ -f "$compose" ] || return 0
    command -v docker >/dev/null 2>&1 || return 0

    pinned="$(grep -oE '^[[:space:]]*image:[[:space:]]*authelia/authelia:[^[:space:]"#]+' "$compose" \
        | head -n1 | sed -E 's/^[[:space:]]*image:[[:space:]]*//' || true)"
    pinned_ver="${pinned##*:}"
    [[ "$pinned_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0

    probe_dir="$(mktemp -d)"
    printf 'storage:\n  encryption_key: %s\n  local:\n    path: /auth/db.sqlite\n' \
        'migration-history-probe-not-a-real-key' > "$probe_dir/probe.yml"
    chmod 644 "$probe_dir/probe.yml"
    if ! out="$(docker run --rm --network none \
            -v "$auth_dir:/auth:ro" -v "$probe_dir/probe.yml:/probe.yml:ro" \
            "$pinned" authelia storage migrate history --config /probe.yml 2>&1)"; then
        rm -rf "$probe_dir"
        log_warn "Authelia pin check skipped: could not read the migration history with $pinned"
        return 0
    fi
    rm -rf "$probe_dir"

    db_ver="$(printf '%s\n' "$out" \
        | awk '$NF ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ { v = $NF } END { sub(/^v/, "", v); print v }')"
    [ -n "$db_ver" ] || return 0
    # Equal or newer pin: sort -V puts the database version first.
    [ "$(printf '%s\n' "$pinned_ver" "$db_ver" | sort -V | head -n1)" = "$db_ver" ] && return 0

    sed -i -E "s#^([[:space:]]*image:[[:space:]]*authelia/authelia:)${pinned_ver//./\\.}([[:space:]]|\$)#\1${db_ver}\2#" "$compose"
    if ! grep -qE "^[[:space:]]*image:[[:space:]]*authelia/authelia:${db_ver//./\\.}([[:space:]]|\$)" "$compose"; then
        log_error "Authelia $pinned_ver cannot open $auth_dir/db.sqlite (last migrated by v$db_ver) and the pin in $compose could not be raised: Authelia will not start"
        return 1
    fi
    log_warn "Authelia $pinned_ver cannot open $auth_dir/db.sqlite (last migrated by v$db_ver). Raised the pin in $compose to $db_ver; the template pin needs to be at least that."
}

# Wait until every container of the compose project in the current directory is
# running and has stayed up for <stable> seconds.
#
# `docker compose up -d` exits 0 once the containers are CREATED. A service that
# dies on start under `restart: unless-stopped` just loops, and nothing else looks:
# on 2026-09-10 an update printed "Self-check complete: 18/18 OK" and
# "Installation complete" while authelia and dex were both crash-looping and the
# box had no working login.
#
# A crash loop never reaches <stable> — it is back in `restarting` within a second
# of each start — while a one-off restart during boot (Dex starting before
# Authelia answers) recovers well inside <timeout>. Every service in this stack is
# long-running; a one-shot service added later would need excluding here.
#
# On failure prints each unsettled container with its last error lines, returns 1.
#
# Usage: wait_stack_settled [timeout-seconds] [stable-seconds]
wait_stack_settled() {
    local timeout="${1:-90}" stable="${2:-15}"
    local ids id deadline now line name status started uptime entry
    local -a unsettled=()

    ids="$(docker compose ps -a -q)"
    [ -n "$ids" ] || return 0
    deadline=$(( $(date +%s) + timeout ))

    while :; do
        now="$(date +%s)"
        unsettled=()
        for id in $ids; do
            line="$(docker inspect -f '{{.Name}} {{.State.Status}} {{.State.StartedAt}}' "$id" 2>/dev/null || true)"
            read -r name status started <<<"$line"
            name="${name#/}"
            if [ "${status:-}" != "running" ]; then
                unsettled+=("${name:-$id}:${status:-gone}")
                continue
            fi
            # An unparseable timestamp counts as settled rather than failing a healthy stack.
            uptime=$(( now - $(date -d "$started" +%s 2>/dev/null || echo 0) ))
            [ "$uptime" -ge "$stable" ] || unsettled+=("$name:up ${uptime}s")
        done
        [ "${#unsettled[@]}" -eq 0 ] && return 0
        [ "$now" -lt "$deadline" ] || break
        sleep 3
    done

    echo "ERROR: containers not running stably ${timeout}s after 'up' (each needs ${stable}s of uptime): ${unsettled[*]}"
    for entry in "${unsettled[@]}"; do
        name="${entry%%:*}"
        echo "  --- $name, last errors:"
        docker logs --tail 40 "$name" 2>&1 \
            | grep -iE 'error|fatal|panic|failed' | tail -n 3 | cut -c1-300 | sed 's/^/  /' || true
    done
    return 1
}
