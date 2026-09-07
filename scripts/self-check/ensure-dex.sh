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
# Encrypts Dex's own session cookie (see the `sessions:` block in the template).
# Minted by ensure-dex-session-key.sh, which scripts-config.txt orders before
# this script. Empty is tolerated: Dex starts and sessions still work, the cookie
# is simply not encrypted — so a missing key degrades rather than breaking login.
DEX_SESSION_KEY="$(get_env_value DEX_SESSION_KEY)"
if [ -z "$DEX_SESSION_KEY" ]; then
    log_warn "DEX_SESSION_KEY not set yet; Dex session cookies will be unencrypted until ensure-dex-session-key.sh has run"
fi

# Literal substitution, NOT envsubst: this installer targets arbitrary boxes and
# must not require gettext. It is also the safer of the two here — the values
# below can carry '$' and pass through untouched.
CONTENT="$(cat "$TEMPLATE")"
CONTENT="${CONTENT//\$\{DOMAIN\}/$DOMAIN}"
CONTENT="${CONTENT//\$\{AUTHELIA_DEX_SECRET\}/$AUTHELIA_DEX_SECRET}"
CONTENT="${CONTENT//\$\{DEX_SESSION_KEY\}/$DEX_SESSION_KEY}"

TMP="$(mktemp "$DEX_ROOT/.config.XXXXXX")"
chmod 600 "$TMP"
printf '%s\n' "$CONTENT" > "$TMP"
mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"

# ---------------------------------------------------------------------------
# Connectors are APPENDED here, not declared in the template — the template's
# `connectors:` key is deliberately left empty. Everything below adds to it.
# ---------------------------------------------------------------------------
CONNECTOR_COUNT=0

# ---------------------------------------------------------------------------
# Local Account connector — Authelia — ONLY when the account is claimed.
#
# A fresh box seeds its owner account `disabled: true` (ensure-authelia.sh), and
# Authelia refuses a disabled user as "user not found" — so offering the button
# before onboarding shows a login that cannot possibly work. Claimed-ness is
# therefore the render condition, and it is read straight from the user store:
# at least one user that is not disabled.
#
# FAIL-OPEN on any doubt (yq missing, unreadable file, malformed YAML): render
# the connector. Guessing "unclaimed" on a box that is actually claimed would
# hide the owner's only door; guessing "claimed" on a fresh box merely restores
# the old cosmetic wart. The asymmetry is deliberate.
#
# Keep this predicate in sync with is_claimed() in tools/authelia-user-manager.sh.
# ---------------------------------------------------------------------------
USERS_DB="$MESH_ROOT/auth/users_database.yml"
LOCAL_ACCOUNT_CLAIMED=1
if [ -f "$USERS_DB" ] && command -v yq >/dev/null 2>&1; then
    if ENABLED="$(yq -e '[.users[] | select(.disabled != true)] | length' "$USERS_DB" 2>/dev/null)"; then
        [ "$ENABLED" -gt 0 ] 2>/dev/null || LOCAL_ACCOUNT_CLAIMED=0
    fi
fi

if [ "$LOCAL_ACCOUNT_CLAIMED" = "1" ]; then
    cat >> "$CONFIG_OUT" <<YAML
  # Local Account — Authelia, the box-local credential store. Publicly-trusted
  # host so Dex's back-channel TLS validates against system roots. Authelia's own
  # login page carries the password-reset link.
  - type: oidc
    id: authelia
    name: Local Account
    config:
      issuer: https://local-auth-${DOMAIN}
      clientID: dex
      clientSecret: "${AUTHELIA_DEX_SECRET}"
      # Dex's own connector callback.
      redirectURI: https://auth-${DOMAIN}/callback
      # Authelia 4.39 returns scope claims (preferred_username, email, name) from
      # its userinfo endpoint rather than in the ID token, so Dex must fetch it.
      getUserInfo: true
      userNameKey: preferred_username
      scopes:
        - openid
        - profile
        - email
YAML
    CONNECTOR_COUNT=$((CONNECTOR_COUNT + 1))
else
    log_info "Local account is unclaimed; omitting the Local Account connector until it is claimed"
fi

# ---------------------------------------------------------------------------
# Drop-in connectors — ${DATA_ROOT}/AppData/mesh/dex/connectors.d/*.yaml
#
# A generic extension point, deliberately shaped like Authelia's clients.d/*.yml:
# a deployment can federate Dex to something this template does not ship without
# the template knowing anything about it. Each file holds one or more items for
# the `connectors:` block, indented two spaces to match:
#
#     - type: oidc
#       id: example
#       name: Example
#       config:
#         issuer: https://example-${DOMAIN}
#         ...
#
# The directory lives in the runtime data dir, NOT the template tree, so
# ensure-template-sync.sh never touches it and a drop-in survives updates.
# Concatenated onto the freshly-rendered config, which is rewritten from scratch
# each run — so this never accumulates duplicates.
#
# ${DOMAIN} is the only token expanded, letting a drop-in reference the box's
# domain without knowing it at write time. Anything else ($-bearing secrets in
# particular) passes through verbatim.
#
# NOT VALIDATED, deliberately — this runs before Dex sees the file, and a schema
# check here would be a second, drifting copy of Dex's own.
#
# THE COST IS HIGH, so read this before adding one. Dex resolves every oidc
# connector's discovery document AT STARTUP and treats a failure as fatal:
#
#   failed to initialize server: server: Failed to open connector demo:
#   failed to get provider: 502 Bad Gateway
#
# and the process exits. A drop-in pointing at an issuer that is down, slow to
# boot, or not yet routed by Caddy therefore takes down ALL interactive login on
# this box — every other connector included, not just itself. Whatever writes a
# drop-in must confirm the issuer answers over its public URL first, and must
# REMOVE its file rather than leave a stale one behind when it cannot.
# A malformed drop-in does the same thing via a YAML parse error.
#
# Two more rules: keep the shape above, and never reuse a connector id that is
# already taken — `authelia` is rendered above, and Dex rejects duplicate ids at
# startup.
# ---------------------------------------------------------------------------
CONNECTORS_D="$DEX_ROOT/connectors.d"
mkdir -p "$CONNECTORS_D"
shopt -s nullglob
for dropin in "$CONNECTORS_D"/*.yaml "$CONNECTORS_D"/*.yml; do
    DROPIN_CONTENT="$(cat "$dropin")"
    DROPIN_CONTENT="${DROPIN_CONTENT//\$\{DOMAIN\}/$DOMAIN}"
    printf '\n%s\n' "$DROPIN_CONTENT" >> "$CONFIG_OUT"
    CONNECTOR_COUNT=$((CONNECTOR_COUNT + 1))
    log_info "Added drop-in Dex connector from $(basename "$dropin")"
done
shopt -u nullglob

echo "Rendered Dex config at $CONFIG_OUT ($CONNECTOR_COUNT connector(s))"

# ---------------------------------------------------------------------------
# Never-empty check.
#
# Not a gate — the config is already written and Dex starts fine with an empty
# connector list. This exists so the state is OBVIOUS in the log instead of being
# reverse-engineered from a login page with no buttons.
# ---------------------------------------------------------------------------
if [ "$CONNECTOR_COUNT" -eq 0 ]; then
    log_warn "Dex rendered with NO connectors — interactive login is impossible on this box."
    log_warn "  Cause: the local account is unclaimed and no drop-in connector is present."
    log_warn "  Fix over SSH: $SCRIPTS_DIR/tools/authelia-user-manager.sh claim <username>"
fi

# Perms: dex (uid 1001) owns its tree so it can create dex.db.
# NOTE this covers $DEX_ROOT only, not the sibling dex-frontend/ — those files
# are bind-mounted :ro and read as world-readable, so they need no ownership.
chown -R "$DEX_UID:$DEX_UID" "$DEX_ROOT" 2>/dev/null || true
chmod 755 "$DEX_ROOT" 2>/dev/null || true

# Provision the custom login frontend into the dir the compose file bind-mounts
# over the stock image. Copied every run so template updates propagate.
#
# The logic lives in tools/provision-dex-frontend.sh because it is NOT exclusive
# to this script: ensure-stack-up.sh runs it too, since a `docker compose up`
# that happens before these files exist makes Docker create the file bind-mount
# sources as DIRECTORIES and permanently breaks `dex`. See that tool's header.
"$SCRIPTS_DIR/tools/provision-dex-frontend.sh" \
    || log_warn "Dex frontend provisioning reported an error"

# Pick up the re-rendered config if Dex is already running. A mounted-file change
# does not trigger a compose recreate, so an explicit restart is needed. Silent
# on cold boot when the container does not exist yet.
if docker inspect dex >/dev/null 2>&1; then
    docker restart dex >/dev/null 2>&1 || true
fi

echo "Dex provisioning complete (data root: $DEX_ROOT)"
