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

# The Dex login-theme files and the Authelia pin check that used to sit here moved
# to ensure-auth-stack.sh with the services they protect.

# THE MESH CA LIVES IN data/ca, ALONE. Dex mounts that
# directory read-only to trust the certificate Caddy serves on the on-box path
# (see CA_CERT_PATH on mesh-router-agent in docker-compose.yml). Before that
# variable existed the agent wrote the CA beside the private key, in data/certs.
#
# MOVED, not copied: one CA file, and the agent its only writer. A copy would
# leave a second file that nothing updates and that goes stale silently on the
# next CA change. Not a symlink either — the containers mount data/ca alone, so
# a link into data/certs would dangle inside them.
#
# Before `up`, so the CA is already in place when anything that trusts it starts:
# the agent only writes it once it has reached the backend, and the gates in this
# same compose file would otherwise come up beside an empty directory.
#
# Nothing depends on the old copy. The agent requests a fresh certificate at
# every start and rewrites all three files, the CA at CA_CERT_PATH — so the moved
# file is refreshed in place seconds later, and a box rolled back to a compose
# file without CA_CERT_PATH simply gets data/certs/ca-cert.pem written again.
#
# Only when the compose file about to be brought up actually sets CA_CERT_PATH:
# with a hand-kept older file (MESH_AUTO_UPDATE=false) the agent still writes
# data/certs and nothing mounts data/ca.
MESH_CA_DIR="$MESH_ROOT/data/ca"
LEGACY_CA="$MESH_ROOT/data/certs/ca-cert.pem"
if grep -q 'CA_CERT_PATH' "$APP_DIR/docker-compose.yml"; then
    mkdir -p "$MESH_CA_DIR"
    if [ -s "$MESH_CA_DIR/ca-cert.pem" ]; then
        if [ -e "$LEGACY_CA" ]; then
            rm -f "$LEGACY_CA" && echo "Removed stale $LEGACY_CA (the mesh CA is $MESH_CA_DIR/ca-cert.pem)"
        fi
    elif [ -s "$LEGACY_CA" ]; then
        mv -f "$LEGACY_CA" "$MESH_CA_DIR/ca-cert.pem" && echo "Moved the mesh CA to $MESH_CA_DIR/ca-cert.pem"
    fi
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

# Every stack joins `pcs` as external; nothing creates it but this.
ensure_pcs_network || FAILED=1

cd "$APP_DIR"

# A container from another project holding one of our names makes `up` abort for
# the whole stack (see evict_name_squatters in library/common.sh).
evict_name_squatters || FAILED=1

# --remove-orphans, EXCEPT while this project still holds containers another stack
# now declares (see services_handed_over in library/common.sh). On the cycle that
# moved dex/authelia/auth-registrar out, this runs before ensure-auth-stack.sh, and
# pruning them here would drop every login on the box until that script had run —
# or for good, if it then failed. Kept, they keep serving; the auth stack's own
# eviction retires them, and the next cycle prunes normally.
UP_ARGS=(-d --remove-orphans)
HANDED_OVER="$(services_handed_over mesh "$TEMPLATE_DIR/stacks/auth/docker-compose.yml" | xargs)"
if [ -n "$HANDED_OVER" ]; then
    echo "WARN: keeping mesh containers now owned by the auth stack until it takes them over: $HANDED_OVER"
    UP_ARGS=(-d)
fi

# ROUTING HOLD: keep this box off the domain. Two agents (or tunnels) on one
# identity overwrite each other's routes in the backend - last writer wins and the
# domain flaps - so while MESH_ROUTING_HOLD is set, mesh-router-agent and
# mesh-router-tunnel are kept ABSENT; everything else, Caddy included, still runs
# and answers on the box's own sslip.io / nip.io names. Set by tools/migrate.sh:
#   migrating:<id>       a target being brought up, or a source mid-cutover
#   retired:<target-ip>  a migrated-away source; deleting the key is the rollback
# Absent rather than stopped, the same as dex in the auth stack: a stopped
# container is restarted by the next `up` and fails wait_stack_settled.
ROUTING_HOLD="$(get_env_value MESH_ROUTING_HOLD)"
if [ -n "$ROUTING_HOLD" ]; then
    echo "Routing held ($ROUTING_HOLD): mesh-router-agent and mesh-router-tunnel stay down"
    UP_ARGS+=(--scale mesh-router-agent=0 --scale mesh-router-tunnel=0)
fi

# If `up` still fails, start whatever it did create before reporting: compose
# aborts mid-way leaving containers in `Created`, and install.sh has already taken
# the stack down, so a hard exit here leaves the box with no routing at all. A
# partial stack (caddy + tunnel up, one service missing) is far better than none.
if docker compose up "${UP_ARGS[@]}"; then
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

# On a fresh box there was no CA to move: the agent fetches its certificate once
# it is up and writes the CA then. The auth stack is next and Dex needs that file
# to open the Local Account connector, so give the agent a moment. A warning, not
# a failure: a box whose agent cannot reach the backend has no certificate at
# all, which the verification steps at the end of the list report on their own.
if [ -z "$ROUTING_HOLD" ] && grep -q 'CA_CERT_PATH' "$APP_DIR/docker-compose.yml"; then
    for _ in $(seq 1 15); do
        [ -s "$MESH_CA_DIR/ca-cert.pem" ] && break
        sleep 2
    done
    [ -s "$MESH_CA_DIR/ca-cert.pem" ] \
        || echo "WARN: mesh-router-agent has not written $MESH_CA_DIR/ca-cert.pem yet - Dex cannot verify TLS on its on-box call to Authelia until it does"
fi

exit "$FAILED"
