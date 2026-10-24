#!/bin/bash
# set-dns-force.sh <gateway|auto>
#   - the owner's choice of what the mesh nameservers answer for this box's names,
#     once its zone is delegated to them.
#
# THE CONTRACT with mesh-console (same shape as set-routing-mode.sh): the console
# only knows this path, the two verbs and the exit codes. The box credential stays
# here: the console never holds the route signature.
#
#   gateway  every name of the box answers the gateway, even when the box could be
#            reached directly (the owner's "route through the gateway")
#   auto     the default: the box's IP once the backend has verified that the box
#            serves its own names with a trusted certificate, the gateway otherwise
#
# Stored by mesh-router-backend (PUT /dns/v1/force/<userid>/<signature>); the
# nameservers follow within seconds, resolvers within the 30 s record TTL. "direct"
# is an admin action (mesh-cli dns force), not the owner's.
#
# Exit: 0 applied, 2 bad arguments, 1 the backend refused or was unreachable.
set -euo pipefail

FORCE="${1:-}"
case "$FORCE" in
    gateway|auto) ;;
    *) echo "usage: $0 <gateway|auto>" >&2; exit 2 ;;
esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

IFS=',' read -r BACKEND_URL USER_ID SIG <<< "${PROVIDER_STR:-}"
if [ -z "${BACKEND_URL:-}" ] || [ -z "${USER_ID:-}" ] || [ -z "${SIG:-}" ]; then
    echo "PROVIDER_STR is not set: this box has no backend identity" >&2
    exit 1
fi

# The signature is base64 (+, /, =): percent-encode it for the path.
urlencode() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

URL="${BACKEND_URL%/}/router/api/dns/v1/force/$(urlencode "$USER_ID")/$(urlencode "$SIG")"
if ! RESPONSE="$(curl -sS --max-time 20 -w '\n%{http_code}' -X PUT "$URL" \
        -H 'Content-Type: application/json' -d "{\"force\":\"$FORCE\"}" 2>&1)"; then
    echo "Backend unreachable: $RESPONSE" >&2
    exit 1
fi
STATUS="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"
if [ "$STATUS" != "200" ]; then
    echo "Backend refused ($STATUS): $BODY" >&2
    exit 1
fi
echo "DNS force: $FORCE ($BODY)"
