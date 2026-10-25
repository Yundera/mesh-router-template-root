#!/bin/bash
# set-primary-form.sh <dash|dot> - the form of the box's primary app names.
#
#   dash  <app>-<domain>: the default, works on every box.
#   dot   <app>.<domain>: only once the box's zone is delegated to the mesh nameservers
#         and Caddy holds the zone's wildcard certificate (dot_form_ready in
#         library/common.sh). Before that the dot names end at Cloudflare, whose
#         certificate stops one level below the zone.
#
# Writes MESH_PRIMARY_FORM and applies it at once: routing_domains puts the chosen form
# first, so Maison's tiles and every store app's APP_URL move to it (Maison republishes
# each app once: about a minute of 502 per app, and one gate login per app on the new
# host). Both forms stay routed either way. The platform stacks keep their dash names.
# A box that later loses the dot form falls back to dash at its next self-check.
#
# THE CONTRACT with mesh-console (same shape as set-routing-mode.sh): the console only
# knows this path, the two values, the exit codes and the derived .env keys
# PRIMARY_FORM_ACTIVE and DOT_FORM_READY (ensure-routing-domains.sh).
#
# Takes the self-check lock and REFUSES while a self-check runs.
#
# Exit: 0 applied, 2 bad arguments, 3 dot asked but the box cannot serve it (nothing
#       written), 75 a self-check is running (try later), 1 written but applying failed.
set -euo pipefail

FORM="${1:-}"
case "$FORM" in
    dash|dot) ;;
    *) echo "usage: $0 <dash|dot>" >&2; exit 2 ;;
esac

exec 200>"/var/run/mesh-self-check.lock"
if ! flock -n 200; then
    echo "A self-check is running on this box - try again once it has finished." >&2
    exit 75
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

if [ "$FORM" = dot ] && ! dot_form_ready; then
    echo "This box cannot serve the dot form yet: its zone is not delegated to the mesh nameservers, or Caddy has no wildcard certificate for it." >&2
    exit 3
fi

if [ "$(get_env_value MESH_PRIMARY_FORM)" != "$FORM" ]; then
    set_env_value MESH_PRIMARY_FORM "$FORM"
fi
echo "MESH_PRIMARY_FORM=$FORM"

# The two steps of the self-check that carry it: the derived keys, then Maison's
# routing setting (Maison republishes only when the value changed).
bash "$SELF_DIR/self-check/ensure-routing-domains.sh" || exit 1
bash "$SELF_DIR/self-check/ensure-maison-stack.sh" || exit 1
echo "Primary form: $(get_env_value PRIMARY_FORM_ACTIVE)"
