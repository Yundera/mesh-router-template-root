#!/bin/bash
# ensure-connector-local-account.sh - The Dex "Local Account" connector (Authelia),
# as a drop-in: ${DATA_ROOT}/AppData/auth/dex/connectors.d/authelia.yaml.
#
# Every Dex connector is a drop-in owned by one ensure-connector-* script; this is
# the one the mesh template ships. ensure-dex.sh knows none of them — it renders
# the base config, appends whatever is in connectors.d/, and keeps Dex absent while
# there is nothing to append (see dex_wanted, library/common.sh). A deployment adds
# its own the same way (Yundera: ensure-connector-yundera.sh).
#
# ONLY WHEN THE ACCOUNT IS CLAIMED. A fresh box seeds its owner account
# `disabled: true` (ensure-authelia.sh), and Authelia refuses a disabled user as
# "user not found" — so offering the button before onboarding shows a login that
# cannot possibly work. Claimed-ness is read straight from the user store: at least
# one user that is not disabled. Unclaimed, the file is REMOVED.
#
# FAIL-OPEN on any doubt (yq missing, unreadable file, malformed YAML): write the
# connector. Guessing "unclaimed" on a box that is actually claimed would hide the
# owner's only door; guessing "claimed" on a fresh box merely shows a button that
# does not work yet. The asymmetry is deliberate.
#
# Keep the predicate in sync with is_claimed() in tools/authelia-user-manager.sh
# (and Yundera/template-root tools/onboarding.sh).
#
# ORDERING: after ensure-authelia.sh (it mints AUTHELIA_DEX_SECRET, embedded here),
# before ensure-dex.sh (which reads this file). Whatever changes claimed-ness
# outside a self-check run — `authelia-user-manager.sh claim`, an onboarding reset
# — runs this script and then ensure-dex.sh.
#
# The file carries the connector's client secret, so it is 0600; ensure-dex.sh
# hands the whole Dex tree to uid 1001.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

# Fatal, as in ensure-authelia.sh: never write beside the real state.
adopt_auth_state

CONNECTORS_D="$DEX_HOME/connectors.d"
DROPIN="$CONNECTORS_D/authelia.yaml"
mkdir -p "$CONNECTORS_D"

USERS_DB="$AUTHELIA_HOME/users_database.yml"
CLAIMED=1
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
    exit 0
fi

# Empty is tolerated: the connector then renders with an empty secret and fails
# its back-channel until Authelia has provisioned, rather than leaving the owner
# with no button at all.
AUTHELIA_DEX_SECRET="$(get_env_value AUTHELIA_DEX_SECRET)"
if [ -z "$AUTHELIA_DEX_SECRET" ]; then
    log_warn "AUTHELIA_DEX_SECRET not set yet; Local Account connector written without a secret until ensure-authelia.sh has run"
fi

# ${DOMAIN} is left as a token: ensure-dex.sh expands it in every drop-in, so a
# domain change needs no rewrite here. The secret is hex (openssl rand -hex), so
# writing it verbatim is safe.
TMP="$(mktemp "$CONNECTORS_D/.authelia.XXXXXX")"
chmod 600 "$TMP"
cat > "$TMP" <<YAML
  # Local Account — Authelia, the box-local credential store. Written by
  # ensure-connector-local-account.sh; edits here are overwritten.
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

# Check the path Dex will take to open that connector, and say so when it is
# broken. Dex reaches local-auth-${DOMAIN} ON THE BOX — extra_hosts pins the name
# to this host's :443, i.e. mesh-router-caddy, and SSL_CERT_DIR makes it trust the
# mesh CA (stacks/auth/docker-compose.yml). This is the same request from the host:
# same port, same certificate, same CA file.
#
# A WARNING ONLY — the connector is written either way. Local Account is usually
# this box's ONLY connector, so omitting it would trade a login that may not work
# for no login at all. Skipped when Authelia is not running yet (cold boot) or
# when curl is missing.
DOMAIN="$(get_env_value DOMAIN)"
MESH_CA="$MESH_ROOT/data/ca/ca-cert.pem"
# On the run that first delivers data/ca the file is still beside the key:
# ensure-stack-up.sh, later in the list, is what moves it. Same CA either way.
[ -s "$MESH_CA" ] || [ ! -s "$MESH_ROOT/data/certs/ca-cert.pem" ] || MESH_CA="$MESH_ROOT/data/certs/ca-cert.pem"
if [ -n "$DOMAIN" ] && command -v curl >/dev/null 2>&1 \
    && [ "$(docker inspect -f '{{.State.Running}}' authelia 2>/dev/null)" = "true" ]; then
    if [ ! -s "$MESH_CA" ]; then
        log_warn "The mesh CA is not at $MESH_CA yet; Dex cannot verify local-auth-$DOMAIN on the box until mesh-router-agent writes it"
    else
        PROBE_OK=0
        for _ in 1 2 3; do
            if curl -sS --max-time 10 \
                    --resolve "local-auth-$DOMAIN:443:127.0.0.1" --cacert "$MESH_CA" \
                    "https://local-auth-$DOMAIN/.well-known/openid-configuration" 2>/dev/null \
                    | grep -q '"issuer"'; then
                PROBE_OK=1
                break
            fi
            sleep 3
        done
        if [ "$PROBE_OK" != "1" ]; then
            log_warn "local-auth-$DOMAIN did not return a discovery document over the on-box path (127.0.0.1:443, mesh CA)"
            log_warn "  Dex may fail to open the Local Account connector. Check that authelia is up and that"
            log_warn "  mesh-router-caddy serves local-auth-$DOMAIN with the mesh certificate."
        fi
    fi
fi
