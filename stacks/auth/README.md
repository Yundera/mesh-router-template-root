# auth stack

The box's identity layer. Every app on the box logs in through it: **Dex** is the OIDC
broker apps talk to, **Authelia** holds the local account behind Dex, and
**auth-registrar** lets each app register itself as an OIDC client. **auth-console** is
the stack's web UI.

| Host | Serves |
|---|---|
| `auth-${DOMAIN}` | Dex — issuer, login page, `/.well-known/openid-configuration` |
| `local-auth-${DOMAIN}` | Authelia — the "Local Account" login and password reset |
| `auth-console-${DOMAIN}` | auth-console — Account and Access pages (also the Maison **Auth** tile) |

Each host also answers on the `-${PUBLIC_IP_DASH}.nip.io` and `.sslip.io` variants.

Deployed to `${DATA_ROOT}/AppData/auth` (project name `auth`). This README is copied
there on every deploy.

## Services

| Container | Image | Networks | Role |
|---|---|---|---|
| `dex` | `dexidp/dex` **by digest** (a `master` build) | `pcs`, `dex-internal` | OIDC broker. Web on `5556`, client-management gRPC on `5557` |
| `authelia` | `authelia/authelia:4.39.x` | `pcs` | Local credential store, Dex's only built-in connector |
| `auth-registrar` | `mesh-auth` | `pcs`, `dex-internal` | `POST /register` → creates the app's client in Dex over gRPC |
| `auth-console` | `appshield` | `pcs` | AppShield gate, the only public route to the console |
| `auth-console-app` | `auth-console` | `pcs` | Console backend. Holds the Docker socket |

Pin rules, explained in full in `docker-compose.yml`:

- **Dex is pinned by digest, not by a tag.** RP-Initiated and Back-Channel Logout are
  merged upstream but not in any release yet. Re-pin to a release once one ships with
  both. When you do, re-check that the image still has its CA bundle at
  `/etc/ssl/certs/ca-certificates.crt` (see `SSL_CERT_DIR` below).
- **Never lower the Authelia pin.** Authelia migrates `db.sqlite` forward on every
  start, and an older binary then exits with a misleading *"encryption key does not
  appear to be valid"* error. `AUTHELIA_IMAGE` is repeated in `ensure-authelia.sh` and
  `tools/authelia-user-manager.sh`, so change all three together. As a safety net,
  `pre-up.sh` raises a pin that is older than the box's database
  (`authelia_enforce_db_floor`).

## How it is built

Nothing in this folder is hand-written. Each self-check renders it in this order (from
`scripts/self-check/scripts-config.txt`):

```
ensure-authelia.sh   secrets (generate-once)        → auth/authelia/secrets/, oidc/private.pem
                     auth/configuration.yml.tmpl    → auth/authelia/configuration.yml
                     owner seed / email refresh     → auth/authelia/users_database.yml
                     AUTHELIA_DEX_SECRET            → auth/.stack.env (plaintext) + secrets/dex-client-hash
                     "Local Account" connector      → auth/dex/connectors.d/authelia.yaml  (only once claimed)
                     restart authelia, wait until it serves

ensure-dex.sh        DEX_SESSION_KEY (generate-once) → auth/.stack.env
                     scripts/self-check/dex.config.yaml.tmpl  ┐
                     + every auth/dex/connectors.d/*.yaml      ┘→ auth/dex/config.yaml
                     connector count                 → auth/dex/connector-count
                     dex-theme/                      → auth/dex/frontend/  (tools/provision-dex-frontend.sh)
                     restart dex — or remove it when there are 0 connectors

ensure-stack-up.sh   mesh stack (Caddy, smtp, the `pcs` network)

ensure-auth-stack.sh AUTH_CONSOLE_ASSERTION_SECRET   → auth/.stack.env
                     tools/deploy-stack.sh auth …:
                       stacks/auth/docker-compose.yml → auth/docker-compose.yml
                       stacks/auth/icon.svg           → auth/.icon.svg
                       stacks/auth/README.md          → auth/README.md
                       mesh .env + auth/.stack.env,
                       filtered to the compose's keys → auth/.env
                       pull → evict name squatters → pre-up.sh → up
                     (`--scale dex=0` when dex_wanted says no)
```

Templates use literal bash substitution, not `envsubst`, so the installer does not
depend on gettext. `dex.config.yaml.tmpl` substitutes only `${DOMAIN}` and
`${DEX_SESSION_KEY}`. Connector drop-ins substitute only `${DOMAIN}`, and any other
`$…` passes through unchanged.

`pre-up.sh` runs after the eviction and before `up`. It hands the `dex-internal`
network over from the old mesh project (`adopt_network`) and enforces the Authelia
database floor.

### Dex's config, piece by piece

The comments in `scripts/self-check/dex.config.yaml.tmpl` are the reference. What it
contains:

- **`issuer: https://auth-${DOMAIN}`**, stored in **sqlite** at `/data/dex.db`.
- **`grpc.addr: dex-grpc:5557`.** The client API is **unauthenticated**. `dex-grpc` is a
  network-scoped alias that exists only on `dex-internal`, so Dex binds that one
  interface and only auth-registrar can reach the API. Do not change it to `dex`,
  `0.0.0.0` or a fixed IP; the template comment explains why each one breaks.
- **`frontend`.** `dir: /srv/dex/web` is required, or Dex ignores the files mounted
  over it. `theme: mesh`, and the heading shows the box's own domain.
- **`oauth2.skipApprovalScreen: true`.** Every app on the box is first-party.
- **`sessions`** (needs `DEX_SESSIONS_ENABLED=true` on the container, or Dex refuses to
  start). The 30-day absolute and idle lifetimes are what keep SSO at 30 days instead
  of Dex's default 1 h idle. `ssoSharedWithDefault: all` shares one session across all
  clients, which skips the connector chooser. It also makes Dex advertise
  `end_session_endpoint` and back-channel logout, so a single logout ends every app.
- **No password DB and no static clients.** Dex is a pure broker. Clients are created at
  runtime by auth-registrar, and connectors come from `connectors.d/`.
- **`connectors:`** is empty in the template. `ensure-dex.sh` appends the drop-ins
  after it.

## Connectors (`auth/dex/connectors.d/`)

Each Dex connector is a drop-in file, written by the script that owns the
connector's issuer. The template ships one: `authelia.yaml` (Local Account), written by
`ensure-authelia.sh` once the owner account is claimed. A deployment adds its own
login sources in the same way, without changing this template.

A drop-in holds one or more items of the `connectors:` list, indented two spaces:

```yaml
  - type: oidc
    id: example            # unique; `authelia` is taken
    name: Example
    config:
      issuer: https://example.org
      clientID: …
      clientSecret: …
      redirectURI: https://auth-${DOMAIN}/callback
```

The directory is runtime data, so template syncs never touch it. After writing or
removing a drop-in, run `scripts/self-check/ensure-dex.sh` to apply it right away.

> **A broken drop-in takes down every login on the box.** Dex resolves each OIDC
> connector's discovery document *at startup* and exits if one fails
> (`failed to get provider: 502`), and a YAML error has the same effect. Before writing
> a drop-in, the script must check that its issuer answers. When it cannot, it must
> **remove** the file rather than leave the last good copy in place.

### Zero connectors = no Dex

Dex will not start with an empty connector list. A freshly installed box seeds its
owner **disabled (unclaimed)**, and Authelia treats a disabled user as nonexistent, so
there is no Local Account connector yet. In that state:

- `ensure-dex.sh` records `0` in `connector-count`, and the `dex` container is
  **absent**. That is expected, not a crash.
- auth-registrar answers `503 login_unavailable` (with `SETUP_URL` when it is set), and
  every gate shows "sign-in unavailable".
- To leave this state, claim the account:
  `scripts/tools/authelia-user-manager.sh claim <user>`. It runs
  `ensure-authelia.sh --connector-only` and then `ensure-dex.sh`, which writes the
  drop-in and starts Dex immediately.

## How an app logs in

1. The app's AppShield gate (container `foo`) calls `POST http://auth-registrar:9092/register`.
2. The registrar identifies the caller **by PTR lookup of its source IP on `pcs`**, so
   it never trusts a name sent in the request. It checks every redirect URI against
   `<name>-<suffix>` for each suffix in `REDIRECT_HOST_SUFFIXES`. Only
   `ROOT_CLIENT_ID` (= `DEFAULT_SERVICE_HOST`) may use the bare `${DOMAIN}`.
3. The registrar calls `CreateClient` on Dex over gRPC and returns
   `{client_id, client_secret, issuer_url, internal_issuer_url}`.
4. The browser goes to `auth-${DOMAIN}`. Dex shows the connector chooser and sends the
   user on to Authelia (or another connector), then back.
5. The gate uses `internal_issuer_url` (`http://dex:5556`) for discovery, the token
   exchange and JWKS, so those calls stay on the box. The issuer string, and every URL
   the browser sees, is still `https://auth-${DOMAIN}`.

The registrar keeps no state. Its secret cache is in `/tmp`, so a restart rotates each
client's secret on that client's next `/register`, and nobody notices.

Dex reaches **Authelia** the same way: `extra_hosts` points `local-auth-${DOMAIN}` at
the host, where this box's Caddy terminates TLS with the mesh certificate. Dex trusts
that certificate through `SSL_CERT_DIR=/ca`, which **adds** the mesh CA to the image's
bundle instead of replacing it.

## On disk

```
${DATA_ROOT}/AppData/auth/
├── docker-compose.yml  .env  .icon.svg  README.md   regenerated every self-check — don't edit
├── authelia/                         STATE — back it up
│   ├── configuration.yml             rendered every run
│   ├── users_database.yml            the accounts (Authelia owns it after the seed)
│   ├── db.sqlite                     sessions, regulation, schema version
│   ├── secrets/                      session, storage, reset, oidc-hmac, dex-client-hash
│   └── oidc/private.pem              JWKS signing key
├── dex/                              CACHE — safe to delete, except connectors.d/
│   ├── config.yaml  connector-count  rendered every run
│   ├── dex.db                        clients, codes, refresh tokens, keys
│   ├── connectors.d/                 drop-ins: rebuilt only by the scripts that own them
│   └── frontend/                     rendered login theme (bind-mounted :ro)
└── auth-console/gate-data/           the console gate's sessions (uid 65534)
```

Losing `authelia/` puts the box back to **unclaimed**. It is recoverable over SSH,
but the account is gone. Deleting `dex/` costs one re-login on each app.

## What it needs from the other stacks

Nothing below is a `depends_on`, because that cannot point at another project. Each is
a reference by name or by path:

- **mesh** — `mesh-router-caddy` routes all three hosts. `mesh-router-agent` writes the
  mesh CA to `AppData/mesh/data/ca`, which Dex mounts. `smtp` relays Authelia's
  reset mail. The mesh `.env` is the source of this stack's `.env`.
- **`pcs` network** — external, created by `ensure_pcs_network` before any stack comes
  up. `dex-internal` belongs to this stack, and nothing outside it may join.
- **Order** — runs after the mesh stack and before `maison` and `terminal`, because
  their gates register here.

## Day-to-day

```bash
# accounts (stdout is JSON)
sudo /DATA/AppData/mesh/scripts/tools/authelia-user-manager.sh list
printf '%s' 'pw' | sudo …/authelia-user-manager.sh claim <user>     # or: claim --generate <user>
sudo …/authelia-user-manager.sh add|delete|set-password|set-email …

# re-render one piece
sudo bash /DATA/AppData/mesh/scripts/self-check/ensure-dex.sh        # config + connectors
sudo bash /DATA/AppData/mesh/scripts/self-check/ensure-auth-stack.sh # redeploy the stack

# look
curl -s https://auth-<domain>/.well-known/openid-configuration | jq .
cat /DATA/AppData/auth/dex/connector-count
docker logs dex | head          # startup errors name the failing connector
docker logs auth-registrar      # `root app:` line, /register decisions
```

## Known traps

| Symptom | Cause |
|---|---|
| `dex` container missing | No connector (unclaimed and no drop-in). Expected; claim the account |
| Dex exits `failed to get provider` | A drop-in's issuer is down or not routed yet. Fix or remove the drop-in |
| Dex fails with `login.html … not a directory` | `compose up` ran before the frontend existed, so Docker created a directory. `provision-dex-frontend.sh` fixes it |
| Authelia: "encryption key does not appear to be valid" | The image is older than `db.sqlite`. Raise the pin; never lower it |
| Dex "Address already in use" on gRPC | A fixed IP was reintroduced on `dex-internal`. Use the alias |
| Gate logs `back-channel via the public issuer` | It registered with a registrar that didn't send `internal_issuer_url`. Restart the gate |
| Login on the bare domain bounces to `<app>-${DOMAIN}` | `ROOT_CLIENT_ID` was rejected; check the registrar's `root app:` log line |
| Logout leaves apps logged in | Dex image without session/logout support, or `DEX_SESSIONS_ENABLED` missing |

## See also

- `docker-compose.yml`, `scripts/self-check/dex.config.yaml.tmpl` and
  `auth/configuration.yml.tmpl`: the rationale behind every setting.
- `scripts/self-check/ensure-{authelia,dex,auth-stack}.sh`: their headers.
- `doc/alignment-with-template-root.md`: history of the split and the CasaOS removal.
