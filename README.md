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
# /DATA/AppData/casaos/apps/mesh/.env
DEFAULT_SERVICE_HOST=my-app     # container name, or host.docker.internal for a host port
DEFAULT_SERVICE_PORT=3000
```

then `cd /DATA/AppData/casaos/apps/mesh && docker compose up -d`.

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
part of the mesh stack — it attaches to the `pcs` network the mesh stack owns.

- Reachable at `maison-${DOMAIN}` (plus the `nip.io` / `sslip.io` variants), and it is
  what the root domain points at by default (`DEFAULT_SERVICE_HOST=maison`).
- **No authentication of its own** and it mounts the Docker socket, so it is never
  published: the AppShield gate in the same stack is the only route in, and that gate
  federates through Dex to Authelia. Never add a `ports:` mapping to it.
- What apps receive on install — network, domain, public IP, default password — comes
  from `${DATA_ROOT}/AppData/maison/.env.app`, regenerated from the mesh `.env` on
  every self-check.
- Apps installed by CasaOS before it was removed still live under
  `/DATA/AppData/casaos/apps/<app>`. `ensure-maison-app-mirror.sh` projects them into
  Maison's layout so they are manageable rather than merely visible.

### dex / authelia / auth-registrar (SSO)

Single sign-on for apps installed on the PCS. Apps delegate login via OIDC instead of
holding their own credentials.

- **dex** — OIDC identity broker at `https://auth-${DOMAIN}` (discovery at
  `/.well-known/openid-configuration`). A pure broker: it holds no credential of its
  own, and renders a connector-chooser login page.
- **authelia** — the PCS-local credential store at `https://local-auth-${DOMAIN}`,
  federated by Dex as the "Local Account" connector. Owns the account that used to
  live in CasaOS, seeded from `DEFAULT_PWD` as user `admin`. Its own login page
  carries the password-reset link, which mails through the `smtp` relay in this stack.
  Exactly one OIDC client (Dex); per-app clients stay on Dex's gRPC path.
- **auth-registrar** — apps self-register as OIDC clients (`POST /register` to
  `http://auth-registrar:9092`, internal only); the registrar creates the client in Dex
  over its gRPC API. Caller identity comes from a PTR lookup of the source container
  name, never from the request body.
- Provisioned by `ensure-authelia.sh` (secrets, JWKS key, config, admin seed) and
  `ensure-dex.sh` (config render), in that order — Authelia mints the
  `AUTHELIA_DEX_SECRET` that Dex's connector needs. Dex's data under
  `${DATA_ROOT}/AppData/mesh/dex` is cache and safe to delete; Authelia's under
  `${DATA_ROOT}/AppData/mesh/auth` holds the local account — back it up.
- Dex's gRPC client API is unauthenticated and is therefore bound to the isolated
  `dex-internal` network, never `pcs`.

**REMOVED:** `casaos`, and with it `casaos-oidc-bridge` and the disposable Dex
break-glass admin. Authelia is the local credential now, so the bridge was a second
identity for the same person and the break-glass account had nothing left to recover
from. See [doc/alignment-with-template-root.md](doc/alignment-with-template-root.md).

## Network Configuration

All services connect via the `pcs` bridge network, enabling internal communication:

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

### Layout

```
/DATA/AppData/casaos/apps/mesh/   # CasaOS-visible surface only
├── docker-compose.yml            # template-owned: overwritten by auto-update
└── .env                          # user-owned: never touched by auto-update

${DATA_ROOT}/AppData/mesh/
├── Caddyfile                     # template-owned: base caddy config, bind-mounted read-only
├── template/                     # pristine synced copy of this repo
├── scripts/                      # live scripts (self-check.sh, library/, self-check/, tools/, migrations/)
├── migration-markers/            # one marker per applied migration
├── log/mesh.log                  # self-check log (logrotate: daily, 7 days)
└── data/                         # runtime state: certs, caddy
```

### What runs (in order, from `scripts/self-check/scripts-config.txt`)

1. **Self-maintenance** — scripts executable, nightly cron entry, logrotate config
2. **Prerequisites** — Docker installed, `.env` valid (backfills missing optional keys)
3. **Template sync** — downloads the tarball at `UPDATE_URL` (default: the `stable`
   branch), runs any pending **migrations** from the downloaded tree, atomically
   swaps `template/`, copies `docker-compose.yml`, `Caddyfile` and `scripts/` to their live
   locations (auto-update)
4. **Stack** — re-detect public IP (updates `.env` if changed), provision Dex SSO
   (`ensure-dex.sh`: render config, seed `BRIDGE_SECRET` + break-glass admin), `docker compose pull`, `up -d`
5. **Verification** (check-only) — routes registered with the backend, own domain reachable
   end-to-end (`curl -H 'X-Mesh-Trace: 1' https://$DOMAIN/`)

Exit code 0 only if every script succeeded; failures never abort the run early.

The list is read into memory before the loop starts, so the sync in step 3 cannot change what
runs mid-pass. A **second pass** then re-reads `scripts-config.txt` and runs any entry the
first pass did not, so a release that adds an ensure-script converges in the same cycle. Newly
added scripts run after the existing ones regardless of their position in the file; their
declared order takes effect from the next cycle.

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
| `DEFAULT_PWD` | _(generated)_ | Platform secret handed to installed apps as `$APP_DEFAULT_PASSWORD` / `$PCS_DEFAULT_PASSWORD`. Generated once and never rotated — regenerating invalidates every app's DB password and admin token |
| `MESH_AUTO_UPDATE` | `true` (`false` for `--local` installs) | Set `false` to opt out of template sync — the stack stays pinned, the rest of the self-check still runs |
| `UPDATE_URL` | stable branch tarball | **Full** URL the nightly sync pulls from. Set at install via `--channel` / `--update-url`. Must be `.tar.gz` |
| `SELF_CHECK_CRON` | `0 3 * * *` | Nightly schedule; `disabled` removes the cron entry |
| `MESH_UPDATE_CHANNEL` / `MESH_TEMPLATE_URL` | _(unset)_ | **Deprecated** pre-rename keys, still read as fallbacks for one release. Migrated to `UPDATE_URL` automatically |
| `DEFAULT_SERVICE_HOST` | `casaos` | Container answering on the root domain and the custom-domain catch-all. Must be on the `pcs` network — see [Root domain routing](#root-domain-routing) |
| `DEFAULT_SERVICE_PORT` | `8080` | Port that container listens on |

`PROVIDER_STR`, `DEFAULT_PWD` and `SELF_CHECK_CRON` were previously named `PROVIDER`,
`DEFAULT_PASSWORD` and `MESH_SELF_CHECK_CRON`. Existing boxes are renamed in place by
`scripts/migrations/2026-08-02-01-rename-env-keys.sh` (values are moved, never regenerated);
`ensure-env-valid.sh` carries the same fix as a fallback for boxes the migration never reaches
(`MESH_AUTO_UPDATE=false`). The names now match `Yundera/template-root` so the same admin app
can run against both — see [doc/alignment-with-template-root.md](doc/alignment-with-template-root.md).

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

`uninstall.sh` stops and removes the `mesh` stack (tunnel, agent, caddy, smtp, casaos) and its
caddy volumes, removes the nightly self-check cron entry and `/etc/logrotate.d/mesh-router`, and
deletes the two mesh folders (`/DATA/AppData/casaos/apps/mesh` and `${DATA_ROOT}/AppData/mesh`).
It never touches Docker, user-installed apps, or user data (`/DATA/Documents`, `/DATA/Downloads`,
`/DATA/Media`, other `/DATA/AppData` apps). Run without `--yes` for an interactive confirmation.

## License

MIT
