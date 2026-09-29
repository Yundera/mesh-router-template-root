#!/bin/bash
# ensure-mesh-console-stack.sh - Deploy Mesh Console behind its AppShield gate.
#
# Mesh Console (github.com/Yundera/mesh-console) is the box's local status and
# control page: IP, domain, routing state, template version + "Update now", and the
# root-domain default app. See stacks/mesh-console/docker-compose.yml for the
# security model — the app holds the Docker socket, the gate is the only way in.
#
# Deployed to ${DATA_ROOT}/AppData/mesh-console (no dot in the name, so Maison's
# managed scan tiles it in the System grid).
#
# ORDERING: must run AFTER ensure-stack-up.sh — the `pcs` network is owned by the
# mesh stack, and the gate needs auth-registrar / dex reachable by name on it.
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

CONSOLE_DIR="${DATA_ROOT:-/DATA}/AppData/mesh-console"

# Shared secret between the gate (signs X-AppShield-Assertion) and the app
# (verifies it). Minted once into the mesh .env; deploy-stack.sh copies that file
# into the stack's .env, which is how compose interpolates it into both services.
# Unset, the app refuses every request — it fails closed, never open.
#
# RECOVERY: nothing to back up. Deleting the key re-mints it on the next run and
# deploy-stack.sh recreates both services with the new value.
SECRET="$(get_env_value MESH_CONSOLE_ASSERTION_SECRET)"
if [ -z "$SECRET" ]; then
    SECRET="$(openssl rand -hex 32)"
    set_env_value MESH_CONSOLE_ASSERTION_SECRET "$SECRET"
    log_info "Generated MESH_CONSOLE_ASSERTION_SECRET"
fi

# The self-check log is written in host local time; the console parses it in TZ.
if [ -f /etc/timezone ]; then
    TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"
elif [ -L /etc/localtime ]; then
    TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
else
    TZ="UTC"
fi

mkdir -p "$CONSOLE_DIR"

exec "$SCRIPTS_DIR/tools/deploy-stack.sh" mesh-console "$CONSOLE_DIR" \
    "TZ=$TZ"
