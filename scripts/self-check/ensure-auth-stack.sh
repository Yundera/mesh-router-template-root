#!/bin/bash
# Bring the auth stack up: dex, authelia, auth-registrar and auth-console
# (stacks/auth/).
#
# Deployed to ${DATA_ROOT}/AppData/auth through tools/deploy-stack.sh, like maison
# and terminal. It renders nothing: ensure-authelia.sh and ensure-dex.sh have
# written every config these services read. The stack's state is in that same
# folder — authelia/ and dex/ — moved there from the mesh root by adopt_auth_state
# (library/common.sh) on a box that predates the move.
#
# THE CUTOVER. Until the split these three were services of the mesh stack. On the
# first run here, deploy-stack.sh's eviction removes the mesh-project containers
# holding their names and this project recreates them — a login outage of one
# container restart, not of the whole update. ensure-stack-up.sh keeps them alive
# under the mesh project until then (services_handed_over), so a failure here
# leaves the old ones running rather than none.
#
# ORDERING: after ensure-authelia.sh / ensure-dex.sh (their rendered files are
# bind-mounted here) and after ensure-stack-up.sh (Caddy routes these hosts and
# smtp relays Authelia's mail). Before maison and terminal: their gates register
# through auth-registrar.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/authelia-ready.sh"

AUTH_DIR="$AUTH_STACK_DIR"
FAILED=0

# Already done by ensure-authelia.sh in a self-check run. Repeated because
# tools/set-default-app.sh runs this script on its own, and fatal under `set -e`:
# the compose file binds the new paths, so bringing it up while the state is
# still at the old ones would start Authelia and Dex on empty folders. Stopping
# here leaves the running containers serving.
adopt_auth_state

# The compose file bind-mounts dex/frontend/templates/{login,header}.html as
# SINGLE FILES, so an `up` before they exist makes Docker create them as
# directories and `dex` can never start again ("not a directory"). The tool is
# idempotent and cheap; running it here as well as in ensure-dex.sh means no path
# reaches `up` without those files.
if [ -x "$SCRIPTS_DIR/tools/provision-dex-frontend.sh" ]; then
    "$SCRIPTS_DIR/tools/provision-dex-frontend.sh" \
        || echo "WARN: Dex frontend provisioning reported an error; continuing"
fi

# auth-console (the stack's web UI): its gate signs an identity assertion with
# this key and the app verifies it; the app also signs its session-revocation
# requests to the gate with it. Unset, the app refuses every request (fails
# closed). Minted here, right before the deploy copies the mesh .env into the
# stack's own, so even the cycle that first brings the console in starts it with
# the key. Nothing to back up — deleting it re-mints it, and only logs everyone
# out of the console.
if [ -z "$(get_env_value AUTH_CONSOLE_ASSERTION_SECRET)" ]; then
    set_env_value AUTH_CONSOLE_ASSERTION_SECRET "$(openssl rand -hex 32)"
    echo "Generated AUTH_CONSOLE_ASSERTION_SECRET"
fi

dex_id() { docker container inspect -f '{{.Id}}' dex 2>/dev/null || true; }
DEX_BEFORE="$(dex_id)"

"$SCRIPTS_DIR/tools/deploy-stack.sh" auth "$AUTH_DIR" || FAILED=1

# DEX MUST NOT START BEFORE AUTHELIA ANSWERS. Dex opens every connector once, at
# startup, and the Local Account connector's issuer is Authelia: one it could not
# open stays unopened until Dex restarts, i.e. the next nightly self-check (see
# library/authelia-ready.sh). ensure-authelia.sh and ensure-dex.sh already order
# their own restarts; what they cannot cover is this stack recreating BOTH
# containers at once — the cutover, the state move, or any change to the env they
# share. So when Dex is a new container, wait for Authelia and give Dex one more
# start. A no-op `up` leaves the id unchanged and skips all of it.
DEX_AFTER="$(dex_id)"
if [ -n "$DEX_AFTER" ] && [ "$DEX_AFTER" != "$DEX_BEFORE" ]; then
    wait_for_authelia
    docker restart dex >/dev/null 2>&1 || echo "WARN: could not restart dex after the auth stack recreated it"
fi

# Same reason as ensure-stack-up.sh: `up` exiting 0 only means the containers were
# created, and a crash-looping authelia or dex is a box nobody can log in to.
cd "$AUTH_DIR"
if wait_stack_settled 90 15; then
    echo "Auth stack is up"
else
    FAILED=1
fi

# The login theme used to be rendered beside the Dex data dir, at
# $MESH_ROOT/dex-frontend; it is $DEX_HOME/frontend now. Nothing is moved — the
# theme is rebuilt from the template on every run — so the old copy is only swept,
# and only once the stack is up on the new one: a dex still bound to the old files
# keeps serving them until the deploy above recreates it.
LEGACY_FRONTEND="$MESH_ROOT/dex-frontend"
if [ "$FAILED" -eq 0 ] && [ -d "$LEGACY_FRONTEND" ] && [ -f "$DEX_HOME/frontend/templates/login.html" ]; then
    rm -rf "$LEGACY_FRONTEND" && echo "Removed legacy $LEGACY_FRONTEND (login theme is rendered at $DEX_HOME/frontend)"
fi

exit "$FAILED"
