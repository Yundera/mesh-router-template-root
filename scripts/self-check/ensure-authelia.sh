#!/bin/bash
# ensure-authelia.sh - Provision Authelia as the PCS local-account IdP.
#
# Authelia sits BEHIND Dex as a single OIDC connector (the "Local Account" login),
# owning the credential that used to live in CasaOS. It has exactly one OIDC
# client — Dex — so there is no dynamic client registration here (that stays on
# Dex's gRPC path via auth-registrar).
#
# Responsibilities (all idempotent):
#   - generate-once the session/storage/reset/oidc-hmac secrets + RSA JWKS key,
#   - generate-once the Dex<->Authelia client secret (AUTHELIA_DEX_SECRET):
#     plaintext into .env (Dex reads it to render its connector), pbkdf2 hash
#     cached for Authelia's client config,
#   - render configuration.yml every run (tracks DOMAIN),
#   - seed the admin user in users_database.yml from DEFAULT_PWD, refreshing only
#     the email on later runs (Authelia owns the password once the user changes it),
#   - restart authelia so a re-rendered config is picked up.
#
# MUST RUN BEFORE ensure-dex.sh — it mints AUTHELIA_DEX_SECRET, which the same
# cycle's Dex render interpolates into the Local Account connector.
#
# Storage layout (host ${DATA_ROOT}/AppData/mesh/auth/, mounted at /config):
#   secrets/{session,storage,reset,oidc-hmac}  generate-once (chmod 600)
#   secrets/dex-client-hash                    pbkdf2 hash of AUTHELIA_DEX_SECRET
#   oidc/private.pem                           RSA-4096 JWKS signing key
#   configuration.yml                          rendered each run
#   users_database.yml                         file user store (Authelia owns it after seed)
#   db.sqlite                                  session/regulation store
#
# RECOVERY: unlike the dex dir this holds the local account and IS worth keeping.
# Losing it resets the local password to DEFAULT_PWD on the next run (and the
# email reset flow still works), so it is not a dead end — but back it up.
#
# Ported from Yundera/template-root, with envsubst replaced by pure-bash
# substitution: this installer targets arbitrary boxes and must not require
# gettext. See doc/alignment-with-template-root.md.
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

AUTH_ROOT="$MESH_ROOT/auth"
SECRETS_DIR="$AUTH_ROOT/secrets"
OIDC_DIR="$AUTH_ROOT/oidc"

# Resolve the config template from THIS SCRIPT'S OWN TREE first, falling back to
# the synced template/ directory.
#
# Both paths are needed and neither alone is enough. ensure-template-sync
# propagates only compose/Caddyfile/scripts, so in the LIVE layout there is no
# auth/ beside scripts/ and template/ is the only copy. But when this script is
# invoked by a MIGRATION it runs from the freshly extracted tree, before that tree
# has been swapped into template/ — so template/ still holds the OLD version,
# which on an upgrade has no auth/ at all. That is not hypothetical: it is exactly
# how the phase-1+2 rollout first failed. ensure-authelia.sh bailed with "config
# template missing", ensure-dex.sh then rendered the connector with an EMPTY
# clientSecret, and because ensure-dex.sh is an existing scripts-config entry it
# never re-ran in pass 2 to pick up the secret. Login got as far as Authelia and
# died at Dex's token exchange with `invalid_client`.
SELF_TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$SELF_TREE/auth/configuration.yml.tmpl"
[ -f "$TEMPLATE" ] || TEMPLATE="$TEMPLATE_DIR/auth/configuration.yml.tmpl"
CONFIG_OUT="$AUTH_ROOT/configuration.yml"
USERS_DB="$AUTH_ROOT/users_database.yml"
DEX_HASH_FILE="$SECRETS_DIR/dex-client-hash"

# One image for both hashes: argon2 (user password) + pbkdf2 (client secret).
AUTHELIA_IMAGE="authelia/authelia:4.39"

if [ ! -f "$TEMPLATE" ]; then
    log_error "Authelia config template missing at $TEMPLATE"
    exit 1
fi
if [ -z "${DOMAIN:-}" ]; then
    log_error "DOMAIN not set in $ENV_FILE; cannot render Authelia config"
    exit 1
fi

mkdir -p "$SECRETS_DIR" "$OIDC_DIR"
chmod 700 "$SECRETS_DIR"

# --- generate-once secrets ---------------------------------------------------
for name in session storage reset oidc-hmac; do
    if [ ! -f "$SECRETS_DIR/$name" ]; then
        openssl rand -hex 32 > "$SECRETS_DIR/$name"
        chmod 600 "$SECRETS_DIR/$name"
        echo "Generated Authelia secret: $name"
    fi
done

if [ ! -f "$OIDC_DIR/private.pem" ]; then
    openssl genrsa -out "$OIDC_DIR/private.pem" 4096 2>/dev/null
    chmod 600 "$OIDC_DIR/private.pem"
    echo "Generated Authelia OIDC JWKS keypair"
fi

# --- Dex<->Authelia client secret -------------------------------------------
# Generate-once. Dex (the client) needs the PLAINTEXT; Authelia (the provider)
# stores only a pbkdf2 hash. The plaintext lives in .env so docker compose can
# interpolate it and ensure-dex.sh — which runs right after — can render the
# connector in the SAME cycle.
AUTHELIA_DEX_SECRET="$(get_env_value AUTHELIA_DEX_SECRET)"
SECRET_JUST_MINTED=0
if [ -z "$AUTHELIA_DEX_SECRET" ]; then
    AUTHELIA_DEX_SECRET="$(openssl rand -hex 32)"
    set_env_value AUTHELIA_DEX_SECRET "$AUTHELIA_DEX_SECRET"
    rm -f "$DEX_HASH_FILE"   # force a fresh hash for the new secret
    SECRET_JUST_MINTED=1
    echo "Generated AUTHELIA_DEX_SECRET (Dex<->Authelia connector secret)"
fi

if [ ! -f "$DEX_HASH_FILE" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker unavailable; cannot pbkdf2-hash AUTHELIA_DEX_SECRET"
        exit 1
    fi
    DEX_SECRET_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate pbkdf2 --password "$AUTHELIA_DEX_SECRET" 2>/dev/null \
        | awk '/^Digest:/{print $2}')"
    if [ -z "$DEX_SECRET_HASH" ]; then
        log_error "Failed to pbkdf2-hash AUTHELIA_DEX_SECRET via $AUTHELIA_IMAGE"
        exit 1
    fi
    printf '%s' "$DEX_SECRET_HASH" > "$DEX_HASH_FILE"
    chmod 600 "$DEX_HASH_FILE"
fi
DEX_SECRET_HASH="$(cat "$DEX_HASH_FILE")"

# --- render configuration.yml ------------------------------------------------
# Base via pure-bash literal substitution (${DOMAIN} only), then append the
# always-present single-client OIDC block. The pbkdf2 hash and the PEM hold '$'
# sequences, so they are injected as bash variable values inside the heredoc —
# never through a substitution pass.
TMP="$(mktemp)"
chmod 600 "$TMP"
CONTENT="$(cat "$TEMPLATE")"
CONTENT="${CONTENT//\$\{DOMAIN\}/$DOMAIN}"
printf '%s\n' "$CONTENT" > "$TMP"

HMAC="$(cat "$SECRETS_DIR/oidc-hmac")"
JWKS_KEY="$(sed 's/^/          /' "$OIDC_DIR/private.pem")"
cat >> "$TMP" <<EOF

identity_providers:
  oidc:
    hmac_secret: '${HMAC}'
    jwks:
      - key_id: 'pcs'
        algorithm: 'RS256'
        use: 'sig'
        key: |
${JWKS_KEY}
    clients:
      - client_id: 'dex'
        client_name: 'Dex (PCS SSO broker)'
        client_secret: '${DEX_SECRET_HASH}'
        public: false
        authorization_policy: 'one_factor'
        # Dex is a trusted first-party broker running its own skipApprovalScreen,
        # so never show Authelia's consent screen for it.
        consent_mode: 'implicit'
        redirect_uris:
          - 'https://auth-${DOMAIN}/callback'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        userinfo_signed_response_alg: 'none'
        token_endpoint_auth_method: 'client_secret_basic'
EOF

mv "$TMP" "$CONFIG_OUT"
chmod 600 "$CONFIG_OUT"
echo "Rendered Authelia config at $CONFIG_OUT"

# --- seed / refresh the admin user ------------------------------------------
# The operator email is the password-reset recovery address, so it must track
# EMAIL even after the initial seed.
ADMIN_EMAIL="${EMAIL:-}"
if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${DOMAIN}"
    log_warn "EMAIL not set in $ENV_FILE; falling back to ${ADMIN_EMAIL}"
fi

if [ -f "$USERS_DB" ] && grep -q "^[[:space:]]*password:" "$USERS_DB"; then
    # Already seeded (by us, or by Authelia writing a password change back).
    # Refresh only the email line — never touch the password.
    TMP="$(mktemp)"
    awk -v new="$ADMIN_EMAIL" '
        /^[[:space:]]+email:/ {
            match($0, /^[[:space:]]+/)
            print substr($0, 1, RLENGTH) "email: \"" new "\""
            next
        }
        { print }
    ' "$USERS_DB" > "$TMP"
    if cmp -s "$TMP" "$USERS_DB"; then
        rm -f "$TMP"
        echo "users_database.yml already seeded; admin email already ${ADMIN_EMAIL}"
    else
        chmod 600 "$TMP"
        mv "$TMP" "$USERS_DB"
        echo "users_database.yml already seeded; refreshed admin email to ${ADMIN_EMAIL}"
    fi
else
    # Fixed username 'admin' regardless of anything else: one well-known local
    # login avoids confusion.
    AUTHELIA_ADMIN="admin"
    ADMIN_PWD="$(get_env_value DEFAULT_PWD)"
    if [ -z "$ADMIN_PWD" ]; then
        log_error "DEFAULT_PWD not set in $ENV_FILE; cannot seed the Authelia admin"
        exit 1
    fi

    ADMIN_HASH="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate argon2 --password "$ADMIN_PWD" 2>/dev/null \
        | awk '/^Digest:/{print $2}')"
    if [ -z "$ADMIN_HASH" ]; then
        log_error "Failed to argon2-hash the admin password via $AUTHELIA_IMAGE"
        exit 1
    fi

    TMP="$(mktemp)"
    cat > "$TMP" <<EOF
users:
  ${AUTHELIA_ADMIN}:
    displayname: "Administrator"
    password: "${ADMIN_HASH}"
    email: "${ADMIN_EMAIL}"
    groups:
      - admins
EOF
    chmod 600 "$TMP"
    mv "$TMP" "$USERS_DB"
    echo "Seeded Authelia admin user: ${AUTHELIA_ADMIN} (password: DEFAULT_PWD)"
fi

# Pick up the re-rendered config. SIGHUP is NOT safe (Authelia 4.39 exits on it);
# docker restart is a clean SIGTERM + start. Silent on cold boot.
if docker inspect authelia >/dev/null 2>&1; then
    docker restart authelia >/dev/null 2>&1 || true
fi

# If the secret was minted just now, Dex's config was rendered without it —
# either earlier in this same cycle (ensure-dex.sh sits ahead of this script in
# scripts-config.txt on the release that introduces Authelia) or on some previous
# run. Re-render immediately rather than leaving a broken connector until the next
# cycle: Dex would accept the login at Authelia and then fail its token exchange
# with `invalid_client`, which is a confusing way to find out.
if [ "$SECRET_JUST_MINTED" -eq 1 ] && [ -f "$SELF_TREE/scripts/self-check/ensure-dex.sh" ]; then
    echo "Secret is new; re-rendering Dex so the connector picks it up"
    bash "$SELF_TREE/scripts/self-check/ensure-dex.sh" || \
        log_warn "Dex re-render failed; the next self-check cycle will retry"
fi

echo "Authelia provisioning complete (data root: $AUTH_ROOT)"
