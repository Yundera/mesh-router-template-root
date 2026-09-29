#!/bin/bash
# Bring the mesh stack up. Recreates containers when the compose file, the
# pulled images, or interpolated .env values changed earlier in this run.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
    echo "ERROR: $APP_DIR/docker-compose.yml not found"
    exit 1
fi

# The compose file bind-mounts $MESH_ROOT/Caddyfile as a SINGLE FILE into
# mesh-router-caddy. Docker materialises a missing bind source as a directory,
# which Caddy cannot read — so the stack must never be brought up without it.
#
# ensure-template-sync.sh is the normal owner of this file, but it is not
# guaranteed to have run: it exits at the top when MESH_AUTO_UPDATE=false (every
# --local install), and a failed download leaves it unpropagated while
# self-check.sh carries on to this script regardless. Restoring from the local
# template/ copy covers both without going to the network, and honours a pinned
# box: template/ is whatever that box chose to pin.
if [ ! -f "$MESH_ROOT/Caddyfile" ] || [ -d "$MESH_ROOT/Caddyfile" ]; then
    if [ -d "$MESH_ROOT/Caddyfile" ]; then
        echo "Removing stray Caddyfile directory (bind mount with no source file)"
        rm -rf "$MESH_ROOT/Caddyfile"
    fi
    if [ ! -f "$TEMPLATE_DIR/Caddyfile" ]; then
        echo "ERROR: $MESH_ROOT/Caddyfile is missing and $TEMPLATE_DIR/Caddyfile has no copy to restore from"
        exit 1
    fi
    echo "Restoring $MESH_ROOT/Caddyfile from $TEMPLATE_DIR"
    cp "$TEMPLATE_DIR/Caddyfile" "$MESH_ROOT/Caddyfile"
fi

# Exactly the same hazard, one service over: the compose file bind-mounts
# dex-frontend/templates/{login,header}.html as SINGLE FILES, so a `up -d` before
# they exist makes Docker create them as directories and `dex` can never start
# again ("not a directory"). The tool is idempotent and cheap; running it here as
# well as in ensure-dex.sh means no path reaches `up` without those files.
if [ -x "$SCRIPTS_DIR/tools/provision-dex-frontend.sh" ]; then
    "$SCRIPTS_DIR/tools/provision-dex-frontend.sh" \
        || echo "WARN: Dex frontend provisioning reported an error; continuing"
fi

FAILED=0

# Mesh Console (mesh-console / mesh-console-app): the gate signs an identity
# assertion with this key and the app verifies it. Unset, the app refuses every
# request (fails closed). Minted here, right before `up`, rather than in an
# earlier step: this script runs from the freshly synced tree, so even the cycle
# that first brings the console in starts it with the key. Nothing to back up —
# deleting it re-mints it and the `up` below recreates both with the new value.
if [ -z "$(get_env_value MESH_CONSOLE_ASSERTION_SECRET)" ]; then
    set_env_value MESH_CONSOLE_ASSERTION_SECRET "$(openssl rand -hex 32)"
    echo "Generated MESH_CONSOLE_ASSERTION_SECRET"
fi

# Never start Authelia on an image older than its database (see
# authelia_enforce_db_floor in library/common.sh). Here, right before `up` and
# after every step that can replace the compose file, so the pin it checks is the
# pin that gets started.
authelia_enforce_db_floor "$APP_DIR/docker-compose.yml" "$MESH_ROOT/auth" || FAILED=1

cd "$APP_DIR"

# A container from another project holding one of our names makes `up` abort for
# the whole stack (see evict_name_squatters in library/common.sh).
evict_name_squatters || FAILED=1

# If `up` still fails, start whatever it did create before reporting: compose
# aborts mid-way leaving containers in `Created`, and install.sh has already taken
# the stack down, so a hard exit here leaves the box with no routing at all. A
# partial stack (caddy + tunnel up, one service missing) is far better than none.
if docker compose up -d --remove-orphans; then
    echo "Containers started"
else
    echo "ERROR: 'docker compose up' failed - starting the containers it did create so the box is not left dark"
    docker compose start || true
    FAILED=1
fi

# `up -d` exiting 0 only means the containers were created. Waiting for them to
# stay up is what turns a crash-looping service into a failed step — and so into
# install.sh's "finished with self-check failures" instead of "Installation complete".
if wait_stack_settled 90 15; then
    echo "Stack is up"
else
    FAILED=1
fi

exit "$FAILED"
