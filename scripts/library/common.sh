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

# The auth stack's own folder, and the state inside it. Each stack keeps its
# state in the folder named after it: mesh under $MESH_ROOT/data, auth here.
# Until 2026-10-01 Authelia's and Dex's state sat in the mesh root (auth/, dex/,
# dex-frontend/), a leftover from when they were mesh services; adopt_auth_state
# below moves it. Same layout as Yundera/template-root.
AUTH_STACK_DIR="${DATA_ROOT:-/DATA}/AppData/auth"
AUTHELIA_HOME="$AUTH_STACK_DIR/authelia"   # users_database.yml, db.sqlite, configuration.yml, secrets/, oidc/
DEX_HOME="$AUTH_STACK_DIR/dex"             # dex.db, config.yaml, connectors.d/, frontend/

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

# Remove any container that holds a `container_name` this compose project claims
# but belongs to a DIFFERENT project (or to none).
#
# Container names are host-wide, and `up --remove-orphans` only sweeps orphans of
# its own project, so a squatter from another project makes `up` abort on
# "Conflict. The container name ... is already in use" — and compose aborts the
# WHOLE up, not just that service. On 2026-09-29 watch.nsl.sh went fully dark this
# way: mesh-console moved from its own `mesh-console` stack into the mesh stack
# (21721e8), the old stack still held the names, and install.sh had already taken
# the mesh stack down for its clean restart.
#
# The template is authoritative for the names it declares, so the squatter goes.
# Only the container is removed — its volumes and bind mounts are left alone, and
# its compose project (if any) can be brought back by hand. Loud on purpose: every
# eviction is a template/fleet drift worth knowing about.
#
# Reads the project name and names from `docker compose config` (normalised YAML:
# `name:` at the top, `container_name:` per service), so it needs no yq.
#
# Usage: evict_name_squatters [docker compose global args...]
#   e.g. evict_name_squatters                                  (compose in $PWD)
#        evict_name_squatters --project-directory DIR -f FILE
evict_name_squatters() {
    local config project name owner rc=0
    config="$(docker compose "$@" config 2>/dev/null)" || return 0
    project="$(sed -n 's/^name: *//p' <<<"$config" | head -n 1)"
    [ -n "$project" ] || return 0

    while read -r name; do
        [ -n "$name" ] || continue
        # `container inspect`, not `inspect`: never match an image or volume by name.
        owner="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null)" || continue
        [ "$owner" = "$project" ] && continue
        echo "WARN: container '$name' is declared by the '$project' stack but belongs to '${owner:-no compose project}' - removing it so '$project' can start"
        docker rm -f "$name" >/dev/null || rc=1
    done < <(sed -n 's/^ *container_name: *//p' <<<"$config" | tr -d "\"'")

    return "$rc"
}

# Create the shared `pcs` network if it does not exist yet.
#
# Every stack joins `pcs` as `external: true` — mesh, auth, maison, terminal — so no
# project owns it. It used to belong to the mesh stack, which made the order stacks
# came up in load-bearing (nothing else could start until mesh had created it) and
# meant a `docker compose down` of mesh tried to delete a network every other stack
# was still attached to. A box that has one already keeps it: the compose labels it
# carries from the mesh project are harmless to an external user.
#
# CREATED WITH THOSE SAME LABELS, and that is for rollback. A pre-split template
# declares `pcs` as the mesh project's own network, and compose refuses outright to
# use a same-named network without a matching com.docker.compose.network label
# ("has incorrect label ... set to """): rolled back, a box whose `pcs` came from
# a plain `docker network create` would get no mesh stack at all. With the labels
# it is indistinguishable from the network the old template created (verified,
# compose v5.3). Keep in step with install.sh / install.ps1 (--windows paths).
#
# Usage: ensure_pcs_network
ensure_pcs_network() {
    docker network inspect pcs >/dev/null 2>&1 && return 0
    docker network create \
        --label com.docker.compose.network=pcs \
        --label com.docker.compose.project=mesh \
        pcs >/dev/null && echo "Created network 'pcs'"
}

# Remove a network another compose project created, so <project> can recreate it
# as its own.
#
# Compose attaches to a same-named network owned by another project with only a
# warning ("was not created for project ..."), and that project's `down` never
# removes it — so after a service moves between stacks, its private network would
# keep the old owner label, and the warning, forever. Only an EMPTY network is
# removed: run it after evict_name_squatters, which is what detaches the moved
# containers. A network still in use is left alone and retried next cycle.
#
# Usage: adopt_network <network-name> <project>
adopt_network() {
    local net="$1" project="$2" owner attached
    owner="$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$net" 2>/dev/null)" || return 0
    [ "$owner" = "$project" ] && return 0
    attached="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null || true)"
    if [ -n "${attached// /}" ]; then
        echo "WARN: network '$net' belongs to '${owner:-no compose project}', not '$project', and is still in use by: ${attached% } - leaving it for a later cycle"
        return 0
    fi
    docker network rm "$net" >/dev/null && echo "Removed network '$net' (owned by '${owner:-no compose project}') so '$project' recreates it"
}

# Print the services of <project>'s containers that another stack now declares.
#
# A service that moves between stacks is an orphan of its old project from the
# moment the old compose file stops listing it — and `up --remove-orphans` on that
# project would delete it before the new stack has taken it over. On the cycle a
# template moves dex/authelia/auth-registrar from mesh to auth, ensure-stack-up.sh
# runs first, so that is the difference between a login that stays up and one that
# is gone until ensure-auth-stack.sh; if the auth deploy then fails, it is the
# difference between a login that stays up and none at all. The caller keeps the
# orphans (skips --remove-orphans) while this prints anything; the new stack's own
# evict_name_squatters is what retires them.
#
# Usage: services_handed_over <project> <compose-file>...
services_handed_over() {
    local project="$1" file svc declared="" running
    shift
    for file in "$@"; do
        [ -f "$file" ] || continue
        # No interpolation needed to list services; a missing .env only warns.
        declared+="$(docker compose -f "$file" config --services 2>/dev/null || true)"$'\n'
    done
    [ -n "${declared//$'\n'/}" ] || return 0
    running="$(docker ps -a --filter "label=com.docker.compose.project=$project" \
        --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null || true)"
    for svc in $running; do
        grep -qx -- "$svc" <<<"$declared" && echo "$svc"
    done
    return 0
}

# True when <dir> holds at least one file or symlink, at any depth. A tree of
# empty directories — what a `mkdir -p` or Docker's handling of a missing bind
# source leaves behind — counts as nothing.
_state_has_files() {
    [ -n "$(find "$1" -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null)" ]
}

# Move Authelia's and Dex's state from the mesh root into the auth stack's folder:
#
#   $MESH_ROOT/auth  ->  $AUTHELIA_HOME   (${DATA_ROOT}/AppData/auth/authelia)
#   $MESH_ROOT/dex   ->  $DEX_HOME        (${DATA_ROOT}/AppData/auth/dex)
#
# The rendered login theme ($MESH_ROOT/dex-frontend) is not moved: it is rebuilt
# from the template on every run, now at $DEX_HOME/frontend, and
# ensure-auth-stack.sh sweeps the old copy once the stack runs from the new one.
#
# THE MOVE IS A RENAME, AND THAT IS WHAT MAKES IT SAFE ON A LIVE BOX. Both sides
# are on one filesystem, so `mv` changes a name and nothing else: a container
# still bound to the old path keeps the same directory, because a bind mount
# holds the inode, not the path. Nothing is stopped. The auth stack deploy that
# follows recreates the containers on the new path — the same directory again.
#
# What an old-bound container must NOT do in between is start again: Docker
# recreates a missing bind source as an empty directory, so the service would
# come up on nothing. Hence restart_if_bound below, for the config-reload
# restarts that sit between the move and the deploy.
#
# BOTH OR NEITHER: every pair is checked before anything is touched.
#
#   old missing                   nothing to do (fresh box, or moved earlier)
#   new missing or holds nothing  rename
#   old holds nothing             an empty leftover — removed
#   both hold files               refuse (return 1): which one is the box's state
#                                 is not something to guess at
#
# CALLED FROM TWO PLACES, deliberately. scripts/migrations/
# 2026-10-01-10-move-auth-state-into-auth-folder.sh is the normal path: it runs
# before the new tree is swapped in, so a failure aborts the sync and the box
# keeps a tree that still agrees with where the state is. But migrations only run
# inside ensure-template-sync.sh, which exits at the top on MESH_AUTO_UPDATE=false
# (every --local install, every pinned box) — so the scripts that read or write
# this state call it too, and treat a failure as fatal: rendering into, or
# bringing the stack up on, an empty folder would silently drop the box back to
# an unclaimed login. One stat per pair when there is nothing to do.
#
# ROLLING BACK to a template that predates this makes the old compose file bind
# the old paths, which Docker then creates EMPTY. Move the two directories back
# first (doc/alignment-with-template-root.md, "Auth state move").
#
# Usage: adopt_auth_state
adopt_auth_state() {
    local pairs=("$MESH_ROOT/auth|$AUTHELIA_HOME" "$MESH_ROOT/dex|$DEX_HOME")
    local pair old new parent

    for pair in "${pairs[@]}"; do
        old="${pair%%|*}"; new="${pair##*|}"
        [ -d "$old" ] && [ ! -L "$old" ] || continue
        _state_has_files "$old" || continue
        if [ -e "$new" ] && _state_has_files "$new"; then
            echo "ERROR: both $old and $new hold files - refusing to choose between them."
            echo "       $new is the current location; if it holds the box's real accounts, move $old aside and re-run."
            return 1
        fi
        # A rename only. Across filesystems `mv` degrades to copy-and-delete, which
        # would strand the running containers on a directory that no longer exists.
        parent="$(dirname "$new")"
        while [ ! -d "$parent" ]; do parent="$(dirname "$parent")"; done
        if [ "$(stat -c %d "$old")" != "$(stat -c %d "$parent")" ]; then
            echo "ERROR: $old and $new are on different filesystems - not moving live state by copy"
            return 1
        fi
    done

    for pair in "${pairs[@]}"; do
        old="${pair%%|*}"; new="${pair##*|}"
        [ -d "$old" ] && [ ! -L "$old" ] || continue
        if ! _state_has_files "$old"; then
            find "$old" -depth -type d -empty -delete 2>/dev/null || true
            continue
        fi
        # Only ever a tree of empty directories here — the check above refused
        # anything else.
        if [ -e "$new" ]; then
            find "$new" -depth -type d -empty -delete 2>/dev/null || true
        fi
        mkdir -p "$(dirname "$new")"
        mv "$old" "$new" || return 1
        echo "Moved $old to $new"
    done
    return 0
}

# `docker restart <container>`, but only when it already binds <host-dir>.
# Returns 1 when it did not restart: no such container (cold boot), or one bound
# somewhere else.
#
# For the config-reload restarts in ensure-authelia.sh / ensure-dex.sh. After
# adopt_auth_state renames a state directory, the running container keeps working
# on it — a bind mount holds the inode — until the stack deploy recreates it on
# the new path. STARTING it again in between is what breaks: Docker re-resolves
# the bind by path, finds nothing, and creates an empty directory there, so the
# service comes up on no state and leaves a stray directory behind. Such a
# container is skipped; the deploy that follows picks up whatever the restart
# was for.
#
# Paths are compared with repeated and trailing slashes squeezed out, which is
# how Docker reports a bind source — so a DATA_ROOT written as `/DATA/` still
# matches.
#
# Usage: restart_if_bound <container> <host-dir>
restart_if_bound() {
    local name="$1" dir sources
    dir="$(printf '%s' "$2" | sed -E 's#/+#/#g; s#(.)/$#\1#')"
    sources="$(docker container inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$name" 2>/dev/null)" || return 1
    if ! grep -qxF "$dir" <<<"$sources"; then
        echo "$name does not bind $dir - not restarting it; the stack deploy recreates it"
        return 1
    fi
    docker restart "$name" >/dev/null 2>&1 || true
}

# --- Dex presence ------------------------------------------------------------
# Dex refuses to start with an empty `connectors:` list ("failed to initialize
# server: server: no connectors specified") — and that is a normal state, not a
# misconfiguration: an unclaimed box with no drop-in in connectors.d/ has none.
# A Dex left to crash-loop there failed the auth stack's settle check, and with it
# every fresh install whose owner account starts unclaimed (2026-10-02).
#
# So with no connector the `dex` container does not exist at all: the auth stack is
# brought up with `--scale dex=0`, which removes it. Absent rather than stopped,
# because a stopped container is still started again by every `up` and every
# `docker restart`, and is reported as broken by wait_stack_settled and by
# mesh-console. Its state is on the bind mount, so removing it loses nothing. With
# Dex gone its Caddy labels go too: auth-${DOMAIN} falls to the catch-all (Maison's
# AppShield gate), and every gate shows its "sign-in unavailable" page.
#
# ensure-dex.sh decides, from the config it just rendered, and records the
# decision here; ensure-auth-stack.sh reads it back for its `up`.
DEX_CONNECTOR_COUNT_FILE="$DEX_HOME/connector-count"

# Prints 1 when the dex container should exist, 0 when it should not.
# Fails OPEN: no record (ensure-dex.sh has not run on this tree yet) or an
# unreadable one means 1 — today's behaviour, never a Dex removed on a guess.
dex_wanted() {
    local count
    count="$(cat "$DEX_CONNECTOR_COUNT_FILE" 2>/dev/null || true)"
    case "$count" in
        ''|*[!0-9]*) echo 1 ;;
        0) echo 0 ;;
        *) echo 1 ;;
    esac
}
