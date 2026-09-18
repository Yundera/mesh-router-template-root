# Open Entry — a no-credential login for a demo box

A worked example of the `dex/connectors.d/` seam described in the README's
["Extending it"](../README.md) note, and the concrete form of the promise in
[alignment-with-template-root.md](alignment-with-template-root.md): *"The
`connectors.d/` mechanism it used IS ported, so a fork can add its own."*

It gives a box a login that asks for **nothing** — a visitor lands in Maison
without seeing a single screen. That is what the public Yundera demo boxes run.

> **This is an authentication bypass.** Anyone who can reach the box is an admin
> on it. Use it only on a throwaway box with no data you care about. Nothing here
> is installed by `install.sh` or the self-check: this document is text, and the
> script below only exists on a box if somebody deliberately puts it there.
> That is the design — see "Why this is not a script in `scripts/`" at the end.

## How it works

Two pieces, mirroring what `Yundera/demo` does to a managed PCS
(`src/lib/DemoManager.ts`, `buildOpenEntryAuthCommand`):

1. **An IdP that says yes to everyone** — `ghcr.io/navikt/mock-oauth2-server`
   with `interactiveLogin: false`, so `/authorize` answers with a code
   immediately instead of rendering a form.
2. **A Dex drop-in** at `dex/connectors.d/demo-open-entry.yaml` that federates to
   it, which `ensure-dex.sh` concatenates into Dex's config on every render.

**Zero screens requires exactly one connector.** Dex only skips its chooser at
`len(connectors) == 1`. `ensure-dex.sh` renders the Local Account connector iff
the user store holds a non-disabled user, so the box must be *unclaimed* for the
flow to be seamless — otherwise the visitor gets a two-button chooser.

A box installed by `install.sh` is normally **claimed** (you chose a password at
install time), so the script below disables that account. It sets `disabled: true`
and leaves the password hash alone, which is byte-for-byte how `ensure-authelia.sh`
seeds an unclaimed box — Authelia 4.39 refuses a user with an empty `password:`,
hence the hash stays. Re-claiming is therefore a one-line revert, not a new password.

## Setup

Save as `/root/setup-open-entry.sh` on the box and run it as root. It is
idempotent — safe to re-run.

```bash
#!/bin/bash
set -euo pipefail

MESH_ROOT=/DATA/AppData/mesh
SCRIPTS="$MESH_ROOT/scripts"
AUTH_DIR=/DATA/AppData/.demo-auth
CONNECTORS_D="$MESH_ROOT/dex/connectors.d"
DROPIN="$CONNECTORS_D/demo-open-entry.yaml"
USERS_DB="$MESH_ROOT/auth/users_database.yml"

echo "=== Open Entry: starting ==="

# --- 0. preflight ------------------------------------------------------------
# $SCRIPTS is the LIVE tree — cron runs $SCRIPTS/self-check.sh. $MESH_ROOT/template
# is the staged tarball copy ensure-template-sync.sh installs FROM; running its
# ensure-dex.sh would render with a version of the renderer the box does not use.
[ -x "$SCRIPTS/self-check/ensure-dex.sh" ] || { echo "ERROR: no live script tree at $SCRIPTS"; exit 1; }
DOMAIN="$(grep -E '^DOMAIN=' "$MESH_ROOT/.env" | head -1 | cut -d= -f2-)"
PUBLIC_IP_DASH="$(grep -E '^PUBLIC_IP_DASH=' "$MESH_ROOT/.env" | head -1 | cut -d= -f2-)"
[ -n "$DOMAIN" ] || { echo "ERROR: DOMAIN unset in $MESH_ROOT/.env"; exit 1; }
LOCAL_ADMIN="$(grep -E '^LOCAL_ADMIN_USER=' "$MESH_ROOT/.env" | head -1 | cut -d= -f2-)"
[ -n "$LOCAL_ADMIN" ] || LOCAL_ADMIN=admin

mkdir -p "$AUTH_DIR" "$CONNECTORS_D"

# Probe a DEX-ONLY endpoint. /healthz is useless here: when Dex is down its
# caddy-docker-proxy labels vanish with it and auth-$DOMAIN falls through to the
# default service host (the Maison AppShield gate), which answers /healthz with
# 200 OK — a false positive that once shipped a demo box with no login at all.
dex_serving() {
  curl -fsS --max-time 5 "https://auth-${DOMAIN}/.well-known/openid-configuration" 2>/dev/null | grep -q '"issuer"'
}

render_dex_and_verify() {
  local label="$1" attempt ok i
  for attempt in 1 2 3; do
    bash "$SCRIPTS/self-check/ensure-dex.sh" >/dev/null 2>&1 || true
    ok=0
    for i in $(seq 1 20); do
      if dex_serving; then ok=1; break; fi
      sleep 2
    done
    [ "$ok" = "1" ] && { echo "Dex serving after render ($label, attempt $attempt)"; return 0; }
    echo "WARNING: Dex did not come back on attempt $attempt ($label)"
    docker logs dex 2>&1 | tail -3
    sleep 5
  done
  return 1
}

# --- 1. the open-entry IdP ---------------------------------------------------
# requestMappings matches on client_id, NOT scope: tokenCallbacks fire at the
# TOKEN endpoint, whose request carries no scope. Matching on scope looks natural
# and silently never fires — the token is still issued, just stripped of every
# claim, so login "works" and the visitor lands with no email and no admin role.
# groups:["admins"] is load-bearing for AppShield's group gate.
# The leading dot in /DATA/AppData/.demo-auth keeps the stack off the Maison grid
# (Maison treats "." as reserved in AppData entry names).
cat > "$AUTH_DIR/docker-compose.yml" <<COMPOSE
name: demo-auth

services:
  demo-auth:
    image: ghcr.io/navikt/mock-oauth2-server:6.0.0
    container_name: demo-auth
    hostname: demo-auth
    restart: unless-stopped
    cpu_shares: 40
    mem_limit: 512m
    environment:
      SERVER_PORT: "8080"
      JSON_CONFIG: |
        {
          "interactiveLogin": false,
          "tokenCallbacks": [
            {
              "issuerId": "default",
              "tokenExpiry": 3600,
              "requestMappings": [
                {
                  "requestParam": "client_id",
                  "match": "*",
                  "claims": {
                    "sub": "demo",
                    "preferred_username": "demo",
                    "name": "Demo User",
                    "email": "demo@example.com",
                    "email_verified": true,
                    "groups": ["admins"]
                  }
                }
              ]
            }
          ]
        }
    expose:
      - "8080"
    networks:
      pcs: null
    labels:
      caddy_0: demo-auth-${DOMAIN}
      caddy_0.import: gateway_tls
      caddy_0.reverse_proxy: "{{upstreams 8080}}"
      caddy_1: demo-auth-${PUBLIC_IP_DASH}.nip.io
      caddy_1.import: gateway_tls
      caddy_1.reverse_proxy: "{{upstreams 8080}}"
      caddy_2: demo-auth-${PUBLIC_IP_DASH}.sslip.io
      caddy_2.reverse_proxy: "{{upstreams 8080}}"

networks:
  pcs:
    name: pcs
    external: true
COMPOSE

docker compose -f "$AUTH_DIR/docker-compose.yml" up -d

# --- 2. wait for PUBLIC discovery, stably ------------------------------------
# Required, not politeness: Dex resolves every oidc connector's discovery document
# at STARTUP and treats failure as fatal. Three consecutive successes two seconds
# apart, because creating the container makes caddy-docker-proxy reload, and a
# single probe regularly lands in a gap that answers once and then 502s again.
echo "Waiting for demo-auth discovery over https..."
streak=0
for i in $(seq 1 90); do
  if curl -fsS --max-time 5 "https://demo-auth-${DOMAIN}/default/.well-known/openid-configuration" >/dev/null 2>&1; then
    streak=$((streak + 1))
    [ "$streak" -ge 3 ] && { echo "demo-auth discovery stable after ~$((i * 2))s"; break; }
  else
    streak=0
  fi
  sleep 2
done
# Judge on the streak the loop measured, not a fresh probe — an unretried probe
# here lands in the same reload gap the streak exists to ride out.
if [ "$streak" -lt 3 ]; then
  echo "ERROR: demo-auth never became discoverable; refusing to register the connector"
  rm -f "$DROPIN"
  exit 1
fi

# --- 3. the Dex connector ----------------------------------------------------
# ${DOMAIN} is left UNEXPANDED on purpose: ensure-dex.sh substitutes it on every
# render, so the drop-in survives a domain change. The id must not collide with
# `authelia` — Dex refuses to start on a duplicate connector id.
# The mock returns its claims in the id_token rather than from a userinfo
# endpoint, so getUserInfo stays off and insecureEnableGroups is what lets the
# groups claim (and hence the admin role) through.
cat > "$DROPIN" <<'CONNECTOR'
  - type: oidc
    id: demo
    name: Open Entry
    config:
      issuer: https://demo-auth-${DOMAIN}/default
      clientID: dex
      clientSecret: "demo-open-entry"
      redirectURI: https://auth-${DOMAIN}/callback
      userNameKey: preferred_username
      insecureEnableGroups: true
      insecureSkipEmailVerified: true
      scopes:
        - openid
        - profile
        - email
        - groups
CONNECTOR
chown 1001:1001 "$DROPIN" 2>/dev/null || true

# Render with BOTH connectors first and prove Dex survives the new one, while the
# local account is still a working way in. Only then remove that safety net.
if ! render_dex_and_verify "with Open Entry + Local Account"; then
  echo "ERROR: Dex will not serve with the Open Entry connector — rolling back"
  rm -f "$DROPIN"
  bash "$SCRIPTS/self-check/ensure-dex.sh" >/dev/null 2>&1 || true
  exit 1
fi

# --- 4. unclaim the local account -------------------------------------------
cp -a "$USERS_DB" "$USERS_DB.pre-open-entry"
yq -i ".users.${LOCAL_ADMIN}.disabled = true" "$USERS_DB"
chmod 600 "$USERS_DB"
echo "Local account ${LOCAL_ADMIN} disabled (backup: $USERS_DB.pre-open-entry)"
docker restart authelia >/dev/null 2>&1 || true

if ! render_dex_and_verify "Open Entry only"; then
  echo "ERROR: Dex will not serve after unclaiming — restoring the local account"
  mv "$USERS_DB.pre-open-entry" "$USERS_DB"
  docker restart authelia >/dev/null 2>&1 || true
  rm -f "$DROPIN"
  bash "$SCRIPTS/self-check/ensure-dex.sh" >/dev/null 2>&1 || true
  exit 1
fi

echo "=== Open Entry: done ==="
```

## Verifying

```bash
curl -sS -L -o /dev/null -w '%{http_code} %{num_redirects}\n' https://<domain>/
```

Expect `200` after a handful of redirects and no login form anywhere in the body.
The authoritative confirmation is in Dex's log:

```
login successful connector_id=demo user_id=demo username=demo \
  preferred_username=demo email=demo@example.com groups=[admins]
```

`groups=[admins]` is the part worth checking — without it the visitor is in, but
with no admin role.

The self-check preserves all of this. On the next cycle it logs:

```
Local account is unclaimed; omitting the Local Account connector until it is claimed
Added drop-in Dex connector from demo-open-entry.yaml
Rendered Dex config at /DATA/AppData/mesh/dex/config.yaml (1 connector(s))
```

`connectors.d/` lives in the runtime data dir, so `ensure-template-sync.sh` never
touches it; and `ensure-authelia.sh`'s already-seeded branch only ever rewrites
`email:`, so `disabled: true` is not flipped back.

## Undoing it

```bash
rm -f /DATA/AppData/mesh/dex/connectors.d/demo-open-entry.yaml
docker compose -f /DATA/AppData/.demo-auth/docker-compose.yml down
rm -rf /DATA/AppData/.demo-auth
yq -i '.users.admin.disabled = false' /DATA/AppData/mesh/auth/users_database.yml
docker restart authelia
bash /DATA/AppData/mesh/scripts/self-check/ensure-dex.sh
```

## There is no fallback connector — know this before you run it

Dex resolves every OIDC connector's discovery document **at startup** and treats a
failure as **fatal**:

```
failed to initialize server: server: Failed to open connector demo:
failed to get provider: 502 Bad Gateway
```

The process then exits. With Open Entry as the only connector, a mock that is
down, slow to boot, or not yet routed by Caddy means **no interactive login of any
kind on the box, and no OIDC broker for any installed app** — only SSH gets you
back in. The managed Yundera template can fall back to its "Yundera Login"
connector here; this template has no such connector, which is why the script
verifies Dex actually came back and removes its own drop-in when it did not.

Recovery, over SSH:

```bash
rm -f /DATA/AppData/mesh/dex/connectors.d/demo-open-entry.yaml
bash /DATA/AppData/mesh/scripts/self-check/ensure-dex.sh
```

## The identity is static

Every visitor is `sub: demo`. Yundera's managed demo boxes are destroyed and
rebuilt daily, so per-app state never outlives the cycle. A self-hosted box has no
such reaper: concurrent visitors share one identity and whatever they leave behind
accumulates indefinitely. Recycle the box yourself if that matters.

## Why this is not a script in `scripts/`

`ensure-template-sync.sh` copies `template/scripts/**` into the box's live
`scripts/` tree and `chmod +x`'s every `.sh`. A script here would therefore be
installed and executable on **every** box running this template, gated off by
nothing but its own good manners.

The presence of the drop-in file is the entire condition — nothing in the template
knows a demo exists, there is no `DEMO` flag and no branch in the main stack. So
the bypass is not disabled on a normal box; it is simply *not there*. Keeping this
as documentation rather than code is what preserves that property.
