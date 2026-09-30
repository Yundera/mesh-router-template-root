#!/bin/bash
# set-default-app.sh <host> <port> - point the root domain at another app.
#
# THE CONTRACT with mesh-console (and anything else that changes this setting):
# both templates ship this script at <template scripts>/tools/set-default-app.sh,
# with the same arguments and exit codes. The console only knows that path; where
# the setting is stored and what has to be recreated for it to take effect is
# this template's business, and lives here. Yundera/template-root has its own
# copy for its own layout.
#
# What it does here: writes DEFAULT_SERVICE_HOST / DEFAULT_SERVICE_PORT into the
# mesh .env (the source of truth on this template), then re-runs the two
# self-check steps that apply it —
#   ensure-stack-up.sh    mesh-router-caddy: the root-domain routes + catch-all
#   ensure-auth-stack.sh  auth-registrar: ROOT_CLIENT_ID, so a login on the bare
#                         domain comes back to the bare domain
# Both read the same variable, which is why it is one setting.
#
# Takes the self-check lock and REFUSES while a self-check runs rather than
# waiting for it: a self-check takes minutes, and it applies whatever .env holds
# when it reaches these steps anyway.
#
# Exit: 0 applied, 2 bad arguments, 75 a self-check is running (try later),
# 1 the setting was written but applying it failed (see the log).
set -euo pipefail

HOST="${1:-}"
PORT="${2:-}"

# Same rules as the console validates with: a container name or a hostname such
# as host.docker.internal — Docker's own name charset, no shell metacharacters.
if ! [[ "$HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo "invalid host: '$HOST'" >&2
    exit 2
fi
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "invalid port: '$PORT'" >&2
    exit 2
fi

exec 200>"/var/run/mesh-self-check.lock"
if ! flock -n 200; then
    echo "A self-check is running on this box - try again once it has finished." >&2
    exit 75
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

set_env_value DEFAULT_SERVICE_HOST "$HOST"
set_env_value DEFAULT_SERVICE_PORT "$PORT"
log_info "Default app set to $HOST:$PORT - applying"

# Stop at the first failure: the auth stack is not worth recreating when the mesh
# stack, which routes to it, did not come up.
for step in ensure-stack-up.sh ensure-auth-stack.sh; do
    execute_script_with_logging "$SELF_DIR/self-check/$step" || exit 1
done
