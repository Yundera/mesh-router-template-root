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
#     plaintext into the auth stack's .stack.env (the connector is rendered from
#     it), pbkdf2 hash
#     cached for Authelia's client config,
#   - render configuration.yml every run (tracks DOMAIN),
#   - seed the admin user in users_database.yml from DEFAULT_PWD, refreshing only
#     the email on later runs (Authelia owns the password once the user changes it),
#   - restart authelia ONLY when something it reads at startup changed (the
#     rendered config, a freshly generated secret or key), and WAIT for it to
#     serve again — mesh-router-caddy's route included — before returning
#     (ensure-dex.sh restarts Dex moments later),
#   - write or remove Authelia's Dex connector, the "Local Account" drop-in
#     (dex/connectors.d/authelia.yaml) — see write_local_account_connector.
#
# MUST RUN BEFORE ensure-dex.sh, which appends that drop-in to Dex's config.
#
# --connector-only: only the connector step. For callers that change claimed-ness
# outside a self-check run — `authelia-user-manager.sh claim`, an onboarding
# reset — and then run ensure-dex.sh: the full run's hashing and Authelia restart
# have nothing to do there.
#
# Storage layout (host ${DATA_ROOT}/AppData/auth/authelia/, mounted at /config —
# the auth stack's own folder; adopt_auth_state moves it there from the mesh root
# on a box that predates the move):
#   secrets/{session,storage,reset,oidc-hmac}  generate-once (chmod 600)
#   secrets/dex-client-hash                    pbkdf2 hash of AUTHELIA_DEX_SECRET
#   oidc/private.pem                           RSA-4096 JWKS signing key
#   configuration.yml                          rendered each run
#   users_database.yml                         file user store (Authelia owns it after seed)
#   db.sqlite                                  session/regulation store
#
# RECOVERY: unlike the dex dir this holds the local account and IS worth keeping.
# Losing it drops the box back to UNCLAIMED on the next run — the owner re-claims
# over SSH (tools/authelia-user-manager.sh claim), so it is not a dead end — but
# back it up.
#
# Ported from Yundera/template-root, with envsubst replaced by pure-bash
# substitution: this installer targets arbitrary boxes and must not require
# gettext. See doc/alignment-with-template-root.md.
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/authelia-ready.sh"

# Fatal: rendering into an empty folder while the real state still sits at the
# pre-move path would seed a second, unclaimed user store. The migration normally
# did this already; see adopt_auth_state for why it is repeated here.
adopt_auth_state

# AUTHELIA_DEX_SECRET is the auth stack's own state, in $AUTH_STACK_ENV: moved there
# from the mesh .env on a box that predates it, before either path below reads it.
stack_env_adopt "$ENV_FILE" "$AUTH_STACK_ENV" AUTHELIA_DEX_SECRET

AUTH_ROOT="$AUTHELIA_HOME"
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
# Same tag as the authelia service in docker-compose.yml — see the note there on
# why that pin may only ever go up.
AUTHELIA_IMAGE="authelia/authelia:4.39.25"

# --- hashing helper ----------------------------------------------------------
# Every hash on this box is produced by `docker run`-ing the authelia image, and
# that is the ONLY Docker Hub pull in the whole install. A single transient
# failure there — rate limit, DNS blip, registry 5xx — surfaces as `docker run`
# exiting 125 and, unretried, takes down the entire provision: no client hash
# means no Authelia config, which means no interactive login on the box at all.
# That is not hypothetical; it destroyed a provision upstream on 2026-09-03.
#
# So: bounded retry with exponential backoff, and stderr KEPT rather than sent to
# /dev/null — the old one-shot form swallowed the reason, leaving only "Failed to
# hash" in the log with no way to tell a rate limit from a bad argument.
#
# Result lands in AUTHELIA_HASH_RESULT (a global) rather than on stdout, so the
# caller can distinguish "no digest" from "command failed".
HASH_MAX_ATTEMPTS=5
AUTHELIA_HASH_RESULT=""
authelia_hash() {
    # usage: authelia_hash <argon2|pbkdf2> [extra args...]
    local algo="$1"; shift
    local attempt=1 delay=2 out err errfile rc

    AUTHELIA_HASH_RESULT=""
    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker unavailable; cannot hash with $AUTHELIA_IMAGE"
        return 1
    fi

    errfile="$(mktemp)"
    while [ "$attempt" -le "$HASH_MAX_ATTEMPTS" ]; do
        # The digest is parsed from stdout ONLY. When the image is not cached yet,
        # `docker run` pulls it and prints its own "Digest: sha256:…" line on
        # stderr; merged in, that line was taken as a second digest and the stored
        # hash became two lines no secret could match. stderr is kept apart so a
        # registry error is still reported instead of lost.
        if out="$(docker run --rm "$AUTHELIA_IMAGE" \
                    authelia crypto hash generate "$algo" "$@" 2>"$errfile")"; then
            AUTHELIA_HASH_RESULT="$(printf '%s\n' "$out" | awk '/^Digest:/{print $2}')"
            if [ -n "$AUTHELIA_HASH_RESULT" ]; then
                rm -f "$errfile"
                return 0
            fi
            # Ran but produced no digest — an argument problem, not a transient
            # one. Retrying cannot help.
            log_error "authelia crypto hash generate $algo produced no digest: $out $(cat "$errfile")"
            rm -f "$errfile"
            return 1
        fi
        rc=$?
        err="$(cat "$errfile")"
        log_warn "authelia hash attempt ${attempt}/${HASH_MAX_ATTEMPTS} failed (exit $rc): $out $err"
        [ "$attempt" -lt "$HASH_MAX_ATTEMPTS" ] && sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
    rm -f "$errfile"
    return 1
}

# --- the Local Account connector ---------------------------------------------
# Authelia's Dex connector, as a drop-in: ${DATA_ROOT}/AppData/auth/dex/connectors.d/authelia.yaml.
# ensure-dex.sh knows no connector — it renders the base config, appends whatever
# is in connectors.d/, and keeps Dex absent while there is nothing to append (see
# dex_wanted, library/common.sh). A deployment adds its own the same way
# (Yundera: ensure-connector-yundera.sh).
#
# ONLY WHEN THE ACCOUNT IS CLAIMED. A fresh box seeds its owner account
# `disabled: true` (below), and Authelia refuses a disabled user as "user not
# found" — so offering the button before onboarding shows a login that cannot
# possibly work. Claimed-ness is read straight from the user store: at least one
# user that is not disabled. Unclaimed, the file is REMOVED.
#
# FAIL-OPEN on any doubt (yq missing, unreadable file, malformed YAML): write the
# connector. Guessing "unclaimed" on a box that is actually claimed would hide the
# owner's only door; guessing "claimed" on a fresh box merely shows a button that
# does not work yet. The asymmetry is deliberate.
#
# Keep the predicate in sync with is_claimed() in tools/authelia-user-manager.sh
# (and Yundera/template-root tools/onboarding.sh).
#
# The file carries the connector's client secret (AUTHELIA_DEX_SECRET), so it is
# 0600; ensure-dex.sh hands the whole Dex tree to uid 1001.
write_local_account_connector() {
    local CONNECTORS_D DROPIN TMP AUTHELIA_DEX_SECRET DOMAIN PROBE_RC
    CONNECTORS_D="$DEX_HOME/connectors.d"
    DROPIN="$CONNECTORS_D/authelia.yaml"
    mkdir -p "$CONNECTORS_D"

    local CLAIMED=1 ENABLED=""
    if [ -f "$USERS_DB" ] && command -v yq >/dev/null 2>&1; then
        if ENABLED="$(yq -e '[.users[] | select(.disabled != true)] | length' "$USERS_DB" 2>/dev/null)"; then
            [ "$ENABLED" -gt 0 ] 2>/dev/null || CLAIMED=0
        fi
    fi

    if [ "$CLAIMED" != "1" ]; then
        if [ -f "$DROPIN" ]; then
            rm -f "$DROPIN"
            log_info "Local account is unclaimed; removed the Local Account connector"
        else
            log_info "Local account is unclaimed; no Local Account connector until it is claimed"
        fi
        return 0
    fi

    # Empty is tolerated: the connector then renders with an empty secret and fails
    # its back-channel until Authelia has provisioned, rather than leaving the owner
    # with no button at all.
    AUTHELIA_DEX_SECRET="$(get_stack_env_value AUTHELIA_DEX_SECRET "$AUTH_STACK_ENV")"
    if [ -z "$AUTHELIA_DEX_SECRET" ]; then
        log_warn "AUTHELIA_DEX_SECRET not set yet; Local Account connector written without a secret until a full ensure-authelia.sh run mints it"
    fi

    # ${DOMAIN} is left as a token: ensure-dex.sh expands it in every drop-in, so a
    # domain change needs no rewrite here. The secret is hex (openssl rand -hex), so
    # writing it verbatim is safe.
    TMP="$(mktemp "$CONNECTORS_D/.authelia.XXXXXX")"
    chmod 600 "$TMP"
    cat > "$TMP" <<YAML
  # Local Account — Authelia, the box-local credential store. Written by
  # ensure-authelia.sh; edits here are overwritten.
  # Publicly-trusted host so Dex's back-channel TLS validates against system
  # roots. Authelia's own login page carries the password-reset link.
  - type: oidc
    id: authelia
    name: Local Account
    config:
      issuer: https://local-auth-\${DOMAIN}
      clientID: dex
      clientSecret: "${AUTHELIA_DEX_SECRET}"
      # Dex's own connector callback.
      redirectURI: https://auth-\${DOMAIN}/callback
      # Authelia 4.39 returns scope claims (preferred_username, email, name) from
      # its userinfo endpoint rather than in the ID token, so Dex must fetch it.
      getUserInfo: true
      userNameKey: preferred_username
      # Forward Authelia's groups (users_database.yml) to the apps — an AppShield
      # gate with OIDC_REQUIRED_GROUPS (mesh-console: admins) sees no groups and
      # refuses everyone without both of these. "insecure" is about staleness, not
      # exposure: groups refresh only when the user logs in again.
      insecureEnableGroups: true
      scopes:
        - openid
        - profile
        - email
        - groups
YAML

    if cmp -s "$TMP" "$DROPIN"; then
        rm -f "$TMP"
    else
        mv "$TMP" "$DROPIN"
        log_info "Wrote the Local Account connector ($DROPIN)"
    fi

    # Check the path Dex will take to open that connector (local_auth_discovery_ok,
    # library/authelia-ready.sh), and say so when it is broken.
    #
    # A WARNING ONLY — the connector is written either way. Local Account is usually
    # this box's ONLY connector, so omitting it would trade a login that may not work
    # for no login at all. Skipped when Authelia is not running yet (cold boot). After
    # a restart, wait_for_authelia has already waited for this same route.
    DOMAIN="$(get_env_value DOMAIN)"
    if [ "$(docker inspect -f '{{.State.Running}}' authelia 2>/dev/null)" = "true" ]; then
        PROBE_RC=0
        for _ in 1 2 3; do
            PROBE_RC=0
            local_auth_discovery_ok || PROBE_RC=$?
            [ "$PROBE_RC" -eq 1 ] || break
            sleep 3
        done
        if [ "$PROBE_RC" -eq 1 ]; then
            log_warn "local-auth-$DOMAIN did not return a discovery document over the on-box path (127.0.0.1:443, mesh CA)"
            log_warn "  Dex may fail to open the Local Account connector. Check that authelia is up and that"
            log_warn "  mesh-router-caddy serves local-auth-$DOMAIN with the mesh certificate."
        elif [ "$PROBE_RC" -eq 2 ] && [ -z "$(local_auth_ca)" ]; then
            log_warn "The mesh CA is not under $MESH_ROOT/data yet; Dex cannot verify local-auth-$DOMAIN on the box until mesh-router-agent writes it"
        fi
    fi
}

if [ "${1:-}" = "--connector-only" ]; then
    write_local_account_connector
    exit 0
fi

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

# Set when something Authelia reads only at startup changed in this run: the
# rendered configuration.yml (which embeds the client hash and the JWKS key), or a
# secret file it loads through *_FILE. users_database.yml is NOT among them —
# Authelia watches it (`watch: true`), so an email refresh or a claim needs no
# restart. See the restart block at the end for why this matters.
AUTHELIA_RESTART_NEEDED=0

# --- generate-once secrets ---------------------------------------------------
for name in session storage reset oidc-hmac; do
    if [ ! -f "$SECRETS_DIR/$name" ]; then
        openssl rand -hex 32 > "$SECRETS_DIR/$name"
        chmod 600 "$SECRETS_DIR/$name"
        AUTHELIA_RESTART_NEEDED=1
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
# stores only a pbkdf2 hash. The plaintext lives in the auth stack's .stack.env so
# write_local_account_connector (and ensure-dex.sh, which runs right after) can
# render the connector in the SAME cycle. No compose file interpolates it.
AUTHELIA_DEX_SECRET="$(get_stack_env_value AUTHELIA_DEX_SECRET "$AUTH_STACK_ENV")"
SECRET_JUST_MINTED=0
if [ -z "$AUTHELIA_DEX_SECRET" ]; then
    AUTHELIA_DEX_SECRET="$(openssl rand -hex 32)"
    stack_env_set AUTHELIA_DEX_SECRET "$AUTHELIA_DEX_SECRET" "$AUTH_STACK_ENV"
    rm -f "$DEX_HASH_FILE"   # force a fresh hash for the new secret
    SECRET_JUST_MINTED=1
    echo "Generated AUTHELIA_DEX_SECRET (Dex<->Authelia connector secret)"
fi

if [ ! -f "$DEX_HASH_FILE" ]; then
    if ! authelia_hash pbkdf2 --password "$AUTHELIA_DEX_SECRET"; then
        log_error "Failed to pbkdf2-hash AUTHELIA_DEX_SECRET via $AUTHELIA_IMAGE after $HASH_MAX_ATTEMPTS attempts"
        exit 1
    fi
    DEX_SECRET_HASH="$AUTHELIA_HASH_RESULT"
    printf '%s' "$DEX_SECRET_HASH" > "$DEX_HASH_FILE"
    chmod 600 "$DEX_HASH_FILE"
fi
DEX_SECRET_HASH="$(cat "$DEX_HASH_FILE")"

# --- render configuration.yml ------------------------------------------------
# BRANDING. BRAND_NAME in .env names the product on the two places Authelia shows
# one: the TOTP issuer (what an authenticator app lists the account under) and
# the password-reset mail (sender name and subject tag). Unset, the box names
# itself by its domain, which is both vendor-neutral and the anti-phishing cue.
# Single quotes are doubled because the template puts these inside '...' YAML.
BRAND="${BRAND_NAME:-}"
_SQ="'"
BRAND="${BRAND//$_SQ/$_SQ$_SQ}"
TOTP_ISSUER="${BRAND:-$DOMAIN}"
MAIL_SENDER_NAME="${BRAND:-PCS}"
MAIL_SUBJECT_TAG="${BRAND:-$DOMAIN}"

# Base via pure-bash literal substitution (a fixed token list), then append the
# always-present single-client OIDC block. The pbkdf2 hash and the PEM hold '$'
# sequences, so they are injected as bash variable values inside the heredoc —
# never through a substitution pass.
TMP="$(mktemp)"
chmod 600 "$TMP"
CONTENT="$(cat "$TEMPLATE")"
CONTENT="${CONTENT//\$\{DOMAIN\}/$DOMAIN}"
CONTENT="${CONTENT//\$\{TOTP_ISSUER\}/$TOTP_ISSUER}"
CONTENT="${CONTENT//\$\{MAIL_SENDER_NAME\}/$MAIL_SENDER_NAME}"
CONTENT="${CONTENT//\$\{MAIL_SUBJECT_TAG\}/$MAIL_SUBJECT_TAG}"
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
        # 'groups' carries each user's users_database.yml groups through Dex to
        # the apps. It is what an AppShield gate's OIDC_REQUIRED_GROUPS checks
        # (mesh-console requires admins): without it the ID token has no
        # groups claim and every such gate refuses every account. Served from
        # userinfo, which Dex fetches (getUserInfo: true in ensure-dex.sh).
        # Mirrors Yundera/template-root.
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
          - 'groups'
        userinfo_signed_response_alg: 'none'
        token_endpoint_auth_method: 'client_secret_basic'
EOF

if cmp -s "$TMP" "$CONFIG_OUT"; then
    rm -f "$TMP"
    echo "Authelia config at $CONFIG_OUT is unchanged"
else
    mv "$TMP" "$CONFIG_OUT"
    chmod 600 "$CONFIG_OUT"
    AUTHELIA_RESTART_NEEDED=1
    echo "Rendered Authelia config at $CONFIG_OUT"
fi

# --- seed / refresh the admin user ------------------------------------------
# The operator email is the password-reset recovery address, so it must track
# EMAIL even after the initial seed.
ADMIN_EMAIL="${EMAIL:-}"
if [ -z "$ADMIN_EMAIL" ]; then
    ADMIN_EMAIL="admin@${DOMAIN}"
    log_warn "EMAIL not set in $ENV_FILE; falling back to ${ADMIN_EMAIL}"
fi

# The owner's chosen username, recorded at claim time. Absent on a box that has
# never been claimed, and on pre-onboarding boxes — where the account was always
# literally `admin`, so that is the right fallback.
#
# It lives in .env, which ensure-template-sync.sh declares user-owned and never
# touches, so a sync cannot clobber it.
AUTHELIA_ADMIN="$(get_env_value LOCAL_ADMIN_USER)"
[ -n "$AUTHELIA_ADMIN" ] || AUTHELIA_ADMIN="admin"

if [ -f "$USERS_DB" ] && grep -q "^[[:space:]]*password:" "$USERS_DB"; then
    # Already seeded (by us, by `claim`, or by Authelia writing a password change
    # back). Refresh only the owner's email line — never touch any password.
    #
    # SCOPED TO THE OWNER'S OWN BLOCK. The previous version matched every
    # `email:` at any indent, so on a box with more than one account it stamped
    # the operator's address onto ALL of them on every single self-check —
    # silently redirecting every other user's password-reset mail. The awk below
    # tracks YAML structure instead: `users:` opens the map, any column-0 key
    # closes it, the first key under `users:` establishes the per-user indent,
    # keys at that indent switch which user we are inside, and only `email:` keys
    # deeper than that while inside the owner's block are rewritten.
    TMP="$(mktemp)"
    awk -v new="$ADMIN_EMAIL" -v owner="$AUTHELIA_ADMIN" '
        function indent_of(s,   n) { match(s, /^[[:space:]]*/); return RLENGTH }
        /^users:[[:space:]]*$/ { in_users = 1; user_indent = -1; in_owner = 0; print; next }
        in_users && /^[^[:space:]#]/ { in_users = 0; in_owner = 0 }
        in_users && /^[[:space:]]*#/ { print; next }
        in_users && /^[[:space:]]*$/ { print; next }
        in_users {
            ind = indent_of($0)
            if (user_indent < 0) user_indent = ind
            if (ind == user_indent) {
                key = $0
                sub(/^[[:space:]]*/, "", key)
                sub(/:.*$/, "", key)
                gsub(/^["'"'"']|["'"'"']$/, "", key)
                in_owner = (key == owner)
                print; next
            }
            if (in_owner && ind > user_indent && $0 ~ /^[[:space:]]*email:/) {
                printf "%*semail: \"%s\"\n", ind, "", new
                next
            }
        }
        { print }
    ' "$USERS_DB" > "$TMP"
    if cmp -s "$TMP" "$USERS_DB"; then
        rm -f "$TMP"
        echo "users_database.yml already seeded; ${AUTHELIA_ADMIN} email already ${ADMIN_EMAIL}"
    else
        chmod 600 "$TMP"
        mv "$TMP" "$USERS_DB"
        echo "users_database.yml already seeded; refreshed ${AUTHELIA_ADMIN} email to ${ADMIN_EMAIL}"
    fi
else
    # --- seed UNCLAIMED ------------------------------------------------------
    # A fresh box ships with NO usable local credential. The account exists but is
    # `disabled: true`, which Authelia enforces at authentication: a login with
    # the right password is refused as "user not found". The owner claims it at
    # install time (install.sh prompts, or --claim-user/--claim-password/
    # --generate), or later over SSH with tools/authelia-user-manager.sh claim,
    # choosing both the username and the password.
    #
    # Two hard constraints from Authelia 4.39, both verified against the image —
    # violate either and the container dies on startup, taking every interactive
    # login on the box with it:
    #
    #   1. a user entry MUST carry a non-empty `password:`. Seeding the
    #      "unclaimed" state as a bare `disabled: true` with no password field
    #      is FATAL:
    #        could not validate the schema: Users.admin.users: non zero value required
    #      Hence the throwaway hash below — random, never printed, never stored
    #      anywhere else, and unusable precisely because the account is disabled.
    #   2. `users:` MUST NOT be empty, so we cannot simply omit the entry and let
    #      the claim create the first one:
    #        could not validate the schema: users: non zero value required
    #      Hence a PLACEHOLDER key, which `claim` renames to the user's choice.
    #
    # DEFAULT_PWD is deliberately NOT used here. It is an app-seed secret — it
    # reaches every installed app as APP_DEFAULT_PASSWORD through the .env.app
    # ensure-maison-stack.sh writes for Maison — so making it the login password
    # put the owner's own credential in every app's environment.
    if ! authelia_hash argon2 --random --random.length 64; then
        log_error "Failed to generate the unclaimed-account placeholder hash via $AUTHELIA_IMAGE after $HASH_MAX_ATTEMPTS attempts"
        exit 1
    fi
    THROWAWAY_HASH="$AUTHELIA_HASH_RESULT"

    TMP="$(mktemp)"
    cat > "$TMP" <<EOF
users:
  ${AUTHELIA_ADMIN}:
    disabled: true
    displayname: "Administrator"
    password: "${THROWAWAY_HASH}"
    email: "${ADMIN_EMAIL}"
    groups:
      - admins
EOF
    chmod 600 "$TMP"
    mv "$TMP" "$USERS_DB"
    log_success "Seeded Authelia owner account UNCLAIMED (${AUTHELIA_ADMIN}, disabled until it is claimed)"
fi

# Pick up a changed config. SIGHUP is NOT safe (Authelia 4.39 exits on it);
# docker restart is a clean SIGTERM + start. Silent on cold boot, and skipped for
# a container still bound to the pre-move directory — restarting that one would
# start it on an empty folder; ensure-auth-stack.sh recreates it.
#
# ONLY ON A CHANGE. This used to restart Authelia on every run, and every restart
# takes local-auth-${DOMAIN} out of mesh-router-caddy for as long as
# caddy-docker-proxy needs to re-add the route — 20-25s on a busy box. Dex, restarted
# by ensure-dex.sh right after, then could not open the Local Account connector;
# on Yundera's older tree, where the connector was omitted on a failed probe, the
# box lost its Local Account button every night (2026-10-02). It also logged every
# user out of Authelia nightly for no reason.
if [ "$AUTHELIA_RESTART_NEEDED" -eq 1 ]; then
    if restart_if_bound authelia "$AUTH_ROOT"; then
        # Do NOT return before it is served again: ensure-dex.sh restarts Dex
        # seconds from now, and Dex drops a connector whose issuer is not serving
        # at its startup.
        wait_for_authelia
    fi
else
    echo "Nothing Authelia reads at startup changed; not restarting it"
fi

# After the restart: the connector step probes Authelia over the on-box path.
write_local_account_connector

# If the secret was minted just now, a Dex config rendered before this run has a
# connector without it: Dex would accept the login at Authelia and then fail its
# token exchange with `invalid_client`. Re-render now rather than leave that until
# the next cycle: redundant in a self-check, where ensure-dex.sh follows anyway,
# but not on a standalone run.
if [ "$SECRET_JUST_MINTED" -eq 1 ] && [ -f "$SELF_TREE/scripts/self-check/ensure-dex.sh" ]; then
    echo "Secret is new; re-rendering Dex so the connector picks it up"
    bash "$SELF_TREE/scripts/self-check/ensure-dex.sh" || \
        log_warn "Dex re-render failed; the next self-check cycle will retry"
fi

echo "Authelia provisioning complete (data root: $AUTH_ROOT)"
