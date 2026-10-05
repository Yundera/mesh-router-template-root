#!/bin/bash
# set-update-channel.sh <stable|dev|local|custom> [url] - choose where the
# nightly self-check takes this template from.
#
# THE CONTRACT with mesh-console (same shape as set-default-app.sh): the console
# only knows this path, the four channel names and the exit codes. What a channel
# means in .env is this template's business, and lives here.
#
#   stable  UPDATE_URL = the stable branch tarball, MESH_AUTO_UPDATE=true
#   dev     UPDATE_URL = the main branch tarball,   MESH_AUTO_UPDATE=true
#   custom  UPDATE_URL = <url>,                      MESH_AUTO_UPDATE=true
#   local   MESH_AUTO_UPDATE=false - the self-check keeps repairing the box but
#           never downloads; UPDATE_URL is left as it is, so switching back is
#           a one-click return to the same source.
#
# The deprecated MESH_TEMPLATE_URL / MESH_UPDATE_CHANNEL are dropped on every
# switch: mesh_template_url() reads them after UPDATE_URL, so a stale one would
# only resurface if UPDATE_URL were ever cleared.
#
# Only writes .env. Nothing is downloaded here; the next self-check (nightly, or
# "Update now" in the console) syncs from the new source.
#
# Takes the self-check lock and REFUSES while a self-check runs: one that has
# already read .env would sync from the old source and record it as current.
#
# Exit: 0 saved, 2 bad arguments, 75 a self-check is running (try later).
set -euo pipefail

CHANNEL="${1:-}"
URL="${2:-}"

case "$CHANNEL" in
    stable|dev|local) [ -z "$URL" ] || { echo "channel '$CHANNEL' takes no url" >&2; exit 2; } ;;
    custom)
        # https or a host file (how a template is tested without a push). No
        # quotes, spaces, `$` (compose interpolates .env) or backslashes.
        url_re='^(https|file)://[A-Za-z0-9._~:/?#@!&()*+,;=%-]+$'
        if [ "${#URL}" -gt 2048 ] || ! [[ "$URL" =~ $url_re ]]; then
            echo "invalid url: '$URL' (https:// or file://, no spaces or quotes)" >&2
            exit 2
        fi
        case "$URL" in
            *.zip) echo "invalid url: this template is a .tar.gz, not a .zip" >&2; exit 2 ;;
        esac
        ;;
    *) echo "usage: $0 <stable|dev|local|custom> [url]" >&2; exit 2 ;;
esac

exec 200>"/var/run/mesh-self-check.lock"
if ! flock -n 200; then
    echo "A self-check is running on this box - try again once it has finished." >&2
    exit 75
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

case "$CHANNEL" in
    stable) URL="$(mesh_channel_url stable)" ;;
    dev)    URL="$(mesh_channel_url main)" ;;
esac

if [ "$CHANNEL" = "local" ]; then
    set_env_value MESH_AUTO_UPDATE false
    log_info "Update channel set to local: template downloads off"
else
    set_env_value UPDATE_URL "$URL"
    set_env_value MESH_AUTO_UPDATE true
    log_info "Update channel set to $CHANNEL: $URL"
fi
for key in MESH_TEMPLATE_URL MESH_UPDATE_CHANNEL; do
    bash "$ENV_MGR" delete "$key" "$ENV_FILE" >/dev/null 2>&1 || true
done
