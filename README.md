# mesh-router-template-root

Template docker-compose configuration for PCS (Private Cloud Server) instances.

## Purpose

This repository provides a template `docker-compose.yml` file used by mesh-dashboard to generate user-specific configurations. When a new user sets up their PCS instance, the dashboard replaces template variables with user-specific values.

## Template Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `%PROVIDER_STR%` | Provider connection string | `https://api.nsl.sh,userid,signature` |
| `%PUBLIC_IP%` | Instance public IP address | `203.0.113.5` |
| `%REF_DOMAIN%` | User's full domain | `username.nsl.sh` |
| `%DATA_ROOT%` | Data storage path | `/data` |
| `%DEFAULT_PASSWORD%` | Platform secret consumed by app-store apps via `$APP_DEFAULT_PASSWORD` / `$PCS_DEFAULT_PASSWORD` | `generated-password` |
| `%EMAIL%` | User's email address | `user@example.com` |

## Services Included

### mesh-router-tunnel

WireGuard VPN tunnel to the provider for NAT traversal.

- Forwards traffic to local Caddy instance
- Requires NET_ADMIN and SYS_MODULE capabilities
- Uses `%PROVIDER_STR%` for authentication

### mesh-router-agent

Direct IP registration for low-latency routing.

- Registers public IP with mesh-router-backend
- Falls back to tunnel if direct routing unavailable
- Uses `%PUBLIC_IP%` and `%PROVIDER_STR%`

### caddy

Reverse proxy with automatic SSL certificate management.

- Uses [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)
- Discovers services via Docker labels
- Handles TLS termination
- Base config comes from this repo's `Caddyfile`, synced to
  `${DATA_ROOT}/AppData/mesh/Caddyfile` and bind-mounted at `/etc/caddy/Caddyfile`.
  It holds the global options, the `(gateway_tls)` snippet, and the three
  **root-domain** routes — see [Root domain routing](#root-domain-routing).

#### Root domain routing

The three root addresses — `${DOMAIN}`, `${PUBLIC_IP_DASH}.nip.io`,
`${PUBLIC_IP_DASH}.sslip.io` — are defined **only** in the `Caddyfile`, and point at
whatever `DEFAULT_SERVICE_HOST:DEFAULT_SERVICE_PORT` names in `.env` (default
`maison:80`). The same pair is also the target of the custom-domain catch-all
that `mesh-router-caddy` injects via its Admin API.

To hand the root domain to an installed app:

```bash
# /DATA/AppData/mesh/.env
DEFAULT_SERVICE_HOST=my-app     # container name, or host.docker.internal for a host port
DEFAULT_SERVICE_PORT=3000
```

then run the self-check (`sudo bash /DATA/AppData/mesh/scripts/self-check.sh`). It
recreates both readers of the setting: `mesh-router-caddy` (mesh stack) and
`auth-registrar` (auth stack, whose `.env` is regenerated from the mesh one). A bare
`cd /DATA/AppData/mesh && docker compose up -d` moves the route at once, but logins on
the bare domain keep bouncing to `<app>-${DOMAIN}` until the auth stack follows on the
next self-check.

- The target container **must be attached to the `pcs` network** — Caddy resolves it by
  Docker DNS. A container that isn't on `pcs`, or a typo, gives a 502 on the root domain
  and nothing else to explain it.
- **No container may claim a root address via a `caddy_*` label.** caddy-docker-proxy
  merges site blocks that share an address, so a second claim leaves the apex with two
  `reverse_proxy` handlers and makes this setting meaningless. Services get their own
  `<name>-${DOMAIN}` hostname instead.
- The dashboard stays reachable at `maison-${DOMAIN}` whatever this is set to.

### maison (dashboard)

The CasaOS replacement: the same app grid and the same CasaOS App Store format, in a
single Go binary driving the Docker socket. Deployed as its **own compose stack** to
`${DATA_ROOT}/AppData/maison` by `scripts/self-check/ensure-maison-stack.sh`, not as
part of the mesh stack — it attaches to the shared `pcs` network (see
[Network Configuration](#network-configuration)).

- Reachable at `maison-${DOMAIN}` (plus the `nip.io` / `sslip.io` variants), and it is
  what the root domain points at by default (`DEFAULT_SERVICE_HOST=maison`).
- **No authentication of its own** and it mounts the Docker socket, so it is never
  published: the AppShield gate in the same stack is the only route in, and that gate
  federates through Dex to Authelia. Never add a `ports:` mapping to it.
- What apps receive on install — network, domain, public IP, default password — comes
  from `${DATA_ROOT}/AppData/maison/.env.app`, regenerated from the mesh `.env` on
  every self-check.
- Apps installed by CasaOS before it was removed were copied into Maison's layout
  (`${DATA_ROOT}/AppData/<app>`) by the now-retired `ensure-maison-app-mirror.sh`, and
  Maison manages them there. The originals under `/DATA/AppData/casaos/apps/<app>` are
  left in place, unread.

### mesh-console (the stack's web UI)

The mesh stack's own web UI ([Yundera/mesh-console](https://github.com/Yundera/mesh-console)),
and what the **Mesh Router** tile opens: public IP and domain, how the gateways route to
the box (**direct** / **tunnel** / **offline**, with the registered routes, tunnel
handshake age, mesh certificate expiry and a root-domain probe), whether the template is
up to date with an **Update now** button that runs the self-check, and the root-domain
default application. Two services of the mesh stack itself (`mesh-console`, the AppShield
gate, and `mesh-console-app`) — not a stack of its own.

- Reachable at `mesh-console-${DOMAIN}` (plus the `nip.io` / `sslip.io` variants).
- **Admins only**, checked twice: its AppShield gate refuses accounts outside `admins`
  (`OIDC_REQUIRED_GROUPS`), and the app verifies the gate's signed identity assertion
  (`MESH_CONSOLE_ASSERTION_SECRET`, minted into the mesh `.env` by
  `ensure-stack-up.sh` right before the stack comes up).
- It holds the Docker socket and reads the mesh root **read-only**. Its two host
  actions both call this template's own scripts — `scripts/self-check.sh`, and
  `scripts/tools/set-default-app.sh <host> <port>`, which stores the setting in the mesh
  `.env` and re-runs `ensure-stack-up.sh` then `ensure-auth-stack.sh` (Caddy's root route
  and auth-registrar's `ROOT_CLIENT_ID`). They run as a one-shot privileged
  `mesh-console-runner` container in the host's namespaces. There is no generic command
  path. Yundera/template-root ships the same tool for its own layout.
- The Update page compares `template/.revision.json` (written by
  `ensure-template-sync.sh` after each sync: `{url, commit, synced_at}`) with the head of
  the `UPDATE_URL` branch on GitHub.

### dex / authelia / auth-registrar (SSO) — the `auth` stack

Single sign-on for apps installed on the PCS. Apps delegate login via OIDC instead of
holding their own credentials.

These three are their **own compose stack**, `auth` (`stacks/auth/`), deployed to
`${DATA_ROOT}/AppData/auth` by `scripts/self-check/ensure-auth-stack.sh` right after the
mesh stack. That directory is the stack's whole home: the generated `docker-compose.yml`
and `.env`, and the state — `authelia/` and `dex/` (the rendered login theme sits inside
it, at `dex/frontend/`). Until 2026-10-01 the state was in the mesh root (`auth/`, `dex/`,
`dex-frontend/`); a box that still has it there gets it renamed across on its next
self-check, with nothing stopped. Container names are unchanged, so everything else
still reaches them by name on `pcs`. The stack's web UI, auth-console, is part of it too
(below), and the **Auth** tile in Maison opens it.

- **dex** — OIDC identity broker at `https://auth-${DOMAIN}` (discovery at
  `/.well-known/openid-configuration`). A pure broker: it holds no credential of its
  own, and renders a connector-chooser login page themed from `dex-theme/`. It keeps
  its own 30-day browser session, so it advertises `end_session_endpoint` and
  back-channel logout — one logout ends every app through the spec.
- **authelia** — the PCS-local credential store at `https://local-auth-${DOMAIN}`,
  federated by Dex as the "Local Account" connector. Owns the account that used to
  live in CasaOS. Its own login page carries the password-reset link, which mails
  through the `smtp` relay in the mesh stack. Exactly one OIDC client (Dex); per-app
  clients stay on Dex's gRPC path.
- **auth-registrar** — apps self-register as OIDC clients (`POST /register` to
  `http://auth-registrar:9092`, internal only); the registrar creates the client in Dex
  over its gRPC API. Caller identity comes from a PTR lookup of the source container
  name, never from the request body.
- Provisioned by `ensure-authelia.sh` (secrets, JWKS key, config, admin seed) and
  `ensure-dex.sh` (config render), in that order — Authelia mints the
  `AUTHELIA_DEX_SECRET` that Dex's connector needs. Dex's data under
  `${DATA_ROOT}/AppData/auth/dex` is cache and safe to delete (except
  `connectors.d/`, below); Authelia's under `${DATA_ROOT}/AppData/auth/authelia` holds
  the local account — back it up.
- **auth-console** ([Yundera/auth-console](https://github.com/Yundera/auth-console)) —
  the identity console at `https://auth-console-${DOMAIN}`: **Account** (your own
  account, and for admins the local Authelia users: add, reset password, change email,
  revoke) and **Access** (host Linux accounts, their SSH keys, login history; add or
  remove a key, with a lockout warning before the last `user-` key goes). Two services:
  the AppShield gate `auth-console` and the app `auth-console-app`. Unlike mesh-console
  the gate does not require the `admins` group — every user may reach their own Account
  page; admin-only routes are enforced by the app. Host actions run through the
  template's own `authelia-user-manager.sh` and fixed key scripts, in a one-shot
  privileged `auth-console-runner` container in the host's namespaces (no SSH). Claiming
  the login stays on the command line (below). The console is optional to login: if it
  is down, every other app still logs in.
- Dex's gRPC client API is unauthenticated and is therefore bound to the isolated
  `dex-internal` network via the network-scoped `dex-grpc` alias, never `pcs` and
  never `0.0.0.0`. That network belongs to the auth stack; nothing outside it joins.
- **Extending it.** Drop a connector into
  `${DATA_ROOT}/AppData/auth/dex/connectors.d/*.yaml` (runtime dir, so a template
  update never reverts it) and it is concatenated into Dex's config on the next
  self-check. Read `ensure-dex.sh`'s notes first: Dex resolves every OIDC connector's
  discovery document **at startup and treats a failure as fatal**, so a drop-in
  pointing at an issuer that is down takes down *all* interactive login on the box.

#### Claiming the login

A newly-installed server seeds its owner account **unclaimed** — the account exists
but is disabled, and Dex renders **no sign-in button at all** until it is claimed.
That is deliberate: there is no default password to guess, and nothing advertises a
login that cannot work.

`install.sh` normally claims it for you — it prompts for a username and password, or
takes `--claim-user` / `--claim-password`, or mints one with `--generate`. A box that
was updated rather than installed (the nightly self-check, `--yes` with no
credentials) stays unclaimed until you claim it over SSH:

```bash
# choose your own password
printf '%s' 'your-password' | \
  sudo /DATA/AppData/mesh/scripts/tools/authelia-user-manager.sh claim <username>

# or have one minted and printed once
sudo /DATA/AppData/mesh/scripts/tools/authelia-user-manager.sh claim --generate <username>
```

The username you pick becomes the OIDC `preferred_username` every app keys its
per-user account on, so it is free to choose now and expensive to change later —
`claim` refuses to run twice without `--force`, and there is no rename verb. The same
script also does `list`, `add`, `delete`, `set-password` and `set-email`.

**This is NOT `DEFAULT_PWD`.** That is an app-seed secret handed to every app this
box installs (`$APP_DEFAULT_PASSWORD` and friends); using it as the human login would
put your own password in every app's environment.

**REMOVED:** `casaos`, and with it `casaos-oidc-bridge` and the disposable Dex
break-glass admin. Authelia is the local credential now, so the bridge was a second
identity for the same person and the break-glass account had nothing left to recover
from. See [doc/alignment-with-template-root.md](doc/alignment-with-template-root.md).

## Network Configuration

All services connect via the `pcs` bridge network, enabling internal communication.
Every stack — mesh, auth, maison, terminal — joins it as `external: true`; the
self-check creates it (`ensure_pcs_network` in `scripts/library/common.sh`) before the
first stack comes up, so no stack owns it and none has to start first.

```
External Request
       │
       ▼
   mesh-router-tunnel / mesh-router-agent
       │
       ▼
     caddy (reverse proxy)
       │
       ▼
   maison / other services
```

## Usage

Variables are replaced by mesh-dashboard when generating user configurations:

```javascript
const userConfig = template
  .replace('%PROVIDER_STR%', `${backendUrl},${userId},${signature}`)
  .replace('%PUBLIC_IP%', userPublicIp)
  .replace('%REF_DOMAIN%', `${username}.${serverDomain}`)
  .replace('%DATA_ROOT%', '/data')
  .replace('%DEFAULT_PASSWORD%', generatedPassword)
  .replace('%EMAIL%', userEmail);
```

## Update channels

Installs follow an **update channel** — a branch of this repo:

| Channel | Branch | Who | How to select |
|---------|--------|-----|----------------|
| `stable` (default) | `stable` | end users | nothing — it's the default |
| `main` (dev) | `main` | developers/testing | `install.sh --channel main` (or `-Channel main` on Windows) |

The channel is a convenience: it is resolved to a full URL at install time and persisted
to `.env` as **`UPDATE_URL`**, which the nightly self-check reads back — so a box keeps
updating from the source it was installed with instead of drifting onto another branch.
Point it anywhere with `install.sh --update-url <tarball>` (forks, tags, mirrors), or edit
`UPDATE_URL` directly afterwards.

Re-running `install.sh` reads `UPDATE_URL` back too, so **omit `--channel` on a re-run**
unless you actually want to switch channels — passing it is what moves a box between
branches. The resolution order is `--update-url` → `--channel` (only when passed) →
`UPDATE_URL`/`MESH_TEMPLATE_URL` in the environment → `UPDATE_URL`/`MESH_TEMPLATE_URL` in
`.env` → the default channel. Environment variables outrank `.env` so that
`UPDATE_URL=file:///... sudo -E bash install.sh` still works for testing a local template
tree on a real box.

`UPDATE_URL` is the same key name and shape `Yundera/template-root` uses, and the one
`settings-center-app`'s update-channel panel reads and writes — that alignment is the point
(see [doc/alignment-with-template-root.md](doc/alignment-with-template-root.md)). One
difference remains: this template ships `.tar.gz`, `template-root` ships `.zip`. A `.zip`
URL is rejected with an explicit message rather than failing inside `tar`.

`MESH_UPDATE_CHANNEL` and `MESH_TEMPLATE_URL` are the pre-rename keys. They are still read
as fallbacks for one release, and `scripts/migrations/2026-08-02-02-rename-update-url.sh`
converts them in place.

Promote dev → users by merging `main` into `stable`.

## Publishing updates

The dashboard's install command curls `install.sh` from jsDelivr — `@stable` by default
(the dashboard's `TEMPLATE_REPO_URL` config selects the ref it serves):

```
https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.sh
```

`install.sh` no longer fetches individual files from the CDN. It downloads the whole repo as a channel tarball from GitHub, lays down `docker-compose.yml` + `scripts/`, then runs the self-check. The nightly self-check (`ensure-template-sync.sh`) re-syncs from the **same** GitHub tarball for the box's channel:

```
https://github.com/yundera/mesh-router-template-root/archive/refs/heads/stable.tar.gz   # or main
```

GitHub serves that archive near-realtime (no 12-hour CDN cache), so pushes to a channel branch reach existing installs on it — compose **and** scripts — within minutes, no purge required.

Only `install.sh` / `install.ps1` themselves sit behind jsDelivr's floating cache (up to 12h). After changing them, purge the channel(s) you publish so new installs pick them up:

```bash
# stable (the default user path) — purge after merging into stable
curl "https://purge.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.sh"
curl "https://purge.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.ps1"
# main (dev channel)
curl "https://purge.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh"
```

Notes:
- Purge only works once commits are actually pushed to the branch. It re-resolves `@stable`/`@main` against GitHub, so nothing to fetch = nothing changes.
- Pinned refs (`@1.2.3`, `@<sha>`) are immutable and don't need purging.
- Purge is rate-limited; don't script it in a loop.

## Self-check & auto-update (Linux only)

`install.sh` is thin: it lays down the template (`docker-compose.yml` + `scripts/`) and a
minimal `.env`, then runs `self-check.sh --display`. The self-check is an ordered registry of
idempotent `ensure-*.sh` scripts that install Docker, backfill `.env`, sync the template, pull
images, bring the stack up, and verify routing — shown live during install as a per-step
checklist. The same self-check then runs nightly via cron. Windows (`--windows`) installs skip
it entirely — the stack works but stays manual-update.

### Manual update (`install.sh` with no arguments)

Auto-update is optional (`MESH_AUTO_UPDATE=false`), and on Windows there is no self-check at
all. On those boxes re-running the installer is the only thing that ever lands a new template
— so both installers are designed to be run with **no arguments**:

```bash
# Linux — as root; the installer does not call sudo itself
bash /DATA/AppData/mesh/template/install.sh
# or, to also pick up a newer installer itself:
curl -fsSL https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.sh | bash
```

```powershell
# Windows / PowerShell
irm https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.ps1 | iex
```

Everything the installer needs is already in `.env`, so nothing has to be re-typed: the
provider string, domain, data root and update source are read back from disk, printed as a
summary (the provider signature redacted), and applied after one confirmation.

```
Found an existing installation at /DATA/AppData/mesh

  Domain:       alice.nsl.sh
  Provider:     https://nsl.sh/router/api,alice-uid,4kQ7…(hidden)
  Data root:    /DATA
  Update from:  https://github.com/yundera/mesh-router-template-root/archive/refs/heads/stable.tar.gz
  Auto-update:  disabled
  Claimed:      yes (alice)

Update this installation? [Y/n]
```

The update is not a special mode — it is the same script following its normal precedence
ladder, `explicit flag > value already in .env > prompt > default`. Consequences worth
knowing:

- **`.env` is preserved key by key.** `DEFAULT_PWD`, `AUTHELIA_DEX_SECRET` and
  `DEX_SESSION_KEY` survive; regenerating them would invalidate every installed app's
  database password and admin token. There is deliberately no "reinstall from scratch"
  option in the prompt — to genuinely start over, run `uninstall.sh` first.
- **An already-claimed box is not asked about its owner account**, so the whole update is
  one keypress.
- **Pass `--domain` / `--provider` to change identity.** That is a deliberate change and
  skips the confirmation.
- **Non-interactive runs proceed without asking** (`--yes` / `-Yes`, or no usable terminal —
  cron, CI, a `curl | bash` under systemd). The configuration came off the box's own disk,
  so there is nothing to confirm against.
- **`--windows` is sticky.** It is recorded as `MESH_WINDOWS_MODE` in `.env`, so an
  argument-less re-run of `install.sh` on WSL keeps taking the Windows path instead of
  falling through to the Linux one and trying to set up cron, logrotate and apt.
- A first install still requires `--provider` and `--domain` (`-Provider` / `-Domain` on
  Windows); with neither those flags nor an existing `.env`, the installer says so instead
  of reporting a missing flag.
- **`install.ps1` behaves the same way** — same ladder, same confirmation, same redaction.
  Its one difference: it downloads from a jsDelivr channel base rather than a tarball URL,
  so if `.env` holds an `UPDATE_URL` that names no branch (a fork, tag or mirror) it warns,
  fetches from `stable`, and leaves the recorded URL untouched rather than repointing the
  box.

### Layout

```
/DATA/AppData/mesh/               # everything for this stack, one directory
├── docker-compose.yml            # template-owned: overwritten by auto-update
├── .env                          # user-owned: never touched by auto-update
├── Caddyfile                     # template-owned: base caddy config, bind-mounted read-only
├── template/                     # pristine synced copy of this repo
├── scripts/                      # live scripts (self-check.sh, library/, self-check/, tools/, migrations/)
├── migration-markers/            # one marker per applied migration
├── log/mesh.log                  # self-check log (logrotate: daily, 7 days)
└── data/                         # runtime state: certs/ (mesh cert + key), ca/ (the mesh CA alone), caddy/

/DATA/AppData/auth/               # the auth stack, one directory
├── docker-compose.yml, .env      # generated by deploy-stack.sh on every self-check
├── authelia/                     # users_database.yml, db.sqlite, configuration.yml, secrets/, oidc/
├── dex/                          # dex.db, config.yaml, connectors.d/, frontend/ (rendered login theme)
└── auth-console/gate-data/       # the console gate's sessions
/DATA/AppData/maison/, terminal/  # the other auxiliary stacks
```

### What runs (in order, from `scripts/self-check/scripts-config.txt`)

1. **Self-maintenance** — scripts executable, nightly cron entry, logrotate config
2. **Prerequisites** — Docker installed, `.env` valid (backfills missing optional keys)
3. **Template sync** — downloads the tarball at `UPDATE_URL` (default: the `stable`
   branch), runs any pending **migrations** from the downloaded tree, atomically
   swaps `template/`, copies `docker-compose.yml`, `Caddyfile` and `scripts/` to their live
   locations (auto-update)
4. **Stack** — re-detect public IP (updates `.env` if changed), provision Authelia
   (`ensure-authelia.sh`: secrets, JWKS key, config, owner-account seed), mint the Dex
   session key, provision Dex SSO (`ensure-dex.sh`: render config, append connectors,
   provision the login theme), `docker compose pull`, `up -d` of the mesh stack (which also
   creates the shared `pcs` network), then the auth stack (`ensure-auth-stack.sh`), then the
   auxiliary stacks (Maison, Terminal)
5. **Verification** (check-only) — routes registered with the backend, own domain reachable
   end-to-end (`curl -H 'X-Mesh-Trace: 1' https://$DOMAIN/`)

Exit code 0 only if every script succeeded; failures never abort the run early.

The list is read into memory before the loop starts, so the sync in step 3 cannot change what
runs mid-pass. It then re-reads `scripts-config.txt`, and if the sync changed the list, **runs
the whole new list again in its configured order** — so a release that adds, removes or
reorders an ensure-script converges in the same cycle, with its ordering rules already in
force. The second pass is the verdict that is reported. A script the first list named but the
update removed is skipped, not failed.

### Migrations

`scripts/migrations/` holds one-shot scripts that adapt an already-installed box to a new
template version — renaming an `.env` key, dropping a retired service, minting a secret a new
service needs. `ensure-template-sync.sh` runs them from the **downloaded** tree, before it is
swapped in and before any file is copied to its live location, so they can prepare state for a
version that is not on disk yet. A failure aborts the sync with nothing propagated: the box
stays on its current version.

Markers live in `${DATA_ROOT}/AppData/mesh/migration-markers/`. See
`scripts/migrations/README.md` for the naming convention and the rules.

### Configuration (`.env` keys)

| Key | Default | Purpose |
|-----|---------|---------|
| `PROVIDER_STR` | _(required)_ | Provider connection string, `<backend_url>,<userid>,<signature>`. Written by `install.sh --provider` |
| `DOMAIN` | _(required)_ | This box's domain, e.g. `alice.nsl.sh` |
| `DEFAULT_PWD` | _(generated)_ | Platform secret handed to installed apps as `$APP_DEFAULT_PASSWORD` / `$PCS_DEFAULT_PASSWORD`. Generated once and never rotated — regenerating invalidates every app's DB password and admin token. **Not the login password** — see "Claiming the login" |
| `LOCAL_ADMIN_USER` | _(set at claim)_ | The owner's chosen username. Written by `authelia-user-manager.sh claim`; `ensure-authelia.sh` reads it to keep the right account's email in step with `EMAIL` |
| `DEX_SESSION_KEY` | _(generated)_ | AES key encrypting Dex's session cookie. Rotating it costs one round of re-logins |
| `MESH_CONSOLE_ASSERTION_SECRET` | _(generated)_ | Shared by the mesh-console gate (signs the identity assertion) and app (verifies it). Deleting it re-mints it on the next self-check |
| `AUTH_CONSOLE_ASSERTION_SECRET` | _(generated)_ | Shared by the auth-console gate (signs the identity assertion, verifies session-revocation requests) and app. Minted by `ensure-auth-stack.sh`; deleting it re-mints it and only logs everyone out of the console |
| `MESH_AUTO_UPDATE` | `true` (`false` for `--local` installs) | Set `false` to opt out of template sync — the stack stays pinned, the rest of the self-check still runs. Update such a box by re-running `install.sh` with no arguments (see [Manual update](#manual-update-installsh-with-no-arguments)) |
| `UPDATE_URL` | stable branch tarball | **Full** URL the nightly sync pulls from. Set at install via `--channel` / `--update-url`. Must be `.tar.gz` |
| `SELF_CHECK_CRON` | `0 3 * * *` | Nightly schedule; `disabled` removes the cron entry |
| `MESH_UPDATE_CHANNEL` / `MESH_TEMPLATE_URL` | _(unset)_ | **Deprecated** pre-rename keys, still read as fallbacks for one release. Migrated to `UPDATE_URL` automatically |
| `DEFAULT_SERVICE_HOST` | `casaos` | Container answering on the root domain and the custom-domain catch-all. Must be on the `pcs` network — see [Root domain routing](#root-domain-routing) |
| `DEFAULT_SERVICE_PORT` | `8080` | Port that container listens on |
| `PUBLIC_IP_MODE` | `egress` | How `ensure-public-ip.sh` finds this box's address. `egress`: ask the outside world which address the box connects from — right behind NAT (a home server with forwarded ports). `interface`: take the globally-routable address on a local interface and nothing else — right for a cloud VM, where the egress address can be an upstream NAT gateway that is not this machine; an address the backend cannot ping is dropped, and IPv6 is used when the box has no public IPv4 of its own |
| `BRAND_NAME` | _(unset)_ | Product name shown as the TOTP issuer and on the password-reset mail. Unset, the box names itself by its domain |
| `DEX_THEME_SRC` | _(unset)_ | Directory shaped like `dex-theme/` (`templates/*.html`, `themes/<name>/`) that replaces the login UI |
| `PLATFORM_PROJECTS` | `mesh,auth,maison,mesh-console` | Compose projects Mesh Console lists as platform containers |
| `OPERATOR_API`, `TRUSTED_PUBKEY_HOST_SUFFIXES` | _(unset)_ | For a box run by an operator: the control-plane URL the Access page reads the support SSH key from, and the key-comment host suffixes it marks as trusted. Inert when empty |
| `BACKUP_ENGINE_CONTAINER` | `backup-engine` | Resident backup engine Maison execs into, for a deployment that ships one |

`PROVIDER_STR`, `DEFAULT_PWD` and `SELF_CHECK_CRON` were previously named `PROVIDER`,
`DEFAULT_PASSWORD` and `MESH_SELF_CHECK_CRON`. Existing boxes are renamed in place by
`scripts/migrations/2026-08-02-01-rename-env-keys.sh` (values are moved, never regenerated);
`ensure-env-valid.sh` carries the same fix as a fallback for boxes the migration never reaches
(`MESH_AUTO_UPDATE=false`). The names match `Yundera/template-root`, which is where they came
from — see [doc/alignment-with-template-root.md](doc/alignment-with-template-root.md).

Because the compose file and `Caddyfile` are template-owned, **hand-edits to the live
`docker-compose.yml` or `${DATA_ROOT}/AppData/mesh/Caddyfile` are lost on the next sync** —
pin with `MESH_AUTO_UPDATE=false` if you need local changes. `.env` is the supported knob:
it is only ever backfilled, never overwritten.

### Manual run

```bash
sudo bash /DATA/AppData/mesh/scripts/self-check.sh            # streams full output
sudo bash /DATA/AppData/mesh/scripts/self-check.sh --display  # per-step checklist
tail -f /DATA/AppData/mesh/log/mesh.log
```

Script updates take effect one run late by design: the sync copies new scripts during run N,
the new versions execute on run N+1.

## Uninstall

```bash
curl -fsSL https://nsl.sh/dashboard/uninstall.sh | sudo bash -s -- --yes
# or from the synced template already on the box:
sudo bash /DATA/AppData/mesh/template/uninstall.sh
```

`uninstall.sh` stops and removes the `mesh`, `auth` and `maison` stacks and their volumes,
removes the nightly self-check cron entry and `/etc/logrotate.d/mesh-router`, and deletes
`/DATA/AppData/mesh` (which holds the auth stack's data too), `/DATA/AppData/maison`, the auth
stack's generated files in `/DATA/AppData/auth`, and the compatibility symlink left at the old
`/DATA/AppData/casaos/apps/mesh` path.
It never touches Docker, user-installed apps, or user data (`/DATA/Documents`, `/DATA/Downloads`,
`/DATA/Media`, other `/DATA/AppData` apps). Run without `--yes` for an interactive confirmation.

## License

MIT
