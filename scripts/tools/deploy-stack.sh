#!/bin/bash
# deploy-stack.sh <stack-name> <dest-dir> [EXTRA_KEY=value ...]
#
# Deploys one of the auxiliary compose stacks shipped under stacks/<stack-name>/
# to its own project directory:
#
#   1. copy stacks/<stack-name>/docker-compose.yml -> <dest-dir>/docker-compose.yml
#   1b. copy stacks/<stack-name>/icon.<ext> -> <dest-dir>/.icon.<ext>, the file
#      Maison renders the stack's tile from
#   2. generate <dest-dir>/.env from the mesh .env, plus any extra KEY=value
#      pairs given on the command line
#   3. docker compose pull, then up -d --remove-orphans (both with backoff).
#      Between the two: evict containers squatting this stack's names, then run
#      stacks/<stack-name>/pre-up.sh <dest-dir> <dest-compose> if the stack ships
#      one — the place for work that has to see the deployed compose file and the
#      evicted state, and must happen before `up` (the auth stack uses it).
#
# DEPLOY_UP_ARGS (environment, optional): extra arguments for that `up`, split on
# whitespace. The auth stack passes `--scale dex=0` through it when Dex has no
# connector (see dex_wanted in library/common.sh).
#
# THE STACK IS NOT READ FROM $SCRIPTS_DIR. ensure-template-sync.sh propagates only
# docker-compose.yml, the Caddyfile and scripts/ to live locations — stacks/ is not
# among them, and does not need to be: template/ is a pristine copy of the whole
# repo refreshed on every sync. See the resolution note at SRC_COMPOSE below for
# why own-tree-first matters when a migration invokes this.
#
# Copying the .env wholesale rather than cherry-picking keys means a variable
# added to the mesh .env is automatically available to these stacks with no
# change here.
#
# Retries mirror ensure-stack-{pulled,up}.sh: registry resets are common enough
# that one transient failure must not fail the self-check.
#
# Ported from Yundera/template-root (scripts/tools/deploy-stack.sh); see
# doc/alignment-with-template-root.md.
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

STACK_NAME="${1:?usage: deploy-stack.sh <stack-name> <dest-dir> [KEY=value ...]}"
DEST_DIR="${2:?usage: deploy-stack.sh <stack-name> <dest-dir> [KEY=value ...]}"
shift 2

# Own tree first, then the synced template/ — same reasoning as
# ensure-authelia.sh: a migration runs this from the extracted tree BEFORE that
# tree has been swapped into template/.
SELF_TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_COMPOSE="$SELF_TREE/stacks/$STACK_NAME/docker-compose.yml"
[ -f "$SRC_COMPOSE" ] || SRC_COMPOSE="$TEMPLATE_DIR/stacks/$STACK_NAME/docker-compose.yml"
DEST_COMPOSE="$DEST_DIR/docker-compose.yml"
DEST_ENV="$DEST_DIR/.env"

MAX_ATTEMPTS=5
INITIAL_BACKOFF=15
MAX_BACKOFF=120

if [ ! -f "$SRC_COMPOSE" ]; then
    log_error "Stack template not found: $SRC_COMPOSE"
    exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
    log_error "Mesh .env not found: $ENV_FILE"
    exit 1
fi

mkdir -p "$DEST_DIR"

# --- 1. compose file -------------------------------------------------------
# Only write when the content differs, so an unchanged template does not churn
# the file's mtime on every self-check.
if ! cmp -s "$SRC_COMPOSE" "$DEST_COMPOSE"; then
    cp "$SRC_COMPOSE" "$DEST_COMPOSE"
    echo "Updated $DEST_COMPOSE from template"
fi

# --- 1b. tile icon ---------------------------------------------------------
# The stack's directory sits directly under ${DATA_ROOT}/AppData, so Maison tiles it
# as a MANAGED app — and a managed app's tile is rendered from `.icon.<ext>` in its
# own folder (internal/apps/icon.go: localIcon()), falling back to the compose's
# `icon:` URL only when that file is absent. Nothing else writes the file for these
# stacks: Maison copies an icon at store install/update, which they go through
# neither, and a store compose's relative `icon: icon.png` fetches nothing here
# (appicon.fetch() ignores non-http(s) URLs) — the terminal tile rendered as a "T".
#
# Extensions follow Maison's appicon.Path() order; the icon is looked up beside the
# compose that was picked above, so own-tree-first holds for it too. A stack that
# ships none is a no-op. The rm clears a copy under a DIFFERENT extension: two
# .icon.* files would make Path()'s answer depend on its ordering, not the template.
SRC_ICON=""
DEST_ICON=""
for ext in png svg jpg jpeg webp gif ico avif; do
    if [ -f "$(dirname "$SRC_COMPOSE")/icon.$ext" ]; then
        SRC_ICON="$(dirname "$SRC_COMPOSE")/icon.$ext"
        DEST_ICON="$DEST_DIR/.icon.$ext"
        break
    fi
done
if [ -n "$SRC_ICON" ] && ! cmp -s "$SRC_ICON" "$DEST_ICON"; then
    rm -f "$DEST_DIR"/.icon.*
    cp "$SRC_ICON" "$DEST_ICON"
    chown "${PUID:-1000}:${PGID:-1000}" "$DEST_ICON" 2>/dev/null || true
    echo "Updated $DEST_ICON from template"
fi

# --- 2. .env ---------------------------------------------------------------
TMP_ENV="$(mktemp)"
chmod 600 "$TMP_ENV"
{
    echo "# AUTO-GENERATED FILE - DO NOT EDIT"
    echo "# Written by scripts/tools/deploy-stack.sh for the '$STACK_NAME' stack."
    echo "# Regenerated on every self-check; edit $ENV_FILE instead."
    echo ""
    cat "$ENV_FILE"
    if [ "$#" -gt 0 ]; then
        echo ""
        echo "# ============================================"
        echo "# Stack-specific values (resolved at deploy time)"
        echo "# ============================================"
        for kv in "$@"; do
            echo "$kv"
        done
    fi
} > "$TMP_ENV"

if ! cmp -s "$TMP_ENV" "$DEST_ENV"; then
    mv "$TMP_ENV" "$DEST_ENV"
    chmod 600 "$DEST_ENV"
    echo "Regenerated $DEST_ENV"
else
    rm -f "$TMP_ENV"
fi

# Unconditional, not inside the branch above: the file may already have the right
# content but the wrong owner, from a template version that predates this. It
# carries DEFAULT_PWD and PROVIDER_STR, so it stays 0600 — but owned by the
# dashboard uid, which has to read it.
chown "${PUID:-1000}:${PGID:-1000}" "$DEST_ENV" 2>/dev/null || true

# --- 3. pull + up ----------------------------------------------------------
compose() {
    docker compose --project-directory "$DEST_DIR" -f "$DEST_COMPOSE" "$@"
}

run_with_backoff() {
    local what="$1"; shift
    local backoff="$INITIAL_BACKOFF"
    local attempt=1
    while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            log_warn "[$STACK_NAME] $what attempt $attempt/$MAX_ATTEMPTS failed, retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$((backoff * 2))
            [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
        fi
        attempt=$((attempt + 1))
    done
    log_error "[$STACK_NAME] $what failed after $MAX_ATTEMPTS attempts"
    return 1
}

# Serialise layer streams — a single reset shouldn't poison N concurrent pulls.
pull_once() { COMPOSE_PARALLEL_LIMIT=1 compose pull; }
# shellcheck disable=SC2206 # word splitting is the point
UP_EXTRA=(${DEPLOY_UP_ARGS:-})
up_once()   { compose up --quiet-pull --remove-orphans -d "${UP_EXTRA[@]}"; }

run_with_backoff "pull" pull_once
# Every stack joins `pcs` as external (see ensure_pcs_network in library/common.sh).
ensure_pcs_network
# Retrying cannot clear a name held by another project's container; evicting it
# can (see evict_name_squatters in library/common.sh). After the pull, not before:
# an evicted service is down until the `up` below, so keep that window short.
evict_name_squatters --project-directory "$DEST_DIR" -f "$DEST_COMPOSE" \
    || log_warn "[$STACK_NAME] could not remove a container squatting one of this stack's names"
# Looked up beside the compose that was picked above, so own-tree-first holds for
# it too. A failing hook fails the deploy but NOT the `up`: the eviction above has
# already stopped whatever this stack replaces, so skipping `up` would leave those
# services down rather than degraded.
PRE_UP="$(dirname "$SRC_COMPOSE")/pre-up.sh"
HOOK_FAILED=0
if [ -f "$PRE_UP" ] && ! bash "$PRE_UP" "$DEST_DIR" "$DEST_COMPOSE"; then
    log_error "[$STACK_NAME] pre-up hook failed ($PRE_UP); bringing the stack up anyway"
    HOOK_FAILED=1
fi
run_with_backoff "up" up_once

echo "[$STACK_NAME] stack is up ($DEST_DIR)"
exit "$HOOK_FAILED"
