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

### casaos

Container management UI for the PCS instance.

- Web-based Docker management
- Uses `%REF_DOMAIN%`, `%DATA_ROOT%`, `%DEFAULT_PASSWORD%`
- First-run account setup handled by CasaOS itself; `DEFAULT_PASSWORD` is the platform secret exposed to installed apps (not the CasaOS login)
- Accessible via the user's domain

### dex / casaos-oidc-bridge / auth-registrar (SSO)

Single sign-on for apps installed on the PCS. Apps (e.g. AppShield-gated apps)
delegate login via OIDC instead of holding their own credentials.

- **dex** — OIDC identity broker at `https://auth-${DOMAIN}` (discovery at
  `/.well-known/openid-configuration`). Renders a connector-chooser login page.
- **casaos-oidc-bridge** — small OIDC provider at `https://casaos-oidc-${DOMAIN}`
  that federates Dex's `casaos` connector to CasaOS's login API, so users log in
  with their CasaOS identity. CasaOS is left untouched.
- **auth-registrar** — apps self-register as OIDC clients (`POST /register` to
  `http://auth-registrar:9092`, internal only); the registrar creates the client
  in Dex over its gRPC API. A disposable break-glass admin (`staticPasswords`)
  exists for recovery when CasaOS is unreachable.
- Provisioned by `scripts/self-check/ensure-dex.sh` (renders Dex config, seeds
  `BRIDGE_SECRET` into `.env`, generates the break-glass admin). Data lives under
  `${DATA_ROOT}/AppData/mesh/dex` and is treated as cache (safe to delete; it
  self-heals on the next login). Dex's gRPC client API is unauthenticated and is
  therefore bound to the isolated `dex-internal` network, never `pcs`.

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
   casaos / other services
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

The chosen channel is persisted to `.env` as `MESH_UPDATE_CHANNEL`, and the nightly
self-check (`ensure-template-sync.sh`) reads it back, so a box keeps updating from the
channel it was installed with instead of drifting onto another branch.
`MESH_TEMPLATE_URL` (a full tarball URL) still overrides everything for forks/tags.

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
├── template/                     # pristine synced copy of this repo
├── scripts/                      # live scripts (self-check.sh, library/, self-check/)
├── log/mesh.log                  # self-check log (logrotate: daily, 7 days)
└── data/                         # runtime state: certs, caddy
```

### What runs (in order, from `scripts/self-check/scripts-config.txt`)

1. **Self-maintenance** — scripts executable, nightly cron entry, logrotate config
2. **Prerequisites** — Docker installed, `.env` valid (backfills missing optional keys)
3. **Template sync** — downloads this repo's channel tarball (`MESH_UPDATE_CHANNEL`,
   default `stable`), atomically swaps `template/`, copies `docker-compose.yml` and
   `scripts/` to their live locations (auto-update)
4. **Stack** — re-detect public IP (updates `.env` if changed), provision Dex SSO
   (`ensure-dex.sh`: render config, seed `BRIDGE_SECRET` + break-glass admin), `docker compose pull`, `up -d`
5. **Verification** (check-only) — routes registered with the backend, own domain reachable
   end-to-end (`curl -H 'X-Mesh-Trace: 1' https://$DOMAIN/`)

Exit code 0 only if every script succeeded; failures never abort the run early.

### Configuration (`.env` keys)

| Key | Default | Purpose |
|-----|---------|---------|
| `MESH_AUTO_UPDATE` | `true` (`false` for `--local` installs) | Set `false` to opt out of template sync — the stack stays pinned, the rest of the self-check still runs |
| `MESH_UPDATE_CHANNEL` | `stable` | Branch this box tracks (`stable` \| `main`). Set at install via `--channel`; the nightly sync honours it |
| `MESH_SELF_CHECK_CRON` | `0 3 * * *` | Nightly schedule; `disabled` removes the cron entry |
| `MESH_TEMPLATE_URL` | _(unset)_ | Full tarball URL that overrides `MESH_UPDATE_CHANNEL` entirely (forks/tags/dev) |

Because the compose file is template-owned, **hand-edits to the live `docker-compose.yml` are
lost on the next sync** — pin with `MESH_AUTO_UPDATE=false` if you need local changes.

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
