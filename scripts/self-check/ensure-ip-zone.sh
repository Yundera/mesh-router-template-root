#!/bin/bash
# Turn IP_ZONE on by itself once the provider's ip zone answers for this box.
#
# IP_ZONE (README) is the mesh-router-nameserver zone the box's IP names live in:
# `<ip-dashed>.ip.<server domain>` → this box's IP. With it the agent registers
# those routes instead of nip.io ones and Maison publishes every app there. The
# zone is `ip.` + the parent of DOMAIN (watch.nsl.sh → ip.nsl.sh), and it is turned
# on only once it resolves this box's own public IPv4 — a zone that answers only
# for registered boxes still answers for this one. So a box switches when the
# operator delegates the zone, and nothing changes before.
#
# A STATED value wins: when .env holds IP_ZONE at all — a zone, or empty for "off" —
# this leaves it alone. An operator layer (template-root) writes it there, and so
# does this script once the zone answers. It never removes the key: one DNS hiccup
# must not take the zone away and republish every app.
#
# The backend must sign `*.<IP_ZONE>` into the box certificate (CERT_EXTRA_SANS);
# an operator that runs the nameserver sets that up with it.
#
# Runs after ensure-public-ip.sh (needs PUBLIC_IPV4) and before
# ensure-routing-domains.sh, so the routing domains and the agent pick the zone up
# in the same run. Never fatal.
set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if bash "$ENV_MGR" exists IP_ZONE "$ENV_FILE" >/dev/null 2>&1; then
    echo "IP_ZONE stated (${IP_ZONE:-off}), left as it is"
    exit 0
fi

PARENT="${DOMAIN#*.}"
# A domain with no parent zone of its own (example.com → com) has no ip zone to try.
if [ -z "${DOMAIN:-}" ] || [ "$PARENT" = "$DOMAIN" ] || [[ "$PARENT" != *.* ]]; then
    echo "No server domain to derive an ip zone from (DOMAIN=${DOMAIN:-<empty>}); IP_ZONE stays unset"
    exit 0
fi
ZONE="ip.$PARENT"

IP="${PUBLIC_IPV4:-}"
if [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "No public IPv4 known yet; IP_ZONE stays unset"
    exit 0
fi

GOT="$(getent ahostsv4 "${IP//./-}.$ZONE" 2>/dev/null | awk 'NR==1 {print $1}')" || true
if [ "$GOT" != "$IP" ]; then
    echo "$ZONE does not answer for $IP (got ${GOT:-nothing}); IP_ZONE stays unset"
    exit 0
fi

set_env_value IP_ZONE "$ZONE"
echo "IP_ZONE=$ZONE: $ZONE answers for $IP (.env updated, stack will be recreated)"
