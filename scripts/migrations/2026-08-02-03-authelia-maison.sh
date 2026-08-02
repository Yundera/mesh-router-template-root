#!/bin/bash
# Migration: Authelia replaces the CasaOS OIDC path, Maison replaces CasaOS.
#
# This is the convergence step for the release that removes CasaOS. It runs from
# the NEWLY DOWNLOADED tree, before that tree is swapped in and before the new
# docker-compose.yml reaches its live location — which is the only window where it
# can prepare state the new compose needs in the SAME cycle.
#
# Why it cannot be left to the new ensure-*.sh scripts: self-check.sh runs the list
# it read at startup. ensure-authelia.sh is NEW in this release, so on the cycle that
# installs it, it only runs in pass 2 — after ensure-stack-up.sh has already applied
# the new compose. Without the work below, that cycle brings up `authelia` with no
# configuration.yml (crash loop) and re-renders Dex with an empty
# ${AUTHELIA_DEX_SECRET}, so SSO is down until the next nightly run.
#
# What it does, in order:
#   1. run the NEW tree's ensure-authelia.sh  (mints AUTHELIA_DEX_SECRET, renders config)
#   2. run the NEW tree's ensure-dex.sh       (re-renders with the authelia connector)
#   3. repoint the root domain casaos:8080 -> maison:80  BEFORE CasaOS goes
#   4. tear down casaos + casaos-oidc-bridge
#   5. sweep the dead BRIDGE_SECRET and the bridge/break-glass state
#
# ORDER MATTERS at 3/4: reversing them leaves ${DOMAIN} 502-ing for the rest of the
# cycle, since nothing would answer on the root domain until ensure-maison-stack.sh
# runs in pass 2.
#
# ############################################################################
# # /DATA/AppData/casaos IS NOT OURS TO DELETE.                              #
# # It holds apps/ — every app definition on the box, including apps/mesh,    #
# # which is this template's own directory. Removing CasaOS means removing    #
# # the CONTAINERS, never the tree. ensure-maison-app-mirror.sh keeps         #
# # projecting those apps into Maison's layout.                               #
# ############################################################################
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

ENV_MGR="$SELF_DIR/../tools/env-file-manager.sh"

# --- 1 + 2. provision the new identity stack from the NEW tree ---------------
# Best-effort: a box that cannot reach the registry to hash a password must not
# have its template sync aborted. The ensure-scripts are idempotent and run again
# in pass 2 and every cycle after, so a failure here self-heals.
if [ -x "$SELF_DIR/../self-check/ensure-authelia.sh" ] || [ -f "$SELF_DIR/../self-check/ensure-authelia.sh" ]; then
    echo "Provisioning Authelia from the new tree..."
    bash "$SELF_DIR/../self-check/ensure-authelia.sh" || \
        echo "WARN: ensure-authelia.sh failed here; pass 2 will retry"
fi
if [ -f "$SELF_DIR/../self-check/ensure-dex.sh" ]; then
    echo "Re-rendering Dex config from the new tree..."
    bash "$SELF_DIR/../self-check/ensure-dex.sh" || \
        echo "WARN: ensure-dex.sh failed here; pass 2 will retry"
fi

# --- 3. root-domain routing: casaos:8080 -> maison:80 ------------------------
# Only rewrite values that still point at CasaOS. An operator who deliberately set
# the root domain to some other service keeps their choice.
current_host="$(bash "$ENV_MGR" get DEFAULT_SERVICE_HOST "$ENV_FILE" 2>/dev/null || true)"
if [ -z "$current_host" ] || [ "$current_host" = "casaos" ]; then
    bash "$ENV_MGR" set DEFAULT_SERVICE_HOST "maison" "$ENV_FILE"
    bash "$ENV_MGR" set DEFAULT_SERVICE_PORT "80" "$ENV_FILE"
    echo "Root domain repointed: casaos:8080 -> maison:80"
else
    echo "DEFAULT_SERVICE_HOST is '$current_host' (operator-set); left alone"
fi

# --- 4. tear down the removed containers -------------------------------------
# The mesh stack's own `up --remove-orphans` handles services dropped from ITS
# compose file, which covers both of these — but only once it runs, and only if the
# project still knows about them. Removing them explicitly is deterministic and
# makes the intent obvious in the log.
for c in casaos casaos-oidc-bridge; do
    if docker inspect "$c" >/dev/null 2>&1; then
        docker rm -f "$c" >/dev/null 2>&1 && echo "Removed container: $c" || \
            echo "WARN: could not remove $c; the next compose up will orphan-prune it"
    fi
done

# --- 5. sweep dead state ------------------------------------------------------
# BRIDGE_SECRET fed the casaos-oidc-bridge's CLIENT_SECRET and the old Dex `casaos`
# connector. Nothing reads it now.
if bash "$ENV_MGR" exists BRIDGE_SECRET "$ENV_FILE"; then
    bash "$ENV_MGR" delete BRIDGE_SECRET "$ENV_FILE"
    echo "Dropped dead BRIDGE_SECRET from .env"
fi

# The bridge's signing key, and the disposable Dex break-glass admin that only
# existed because CasaOS could be unreachable. Authelia is the recovery path now.
rm -rf "$MESH_ROOT/casaos-oidc-bridge"
rm -f "$MESH_ROOT/dex/admin-password" "$MESH_ROOT/dex/admin-hash"

echo "Authelia/Maison convergence complete"
