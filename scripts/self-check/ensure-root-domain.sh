#!/bin/bash
# Check-only: verify the root domain actually serves something.
#
# ${DOMAIN}, ${PUBLIC_IP_DASH}.nip.io, ${PUBLIC_IP_DASH}.sslip.io and the catch-all
# all reverse_proxy to DEFAULT_SERVICE_HOST:DEFAULT_SERVICE_PORT — the Caddyfile is
# the only definition of those four, and no container may claim them via a label. So
# one stale value in .env takes down the box's entire front door while every
# per-service hostname (maison-${DOMAIN}, auth-${DOMAIN}, every app) keeps working,
# because those come from container labels instead.
#
# That is exactly the failure this check exists for: a stable -> main upgrade that
# left DEFAULT_SERVICE_HOST=casaos reported "17/17 OK" while https://${DOMAIN}
# returned 502 to every visitor. Every other step passed honestly — none of them
# looks at the front door.
#
# No repair: ensure-env-valid.sh heals the values it knows are dead, and everything
# else here means the target service is down or misconfigured, which needs a human.
# The Caddyfile says as much ("a host that is not on `pcs`, or a typo, yields a 502
# on the root domain with nothing else to indicate why") — this turns that comment
# into a test.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ -z "${DOMAIN:-}" ]; then
    echo "ERROR: DOMAIN not set"
    exit 1
fi

SERVICE_HOST="$(get_env_value DEFAULT_SERVICE_HOST)"
SERVICE_PORT="$(get_env_value DEFAULT_SERVICE_PORT)"

# Probe the local Caddy directly rather than resolving ${DOMAIN} over the internet:
# this must report on THIS box's routing, not on the gateway, DNS propagation or the
# tunnel — all of which have their own checks and their own failure modes.
CODE=""
for attempt in 1 2 3; do
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Host: $DOMAIN" https://127.0.0.1/ 2>/dev/null) || CODE="000"
    case "$CODE" in
        502|503|504|000) ;;   # upstream unreachable — the service may still be starting
        *) break ;;
    esac
    [ "$attempt" -lt 3 ] && sleep 10
done

case "$CODE" in
    502|503|504)
        echo "ERROR: root domain https://$DOMAIN returns $CODE from the local Caddy."
        echo "  DEFAULT_SERVICE_HOST=$SERVICE_HOST DEFAULT_SERVICE_PORT=$SERVICE_PORT"
        if [ -n "$SERVICE_HOST" ] && ! docker inspect "$SERVICE_HOST" >/dev/null 2>&1; then
            echo "  No container named '$SERVICE_HOST' exists — the value is stale."
        elif [ -n "$SERVICE_HOST" ] && \
             ! docker inspect -f '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}' \
                 "$SERVICE_HOST" 2>/dev/null | grep -qw "${APP_NET:-pcs}"; then
            echo "  Container '$SERVICE_HOST' is not on the ${APP_NET:-pcs} network, so Caddy cannot resolve it."
        else
            echo "  '$SERVICE_HOST' resolves but is not answering on port $SERVICE_PORT."
        fi
        exit 1
        ;;
    000)
        echo "ERROR: local Caddy did not answer on :443 — mesh-router-caddy is down or not bound."
        exit 1
        ;;
esac

echo "Root domain serving $CODE from $SERVICE_HOST:$SERVICE_PORT"
