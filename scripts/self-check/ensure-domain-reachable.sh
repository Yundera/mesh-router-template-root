#!/bin/bash
# Check-only: end-to-end probe of the full chain
#   DNS -> gateway/CF worker -> agent|tunnel route -> caddy -> service.
# This is the one check that proves the mesh actually routes traffic.
#
# Pass criteria: any HTTP response that is not a routing-layer failure.
# 502/503/504 come from the gateway when no healthy route exists; other
# statuses (200, 30x, 401, 404...) prove the request reached the PCS.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN not set"
    exit 1
fi

HEADERS_FILE=$(mktemp)
trap 'rm -f "$HEADERS_FILE"' EXIT

HTTP_CODE=$(curl -sS -o /dev/null -D "$HEADERS_FILE" -w '%{http_code}' \
    --max-time 30 -H 'X-Mesh-Trace: 1' "https://$DOMAIN/" 2>&1) || HTTP_CODE="000"

MESH_ROUTE=$(grep -i '^x-mesh-route:' "$HEADERS_FILE" | tr -d '\r' | cut -d' ' -f2- || true)

case "$HTTP_CODE" in
    000)
        echo "ERROR: https://$DOMAIN/ unreachable (DNS, TLS or connection failure)"
        exit 1
        ;;
    502|503|504)
        echo "ERROR: https://$DOMAIN/ returned $HTTP_CODE (routing layer found no healthy route)${MESH_ROUTE:+ - route: $MESH_ROUTE}"
        exit 1
        ;;
    *)
        echo "https://$DOMAIN/ reachable (HTTP $HTTP_CODE)${MESH_ROUTE:+ via $MESH_ROUTE}"
        exit 0
        ;;
esac
