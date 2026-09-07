#!/bin/bash
# Migration: drop the pinned IPAM subnet from the `dex-internal` network.
#
# Dex's gRPC API used to be bound to a literal 172.31.7.2 on a /29, which meant
# docker-compose.yml had to reserve that subnet. It is now bound to `dex-grpc`, a
# network-scoped alias declared on the dex service, so no address is pinned and
# the compose file no longer declares an `ipam:` block.
#
# WHY A MIGRATION IS NEEDED. Docker will not reconfigure an existing network:
# with the old bridge still present, `docker compose up` either errors with
#
#   network dex-internal needs to be recreated - option ... ipam has changed
#
# or silently keeps the old subnet. Either way the box never picks up the new
# shape. The old network has to be removed so compose recreates it.
#
# DELIBERATELY CONDITIONAL AND NON-FORCING, modelled on template-root's
# 2026-08-27-10-rename-dex-internal-network.sh. It does NOT disconnect live
# endpoints: this runs inside ensure-template-sync.sh, before ensure-stack-up.sh
# has taken the stack down, so dex and auth-registrar are typically still
# attached. Forcing them off would break gRPC mid-cycle for no gain — the stack
# is about to be recreated anyway.
#
# So: remove the network only when it is already empty. On a box where it is
# still in use, this exits 0 having done nothing and runs again next cycle, by
# which time the recreate has detached everything. It converges rather than
# forcing.
#
# HENCE `.always.sh`, not a one-shot. run-migrations.sh writes a one-shot's marker
# on ANY successful exit, so a deferral would be recorded as "done" and the sweep
# would never happen. An .always.sh carries no marker and simply re-runs; once the
# network is ipam-less it returns at the check above for the cost of one
# `docker network inspect`.
#
# A no-op on a fresh install (no such network yet) and on any box that already
# has an ipam-less dex-internal.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

NET="dex-internal"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not available; nothing to sweep"
    exit 0
fi

if ! docker network inspect "$NET" >/dev/null 2>&1; then
    echo "Network $NET does not exist; nothing to do"
    exit 0
fi

# Already ipam-less: compose has recreated it, or this ran before.
SUBNETS="$(docker network inspect "$NET" \
    --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
if [ -z "${SUBNETS// /}" ]; then
    echo "Network $NET already has no IPAM config; nothing to do"
    exit 0
fi

echo "Network $NET still pins IPAM: ${SUBNETS}"

# Only remove it if nothing is attached. `docker network rm` on a network with
# live endpoints fails anyway; checking first keeps the log honest about why we
# are deferring rather than printing a scary error every cycle.
ATTACHED="$(docker network inspect "$NET" \
    --format '{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' 2>/dev/null || true)"
if [ -n "${ATTACHED// /}" ]; then
    echo "Deferring: still attached to:${ATTACHED% }"
    echo "The stack recreate later in this cycle detaches them; this migration"
    echo "sweeps the network on a following self-check."
    exit 0
fi

if docker network rm "$NET" >/dev/null 2>&1; then
    echo "Removed $NET; compose recreates it without an IPAM pin on the next up"
else
    echo "Could not remove $NET; will retry next cycle"
fi

exit 0
