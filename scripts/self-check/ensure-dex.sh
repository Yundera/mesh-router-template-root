#!/bin/bash
# ensure-dex.sh - Provision the Dex OIDC broker (the PCS SSO identity provider).
#
# Responsibilities (all idempotent):
#   - render Dex config.yaml from the template every run (tracks DOMAIN changes
#     and re-emits the connector secret / break-glass hash),
#   - generate the Dex<->bridge connector shared secret once (BRIDGE_SECRET, in
#     .env so docker compose interpolates it for the bridge's CLIENT_SECRET),
#   - seed a disposable break-glass admin (random password, bcrypt-hashed),
#   - own the sqlite data dir so the dex container (uid 1001) can write dex.db,
#   - restart dex so a re-rendered config is picked up.
#
# Storage layout (host ${DATA_ROOT}/AppData/mesh/):
#   dex/config.yaml          rendered Dex config (re-rendered each run)
#   dex/dex.db               Dex sqlite store (clients, codes, refresh tokens, keys)
#   dex/admin-password       plaintext break-glass admin password (chmod 600)
#   dex/admin-hash           bcrypt of the above (generate-once; reused on render)
#   casaos-oidc-bridge/signing-key.json  bridge token-signing key (bridge-owned)
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
#     reconstructs config.yaml and the break-glass admin, and the rest self-heals
#     through normal logins.
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
BRIDGE_ROOT="$MESH_ROOT/casaos-oidc-bridge"
CONFIG_OUT="$DEX_ROOT/config.yaml"
ADMIN_PWD_FILE="$DEX_ROOT/admin-password"
ADMIN_HASH_FILE="$DEX_ROOT/admin-hash"

# ghcr.io/dexidp/dex runs as uid/gid 1001 and must own its sqlite tree.
DEX_UID=1001
# Image used only to bcrypt the break-glass admin password (Dex ships no hash
# CLI, and we avoid installing host packages). Pulled once; the hash is cached.
HTPASSWD_IMAGE="httpd:2.4-alpine"

if [ ! -f "$TEMPLATE" ]; then
    log_error "Dex config template missing at $TEMPLATE"
    exit 1
fi

if [ -z "${DOMAIN:-}" ]; then
    log_error "DOMAIN not set in $ENV_FILE; cannot render Dex config"
    exit 1
fi

mkdir -p "$DEX_ROOT" "$BRIDGE_ROOT"

# Operator email for the break-glass admin (recovery path). Falls back to an
# unrouted vanity address when EMAIL is not set yet.
ADMIN_EMAIL="${EMAIL:-}"
if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${DOMAIN}"
    log_warn "EMAIL not set in $ENV_FILE; using ${ADMIN_EMAIL} for the Dex admin"
fi

# Dex<->bridge connector shared secret. Generated once and persisted in .env so
# docker compose interpolates it for BOTH the bridge's CLIENT_SECRET and the
# casaos connector's clientSecret below. This script runs before the stack-up
# steps, so the value is present in .env by the time `docker compose up` reads it.
BRIDGE_SECRET="$(get_env_value BRIDGE_SECRET)"
if [ -z "$BRIDGE_SECRET" ]; then
    BRIDGE_SECRET="$(openssl rand -hex 32)"
    set_env_value BRIDGE_SECRET "$BRIDGE_SECRET"
    echo "Generated BRIDGE_SECRET (Dex<->bridge connector secret)"
fi

# Disposable break-glass admin password (random). Generate-once: presence of the
# file is the marker. Rotate by deleting it (and admin-hash) and re-running.
if [ ! -f "$ADMIN_PWD_FILE" ]; then
    openssl rand -hex 12 > "$ADMIN_PWD_FILE"
    chmod 600 "$ADMIN_PWD_FILE"
    rm -f "$ADMIN_HASH_FILE"   # force a fresh hash for the new password
    echo "Generated disposable Dex break-glass admin password ($ADMIN_PWD_FILE)"
fi
ADMIN_PWD="$(cat "$ADMIN_PWD_FILE")"

# bcrypt the admin password, generate-once (cached in admin-hash). htpasswd emits
# a $2y$ identifier; Go's bcrypt (used by Dex) only accepts $2a$/$2b$, so swap
# the identifier — the algorithm is identical, only the version byte differs.
if [ ! -f "$ADMIN_HASH_FILE" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker unavailable; cannot bcrypt the Dex break-glass admin password"
        exit 1
    fi
    RAW_HASH="$(docker run --rm "$HTPASSWD_IMAGE" htpasswd -bnBC 10 "" "$ADMIN_PWD" | tr -d ':\n')"
    RAW_HASH="${RAW_HASH/\$2y\$/\$2a\$}"
    if [ -z "$RAW_HASH" ]; then
        log_error "Failed to bcrypt the Dex admin password (htpasswd produced no output)"
        exit 1
    fi
    printf '%s' "$RAW_HASH" > "$ADMIN_HASH_FILE"
    chmod 600 "$ADMIN_HASH_FILE"
fi
ADMIN_HASH="$(cat "$ADMIN_HASH_FILE")"

# Render config.yaml. Pure-bash literal substitution (no envsubst/gettext host
# dependency). The replacement strings are inserted verbatim — so the bcrypt
# hash's '$' sequences are safe — and the template contains no other '$'.
CONTENT="$(cat "$TEMPLATE")"
CONTENT="${CONTENT//\$\{DOMAIN\}/$DOMAIN}"
CONTENT="${CONTENT//\$\{ADMIN_EMAIL\}/$ADMIN_EMAIL}"
CONTENT="${CONTENT//\$\{BRIDGE_SECRET\}/$BRIDGE_SECRET}"
CONTENT="${CONTENT//__ADMIN_HASH__/$ADMIN_HASH}"

TMP="$(mktemp "$DEX_ROOT/.config.XXXXXX")"
chmod 600 "$TMP"
printf '%s\n' "$CONTENT" > "$TMP"
mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"
echo "Rendered Dex config at $CONFIG_OUT"

# Perms: dex (uid 1001) owns its tree so it can create dex.db.
chown -R "$DEX_UID:$DEX_UID" "$DEX_ROOT" 2>/dev/null || true
chmod 755 "$DEX_ROOT" 2>/dev/null || true
# The bridge persists its signing key here; let it write regardless of its uid.
chmod 777 "$BRIDGE_ROOT" 2>/dev/null || true

# Pick up the re-rendered config if Dex is already running. A mounted-file change
# does not trigger a compose recreate, so an explicit restart is needed. Silent
# on cold boot when the container does not exist yet.
if docker inspect dex >/dev/null 2>&1; then
    docker restart dex >/dev/null 2>&1 || true
fi

echo "Dex provisioning complete (data root: $DEX_ROOT)"
