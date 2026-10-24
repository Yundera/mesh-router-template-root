#!/bin/bash
# set-routing-mode.sh <auto|tunnel|confirm> [--revert-after <secs>] [--wait]
#   - choose the path public traffic takes behind the gateway.
#
# THE CONTRACT with mesh-console (same shape as set-default-app.sh): the console
# only knows this path, the three verbs, the state file and the exit codes. How a
# mode is applied is this template's business, and lives here.
#
#   auto     the default: the agent's direct route wins whenever the box has one
#            (priority 1), the tunnel (priority 2) otherwise. Cancels a pending
#            revert.
#   tunnel   MESH_ROUTING_FORCE=tunnel: the agent keeps running but registers at
#            priority 3, so the tunnel wins within seconds (see
#            routing_force_sync_env in library/common.sh for why it is demoted,
#            not stopped). With --revert-after N, back to auto after N seconds
#            unless `confirm` comes first - the console always passes it, since
#            the console itself is reached over the path being changed.
#   confirm  keep the current mode: cancel the pending revert. A no-op when none
#            is pending.
#
# STATE for the console, which cannot ask systemd: data/routing/force.json,
#   {"mode":"auto|tunnel","revertAt":"<UTC ISO>"|null,"changedAt":"<UTC ISO>"}
# The mode in .env is the truth; revertAt is only meaningful while it matches.
#
# Takes the self-check lock and REFUSES while a self-check runs, like the other
# console tools. --wait (the revert timer's own call) waits for it instead: a
# revert that gave up because a self-check happened to run would leave the box
# forced with nobody watching.
#
# Exit: 0 applied, 2 bad arguments, 75 a self-check is running (try later),
#       76 routing is held by a migration (MESH_ROUTING_HOLD),
#       1 written but applying failed (see the log).
set -euo pipefail

MODE="${1:-}"
shift || true
REVERT_AFTER=""
WAIT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --revert-after) REVERT_AFTER="${2:-}"; shift 2 || { echo "--revert-after needs a value" >&2; exit 2; } ;;
        --wait) WAIT=1; shift ;;
        *) echo "unknown argument: '$1'" >&2; exit 2 ;;
    esac
done

case "$MODE" in
    auto|tunnel|confirm) ;;
    *) echo "usage: $0 <auto|tunnel|confirm> [--revert-after <secs>] [--wait]" >&2; exit 2 ;;
esac
if [ -n "$REVERT_AFTER" ]; then
    [ "$MODE" = "tunnel" ] || { echo "--revert-after only applies to tunnel" >&2; exit 2; }
    if ! [[ "$REVERT_AFTER" =~ ^[0-9]{2,5}$ ]] || [ "$REVERT_AFTER" -lt 60 ] || [ "$REVERT_AFTER" -gt 86400 ]; then
        echo "invalid --revert-after: '$REVERT_AFTER' (60-86400 seconds)" >&2
        exit 2
    fi
    command -v systemd-run >/dev/null 2>&1 || { echo "systemd is required for --revert-after" >&2; exit 1; }
fi

exec 200>"/var/run/mesh-self-check.lock"
if [ "$WAIT" = 1 ]; then
    flock -w 3600 200 || { echo "Gave up waiting for the self-check lock" >&2; exit 75; }
elif ! flock -n 200; then
    echo "A self-check is running on this box - try again once it has finished." >&2
    exit 75
fi

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

UNIT="mesh-routing-revert"

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

cancel_revert() {
    systemctl stop "$UNIT.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT.timer" "$UNIT.service" >/dev/null 2>&1 || true
}

write_state() {
    local mode="$1" revert_at="null" tmp
    [ -n "$2" ] && revert_at="\"$2\""
    mkdir -p "$(dirname "$ROUTING_FORCE_STATE")"
    tmp="$(mktemp "$ROUTING_FORCE_STATE.XXXXXX")"
    printf '{"mode":"%s","revertAt":%s,"changedAt":"%s"}\n' "$mode" "$revert_at" "$(now_iso)" > "$tmp"
    chmod 644 "$tmp"
    mv -f "$tmp" "$ROUTING_FORCE_STATE"
}

if [ "$MODE" = "confirm" ]; then
    cancel_revert
    write_state "$(routing_force)" ""
    log_info "Routing mode $(routing_force) kept: pending revert cancelled"
    exit 0
fi

if [ -n "$(get_env_value MESH_ROUTING_HOLD)" ]; then
    echo "Routing is held by a migration ($(get_env_value MESH_ROUTING_HOLD)): the agent and tunnel are down, there is no mode to choose." >&2
    exit 76
fi

# A new choice replaces whatever revert was pending; tunnel schedules its own below.
cancel_revert

set_env_value MESH_ROUTING_FORCE "$MODE"
routing_force_sync_env

REVERT_AT=""
if [ -n "$REVERT_AFTER" ]; then
    systemd-run --quiet --collect --unit="$UNIT" --on-active="${REVERT_AFTER}s" \
        /bin/bash "$SELF" auto --wait
    REVERT_AT="$(date -u -d "+${REVERT_AFTER} seconds" '+%Y-%m-%dT%H:%M:%SZ')"
fi
write_state "$MODE" "$REVERT_AT"
log_info "Routing mode set to $MODE${REVERT_AT:+ (reverts to auto at $REVERT_AT unless confirmed)} - applying"

execute_script_with_logging "$SELF_DIR/self-check/ensure-stack-up.sh" || exit 1
