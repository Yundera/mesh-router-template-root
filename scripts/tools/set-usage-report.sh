#!/bin/bash
# set-usage-report.sh <on|off> - usage (DAU) reporting to the box's backend.
#
#   on   the default: mesh-router-caddy streams its access log to mesh-router-agent,
#        which reports once a day's set grows "these apps were opened today" to the
#        backend in PROVIDER (date + app names only: no addresses, paths or counts).
#   off  Caddy keeps no access log and the agent sends nothing.
#
# Writes MESH_USAGE_REPORT and applies it at once (ensure-stack-up.sh recreates
# mesh-router-caddy and mesh-router-agent with the new value).
#
# The choice is the owner's: unlike the update channel, it is NOT locked by
# MESH_UPDATES_MANAGED_BY, and an operator's template must not write the key on every
# run (it may seed it once).
#
# THE CONTRACT with mesh-console (same shape as set-primary-form.sh): the console only
# knows this path, the two values, the exit codes and the agent's state file
# data/usage/state.json.
#
# Takes the self-check lock and REFUSES while a self-check runs.
#
# Exit: 0 applied, 2 bad arguments, 75 a self-check is running (try later),
#       1 written but applying failed.
set -euo pipefail

VALUE="${1:-}"
case "$VALUE" in
    on|off) ;;
    *) echo "usage: $0 <on|off>" >&2; exit 2 ;;
esac

exec 200>"/var/run/mesh-self-check.lock"
if ! flock -n 200; then
    echo "A self-check is running on this box - try again once it has finished." >&2
    exit 75
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

if [ "$(get_env_value MESH_USAGE_REPORT)" != "$VALUE" ]; then
    set_env_value MESH_USAGE_REPORT "$VALUE"
fi
export MESH_USAGE_REPORT="$VALUE"
echo "MESH_USAGE_REPORT=$VALUE"

execute_script_with_logging "$SELF_DIR/self-check/ensure-stack-up.sh" || exit 1
echo "Usage reporting: $VALUE"
