#!/bin/bash
# Migration: remove data/dns/, the state of the removed ensure-dns-delegation.sh
# (Caddyfile hooks, passthrough lists; wildcard.caddy held the route signature).
# Nothing reads it since mesh-router-caddy 1.4.0 decides the zone itself
# (2026-10-25-01 carried its delegated state over into data/caddy/data/mesh-zone.caddy).
#
# ONLY ONCE THE RUNNING CADDY NO LONGER MOUNTS IT. An older Caddy (its compose not yet
# recreated, or a stack update that failed half way) imports /data/dns/*.caddy, and
# caddy-docker-proxy drops every block whose import is missing: removing the files under
# it takes the box's sites down until the recreate. So this defers while the mount is
# there, hence `.always.sh` (a one-shot's marker is written on any exit 0, so a deferral
# would be recorded as done). Once the directory is gone it returns at the first check.
#
# A no-op on a fresh install (no data/dns).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

OLD="$MESH_ROOT/data/dns"
[ -d "$OLD" ] || exit 0

if docker inspect mesh-router-caddy >/dev/null 2>&1; then
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' mesh-router-caddy)"
    case " $mounts " in
        *" /data/dns "*) exit 0 ;;   # still imported by the running Caddy: next sync
    esac
fi

rm -rf "$OLD"
echo "removed $OLD"
