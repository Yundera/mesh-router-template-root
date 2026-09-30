#!/bin/bash
# Bring the auth stack up: dex, authelia, auth-registrar (stacks/auth/).
#
# Deployed to ${DATA_ROOT}/AppData/auth through tools/deploy-stack.sh, like maison
# and terminal. It renders nothing: ensure-authelia.sh and ensure-dex.sh have
# written every config these services read, and the data stays under the mesh
# root — only the compose project is new.
#
# THE CUTOVER. Until the split these three were services of the mesh stack. On the
# first run here, deploy-stack.sh's eviction removes the mesh-project containers
# holding their names and this project recreates them — a login outage of one
# container restart, not of the whole update. ensure-stack-up.sh keeps them alive
# under the mesh project until then (services_handed_over), so a failure here
# leaves the old ones running rather than none. On the cycle that delivers this
# script, self-check.sh runs it after the rest of the list (new entries are
# appended); the old containers keep serving login until it does.
#
# ORDERING: after ensure-authelia.sh / ensure-dex.sh (their rendered files are
# bind-mounted here) and after ensure-stack-up.sh (Caddy routes these hosts and
# smtp relays Authelia's mail). Before maison and terminal: their gates register
# through auth-registrar.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

AUTH_DIR="${DATA_ROOT:-/DATA}/AppData/auth"
FAILED=0

# The compose file bind-mounts dex-frontend/templates/{login,header}.html as
# SINGLE FILES, so an `up` before they exist makes Docker create them as
# directories and `dex` can never start again ("not a directory"). The tool is
# idempotent and cheap; running it here as well as in ensure-dex.sh means no path
# reaches `up` without those files.
if [ -x "$SCRIPTS_DIR/tools/provision-dex-frontend.sh" ]; then
    "$SCRIPTS_DIR/tools/provision-dex-frontend.sh" \
        || echo "WARN: Dex frontend provisioning reported an error; continuing"
fi

"$SCRIPTS_DIR/tools/deploy-stack.sh" auth "$AUTH_DIR" || FAILED=1

# Same reason as ensure-stack-up.sh: `up` exiting 0 only means the containers were
# created, and a crash-looping authelia or dex is a box nobody can log in to.
cd "$AUTH_DIR"
if wait_stack_settled 90 15; then
    echo "Auth stack is up"
else
    FAILED=1
fi

exit "$FAILED"
