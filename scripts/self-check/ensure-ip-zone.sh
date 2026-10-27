#!/bin/bash
# Keep IP_ZONE set: the provider's ip zone, as its backend publishes it.
#
# IP_ZONE (README) is the mesh-router-nameserver zone the box's IP names live in:
# `<ip-dashed>.<IP_ZONE>` → this box's IP. The agent registers its direct routes there
# and Maison publishes every app there. It is part of the mesh architecture, not an
# option: there is no nip.io fallback, so a box without it has no direct route and
# is reachable over its tunnel only. That is a misconfiguration, and this step fails
# on it so the self-check says so.
#
# The zone comes from the provider: `ipZone` in <backend>/router/api/version, the
# backend being the first field of PROVIDER_STR. Not from a DNS probe — the zone only
# answers for IPs that already registered a route, which a box without IP_ZONE never
# does.
#
# A non-empty IP_ZONE already in .env wins (an operator layer such as template-root may
# state its own); an empty one is filled in like a missing one. It is never removed:
# a backend that cannot be reached leaves the current value alone, so one network
# hiccup does not take the zone away and republish every app.
#
# Runs after ensure-public-ip.sh and before ensure-routing-domains.sh, so the routing
# domains and the agent pick the zone up in the same run.
set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

CURRENT="$(get_env_value IP_ZONE)"
if [ -n "$CURRENT" ]; then
    echo "IP_ZONE=$CURRENT"
    exit 0
fi

IFS=',' read -r BACKEND _ <<< "${PROVIDER_STR:-}"
BACKEND="${BACKEND%/}"
if [ -z "$BACKEND" ]; then
    echo "ERROR: IP_ZONE unset and no PROVIDER_STR to ask a backend for it - no direct route"
    exit 1
fi

# One JSON line, {"version":2,...,"ipZone":"ip.nsl.sh"}: sed, not jq (no host dependency).
if ! RESPONSE="$(curl -sS --max-time 10 "$BACKEND/router/api/version" 2>&1)"; then
    echo "WARN: IP_ZONE unset and $BACKEND could not be reached ($RESPONSE); trying again next run"
    exit 0
fi
ZONE="$(printf '%s' "$RESPONSE" | sed -n 's/.*"ipZone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [ -z "$ZONE" ]; then
    echo "ERROR: IP_ZONE unset and $BACKEND publishes no ipZone - the provider runs no nameserver"
    echo "       (backend DNS_IP_ZONE). This box gets no direct route, only its tunnel."
    exit 1
fi

set_env_value IP_ZONE "$ZONE"
echo "IP_ZONE=$ZONE: published by $BACKEND (.env updated, stack will be recreated)"
