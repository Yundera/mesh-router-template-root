#!/bin/bash
# ensure-dex.sh - Provision the Dex OIDC broker (the PCS SSO identity provider).
#
# Responsibilities (all idempotent):
#   - render Dex config.yaml from the template every run (tracks DOMAIN changes
#     and re-emits the connector secret),
#   - read AUTHELIA_DEX_SECRET (minted by ensure-authelia.sh, which runs just
#     before) so the "Local Account" connector renders,
#   - own the sqlite data dir so the dex container (uid 1001) can write dex.db,
#   - restart dex so a re-rendered config is picked up.
#
# Storage layout (host ${DATA_ROOT}/AppData/mesh/):
#   dex/config.yaml          rendered Dex config (re-rendered each run)
#   dex/dex.db               Dex sqlite store (clients, codes, refresh tokens, keys)
#
# RECOVERY / BACKUP: none of this needs backing up — it is all CACHE.
#   - The auth-registrar (mesh-auth) is STATELESS: its OIDC client-secret cache
#     lives inside the container (DEX_CLIENTS_DIR=/tmp/dex-clients), never on a
#     volume. On restart it transparently rotates each client's secret on the
#     next /register.
#   - dex.db is rebuilt automatically on loss. Apps re-register on their next
#     login (the AppShield sidecars hold no persisted creds), and users simply
#     log in again (Dex regenerates its signing keys, invalidating old tokens).
#     Deleting ${DATA_ROOT}/AppData/mesh/dex is therefore safe — this script
#     reconstructs config.yaml and the rest self-heals through normal logins.
#
# Dex is a pure BROKER: it holds no local credential. The local account lives in
# Authelia (see ensure-authelia.sh); the old enablePasswordDB break-glass admin
# is gone, along with the `casaos` connector and the BRIDGE_SECRET it consumed.
#
# NETWORK: Dex's gRPC client-management API is UNAUTHENTICATED, so the rendered
# config binds it to a static IP (172.31.7.2) on the isolated `dex-internal`
# docker network instead of 0.0.0.0. Only auth-registrar sits on that network;
# app containers (pcs network only) cannot reach gRPC. The IP is pinned in both
# docker-compose.yml and dex.config.yaml.tmpl — keep them in sync.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SELF_DIR/dex.config.yaml.tmpl"

DEX_ROOT="$MESH_ROOT/dex"
CONFIG_OUT="$DEX_ROOT/config.yaml"

# ghcr.io/dexidp/dex runs as uid/gid 1001 and must own its sqlite tree.
DEX_UID=1001

if [ ! -f "$TEMPLATE" ]; then
    log_error "Dex config template missing at $TEMPLATE"
    exit 1
fi

if [ -z "${DOMAIN:-}" ]; then
    log_error "DOMAIN not set in $ENV_FILE; cannot render Dex config"
    exit 1
fi

mkdir -p "$DEX_ROOT"

# Dex<->Authelia connector secret for the "Local Account" connector. Minted and
# hashed by ensure-authelia.sh, which runs immediately before this script, and
# persisted in .env. Empty is tolerated: the connector then renders with an empty
# secret and simply fails its back-channel until Authelia has provisioned, so a
# partial cycle never leaves Dex unable to start.
AUTHELIA_DEX_SECRET="$(get_env_value AUTHELIA_DEX_SECRET)"
if [ -z "$AUTHELIA_DEX_SECRET" ]; then
    log_warn "AUTHELIA_DEX_SECRET not set yet; Local Account connector will render without a secret until ensure-authelia.sh has run"
fi

# Render config.yaml. Pure-bash literal substitution (no envsubst/gettext host
# dependency). Replacement strings are inserted verbatim, so '$' sequences in a
# value are safe, and the template contains no other '$'.
CONTENT="$(cat "$TEMPLATE")"
CONTENT="${CONTENT//\$\{DOMAIN\}/$DOMAIN}"
CONTENT="${CONTENT//\$\{AUTHELIA_DEX_SECRET\}/$AUTHELIA_DEX_SECRET}"

TMP="$(mktemp "$DEX_ROOT/.config.XXXXXX")"
chmod 600 "$TMP"
printf '%s\n' "$CONTENT" > "$TMP"
mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"
echo "Rendered Dex config at $CONFIG_OUT"

# Perms: dex (uid 1001) owns its tree so it can create dex.db.
chown -R "$DEX_UID:$DEX_UID" "$DEX_ROOT" 2>/dev/null || true
chmod 755 "$DEX_ROOT" 2>/dev/null || true

# Pick up the re-rendered config if Dex is already running. A mounted-file change
# does not trigger a compose recreate, so an explicit restart is needed. Silent
# on cold boot when the container does not exist yet.
if docker inspect dex >/dev/null 2>&1; then
    docker restart dex >/dev/null 2>&1 || true
fi

echo "Dex provisioning complete (data root: $DEX_ROOT)"
