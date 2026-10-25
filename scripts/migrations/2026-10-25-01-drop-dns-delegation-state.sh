#!/bin/bash
# Migration: the box zone's TLS moved into mesh-router-caddy (1.4.0), which decides
# from the backend by itself; the dot form is always on.
#
# Runs before the new Caddyfile is put in place. That Caddyfile imports
# /data/mesh-zone.caddy (the Caddy container's data dir), which only the 1.4.0 image
# writes, and caddy-docker-proxy DROPS a site block whose import is missing (root and
# *.<domain> served cert0 until Caddy is recreated). So seed the file here, from the
# removed ensure-dns-delegation.sh's state: its delegated TLS block if it had one, else
# the not-delegated default. The image rewrites it at its start.
#
# Then drop DNS_DOT_FORM and REDIRECT_DOT_SUFFIXES from .env. data/dns/ stays until a
# later release: the Caddyfile still live until the propagation imports it.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

ZONE_FILE="$MESH_ROOT/data/caddy/data/mesh-zone.caddy"
if [ ! -s "$ZONE_FILE" ]; then
    mkdir -p "$(dirname "$ZONE_FILE")"
    tmp="$(mktemp "$ZONE_FILE.XXXXXX")"
    OLD="$MESH_ROOT/data/dns"
    if [ -s "$OLD/wildcard.caddy" ] && grep -q "dns acmedns" "$OLD/site_tls.caddy" 2>/dev/null; then
        # the old (site_tls) snippet's body = the DNS-01 tls block, for both new snippets
        body="$(sed '1d;$d' "$OLD/site_tls.caddy")"
        printf '# Seeded by migration 2026-10-25-01 (delegated).\n(zone_root_tls) {\n%s\n}\n(zone_tls) {\n%s\n}\n' "$body" "$body" >"$tmp"
    else
        printf '# Seeded by migration 2026-10-25-01.\n(zone_root_tls) {\n\timport gateway_tls\n}\n(zone_tls) {\n\ttls internal\n}\n' >"$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$ZONE_FILE"
    echo "seeded $ZONE_FILE"
fi

for key in DNS_DOT_FORM REDIRECT_DOT_SUFFIXES; do
    if [ -n "$(bash "$ENV_MGR" get "$key" "$ENV_FILE" 2>/dev/null)" ] || grep -q "^$key=" "$ENV_FILE" 2>/dev/null; then
        bash "$ENV_MGR" delete "$key" "$ENV_FILE" >/dev/null
        echo "removed $key from .env"
    fi
done
