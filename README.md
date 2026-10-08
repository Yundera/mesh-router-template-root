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

## Stacks

The template deploys four compose stacks. Each has a README next to its compose file
that covers what the services do, how their config is rendered, what is state and
what is cache, and the known traps. The self-check copies each README into the
stack's folder on the box, next to the running compose file.

| Stack | Services | Source | On the box |
|---|---|---|---|
| `mesh` | mesh-router-tunnel, -agent, -caddy, smtp, mesh-console | `docker-compose.yml`, `Caddyfile` | `/DATA/AppData/mesh` — [README](stacks/mesh/README.md) |
| `auth` | dex, authelia, auth-registrar, auth-console | `stacks/auth/` | `/DATA/AppData/auth` — [README](stacks/auth/README.md) |
| `maison` | maison (gate), maison-app | `stacks/maison/` | `/DATA/AppData/maison` — [README](stacks/maison/README.md) |

Every stack joins the shared `pcs` bridge network as `external: true`. The self-check
creates that network (`ensure_pcs_network` in `scripts/library/common.sh`) before the
first stack comes up, so no stack owns it and the stacks can start in any order.
Requests reach the box through `mesh-router-tunnel` or `mesh-router-agent`, which hand
them to `mesh-router-caddy`. Caddy routes each hostname to a container using
the `caddy_*` labels on that container.

## Claiming the login

A newly-installed server seeds its owner account **unclaimed** — the account exists
but is disabled, and has **no Local Account connector** until it is claimed. With no
other connector either, Dex cannot start, so it is simply not running: every app's
sign-in page says sign-in is unavailable, and links to `SETUP_URL` when one is set.
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

- **`.env` is preserved key by key.** `DEFAULT_PWD` survives; regenerating it would
  invalidate every installed app's database password and admin token. The auth stack's
  own secrets (`AUTHELIA_DEX_SECRET`, `DEX_SESSION_KEY`, `AUTH_CONSOLE_ASSERTION_SECRET`)
  are in `/DATA/AppData/auth/.stack.env`, which the installer does not touch. There is deliberately no "reinstall from scratch"
  option in the prompt — to genuinely start over, run `uninstall.sh` first.
- **An already-claimed box is not asked about its owner account**, so the whole update is
  one keypress.
- **Pass `--domain` / `--provider` to change identity.** That is a deliberate change and
  skips the confirmation.
- **An update does not take the box offline.** The Linux installer stops the mesh stack
  only when the identity changes (`--domain` / `--provider` naming a different value) or
  with `--clean-restart`; a plain update lets the self-check recreate just the services
  whose definition changed, the way the nightly sync does. This is also how an operator
  adopts an existing box onto this template without an outage.
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
├── .stack.env                    # the stack's own secrets (DEX_SESSION_KEY, AUTHELIA_DEX_SECRET,
│                                 #   AUTH_CONSOLE_ASSERTION_SECRET); 0600, never regenerated
├── authelia/                     # users_database.yml, db.sqlite, configuration.yml, secrets/, oidc/
├── dex/                          # dex.db, config.yaml, connectors.d/, frontend/ (rendered login theme)
└── auth-console/gate-data/       # the console gate's sessions
/DATA/AppData/maison/            # the other auxiliary stack
```

### What runs (in order, from `scripts/self-check/scripts-config.txt`)

1. **Self-maintenance** — scripts executable, nightly cron entry, logrotate config
2. **Prerequisites** — Docker installed, `.env` valid (backfills missing optional keys)
3. **Template sync** — downloads the tarball at `UPDATE_URL` (default: the `stable`
   branch), runs any pending **migrations** from the downloaded tree, atomically
   swaps `template/`, copies `docker-compose.yml`, `Caddyfile` and `scripts/` to their live
   locations (auto-update)
4. **Stack** — re-detect public IP (updates `.env` if changed), provision Authelia
   (`ensure-authelia.sh`: secrets, JWKS key, config, owner-account seed, Local Account
   connector), provision Dex SSO (`ensure-dex.sh`: session key, render config, append connectors,
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
| `MESH_CONSOLE_ASSERTION_SECRET` | _(generated)_ | Shared by the mesh-console gate (signs the identity assertion) and app (verifies it). Deleting it re-mints it on the next self-check |
| `MESH_AUTO_UPDATE` | `true` (`false` for `--local` installs) | Set `false` to opt out of template sync — the stack stays pinned, the rest of the self-check still runs. Update such a box by re-running `install.sh` with no arguments (see [Manual update](#manual-update-installsh-with-no-arguments)) |
| `UPDATE_URL` | stable branch tarball | **Full** URL the nightly sync pulls from. Set at install via `--channel` / `--update-url`. Must be `.tar.gz` |
| `SELF_CHECK_CRON` | `0 3 * * *` | Nightly schedule; `disabled` removes the cron entry |
| `MESH_UPDATES_MANAGED_BY` | _(unset)_ | Name of an operator that drives this box's updates (e.g. `Yundera`). When set, the box cannot change its own source: `tools/set-update-channel.sh` exits `77`, a no-argument `install.sh` refuses, and Mesh Console's Update page is read-only ("managed by …"). The operator pins `UPDATE_URL` (typically a commit tarball, `…/archive/<sha>.tar.gz`) and runs the self-check itself, usually with `SELF_CHECK_CRON=disabled`. Running the self-check by hand stays available — it only syncs to the pinned source and repairs |
| `EMAIL_SYNC` | `true` | Set `false` when `EMAIL` is provisioned by an operator rather than looked up from the mesh backend: `ensure-email-synced.sh` then leaves it alone |
| `MESH_UPDATE_CHANNEL` / `MESH_TEMPLATE_URL` | _(unset)_ | **Deprecated** pre-rename keys, still read as fallbacks for one release. Migrated to `UPDATE_URL` automatically |
| `DEFAULT_SERVICE_HOST` | `maison` | Container answering on the root domain and the custom-domain catch-all. Must be on the `pcs` network — see [the mesh stack README](stacks/mesh/README.md) |
| `DEFAULT_SERVICE_PORT` | `80` | Port that container listens on |
| `PUBLIC_IP_MODE` | `egress` | How `ensure-public-ip.sh` finds this box's address. `egress`: ask the outside world which address the box connects from — right behind NAT (a home server with forwarded ports). `interface`: take the globally-routable address on a local interface and nothing else — right for a cloud VM, where the egress address can be an upstream NAT gateway that is not this machine; an address the backend cannot ping is dropped, and IPv6 is used when the box has no public IPv4 of its own |
| `BRAND_NAME` | _(unset)_ | Product name shown as the TOTP issuer and on the password-reset mail. Unset, the box names itself by its domain |
| `DEX_THEME_SRC` | _(unset)_ | Directory shaped like `dex-theme/` (`templates/*.html`, `themes/<name>/`) that replaces the login UI |
| `PLATFORM_PROJECTS` | `mesh,auth,maison` | Compose projects that are the platform, not user apps: Mesh Console lists them as platform containers, and `tools/migrate.sh` neither stops nor starts them as apps |
| `OPERATOR_API`, `TRUSTED_PUBKEY_HOST_SUFFIXES` | _(unset)_ | For a box run by an operator: the control-plane URL the Access page reads the support SSH key from, and the key-comment host suffixes it marks as trusted. Inert when empty |
| `SETUP_URL` | _(unset)_ | Where an owner finishes setting the box up. While no sign-in method exists yet (unclaimed, no drop-in connector) every app's sign-in page links there. Inert when empty |
| `BACKUP_ENGINE_CONTAINER` | `backup-engine` | Resident backup engine Maison execs into, for a deployment that ships one |

**Not in the `.env`: a stack's own state.** A secret an ensure-script mints for one stack
alone lives in that stack's folder, in `.stack.env` (0600, never regenerated). For the
auth stack, `/DATA/AppData/auth/.stack.env` holds `DEX_SESSION_KEY` (AES key for Dex's
session cookie; rotating it costs one round of re-logins), `AUTHELIA_DEX_SECRET` (the
Dex↔Authelia client secret; Authelia keeps only its hash) and
`AUTH_CONSOLE_ASSERTION_SECRET` (shared by the auth-console gate and app; deleting it
only logs everyone out of the console). Each stack's generated `.env` holds just the keys
its compose file interpolates, from the mesh `.env` and its `.stack.env`. A box that
predates this has the three in the mesh `.env`: the scripts that own them move them over
(`stack_env_adopt`, `scripts/library/common.sh`), saving the `.env` as it was to
`.env.<YYYY-MM-DD>.old` first.

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

## Moving the box to another machine

`scripts/tools/migrate.sh` moves a box (domain, apps, data) onto another machine. It runs
on the **old** box, which copies its data root over SSH, brings the new box up, moves the
domain across and retires itself. Mesh Console's Migration page drives the same script.
Design and reasons: [doc/migration.md](doc/migration.md).

```bash
sudo bash /DATA/AppData/mesh/scripts/tools/migrate.sh key                       # 1. this box's migration public key
sudo bash /DATA/AppData/mesh/scripts/tools/migrate.sh preflight --to migration@new-box   # 2. check the target
sudo bash /DATA/AppData/mesh/scripts/tools/migrate.sh start --to migration@new-box       # 3. go
sudo bash /DATA/AppData/mesh/scripts/tools/migrate.sh log -f                    # follow it (status | cancel)
```

**The target is yours to prepare; nothing is installed on it beforehand.** `preflight` checks:

- Ubuntu, reachable over SSH from this box
- an account (`migration` by convention) with the key from step 1 in its
  `~/.ssh/authorized_keys` and passwordless sudo (`<user> ALL=(ALL) NOPASSWD:ALL`)
- `rsync` installed
- free disk at least what this box uses, plus 5 GiB
- no box on it yet: `${DATA_ROOT}/AppData` absent or empty
- clocks within 60 s

Docker is installed by the target's own self-check during the migration.

What happens:

- The data is copied twice: once with apps running, then again with them stopped, so the
  downtime is the second, incremental copy.
- The target comes up with `MESH_ROUTING_HOLD` set, which keeps its agent and tunnel off
  the domain until it has been checked.
- The cutover stops this box's agent and tunnel and lets the target publish.
- This box ends **retired** (`MESH_ROUTING_HOLD=retired:<new-ip>`). Its self-check never
  brings routing back. To undo, delete the key from `.env` and run the self-check.
- Any failure rolls back, and this box serves again. The target is left as it is for you
  to inspect or wipe.
- Getting the new machine and deleting the old one are up to you.

| Key | Default | Purpose |
|---|---|---|
| `MESH_ROUTING_HOLD` | _(unset)_ | Set by `migrate.sh`. Keeps `mesh-router-agent` / `mesh-router-tunnel` absent: `migrating:<id>` during a migration, `retired:<ip>` on a box that was moved away |
| `MIGRATE_TARGET_SELF_CHECK` | _(unset)_ | A second self-check to run on the target after the mesh one, for a deployment with a template of its own |
| `MIGRATE_HOLD_LOCKS` | _(unset)_ | Comma-separated lock files `migrate.sh` holds for the whole run, so another self-check on this box skips meanwhile |

State lives in `${DATA_ROOT}/AppData/mesh/data/migrate/`: the key, `status.json` (steps,
copy progress, the result) and `migrate.log`. The directory is never copied. The target
gets the log and final status under `data/migrate/arrived/`.

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
