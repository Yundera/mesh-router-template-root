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

## Publishing updates

The dashboard's install command curls `install.sh` from jsDelivr:

```
https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh
```

`install.sh` no longer fetches individual files from the CDN. It downloads the whole repo as a `main` tarball from GitHub, lays down `docker-compose.yml` + `scripts/`, then runs the self-check. The nightly self-check (`ensure-template-sync.sh`) re-syncs from the **same** GitHub tarball:

```
https://github.com/yundera/mesh-router-template-root/archive/refs/heads/main.tar.gz
```

GitHub serves that archive near-realtime (no 12-hour CDN cache), so pushes to `main` reach existing installs — compose **and** scripts — within minutes, no purge required.

Only `install.sh` itself sits behind jsDelivr's floating-`@main` cache (up to 12h). After changing `install.sh`, purge it so new installs pick it up:

```bash
curl "https://purge.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh"
```

Notes:
- Purge only works once commits are actually pushed to `origin/main`. It re-resolves `@main` against GitHub, so nothing to fetch = nothing changes.
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
3. **Template sync** — downloads this repo's `main` tarball, atomically swaps `template/`,
   copies `docker-compose.yml` and `scripts/` to their live locations (auto-update)
4. **Stack** — re-detect public IP (updates `.env` if changed), `docker compose pull`, `up -d`
5. **Verification** (check-only) — routes registered with the backend, own domain reachable
   end-to-end (`curl -H 'X-Mesh-Trace: 1' https://$DOMAIN/`)

Exit code 0 only if every script succeeded; failures never abort the run early.

### Configuration (`.env` keys)

| Key | Default | Purpose |
|-----|---------|---------|
| `MESH_AUTO_UPDATE` | `true` (`false` for `--local` installs) | Set `false` to opt out of template sync — the stack stays pinned, the rest of the self-check still runs |
| `MESH_SELF_CHECK_CRON` | `0 3 * * *` | Nightly schedule; `disabled` removes the cron entry |
| `MESH_TEMPLATE_URL` | repo `main` tarball | Override the sync source (dev/testing) |

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
