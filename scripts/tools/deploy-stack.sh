#!/bin/bash
# deploy-stack.sh <stack-name> <dest-dir> [EXTRA_KEY=value ...]
#
# Deploys one of the auxiliary compose stacks shipped under stacks/<stack-name>/
# to its own project directory:
#
#   1. copy stacks/<stack-name>/docker-compose.yml -> <dest-dir>/docker-compose.yml
#   2. generate <dest-dir>/.env from the mesh .env, plus any extra KEY=value
#      pairs given on the command line
#   3. docker compose pull, then up -d --remove-orphans (both with backoff)
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
up_once()   { compose up --quiet-pull --remove-orphans -d; }

run_with_backoff "pull" pull_once
run_with_backoff "up" up_once

echo "[$STACK_NAME] stack is up ($DEST_DIR)"
