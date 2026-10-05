# maison stack

The box's dashboard: the app grid and the app store, in a single Go binary that drives
the host Docker socket. It reads the CasaOS app-store format unchanged. Maison has **no
authentication of its own**, so an AppShield gate in the same stack is the only way in.

| Host | Serves |
|---|---|
| `maison-${DOMAIN}` | The gate, then the dashboard |
| `${DOMAIN}` (bare) | Also Maison by default, through the Caddyfile's root route (`DEFAULT_SERVICE_HOST=maison`) |

The gate also answers on the `-${PUBLIC_IP_DASH}.nip.io` and `.sslip.io` variants.

Deployed to `${DATA_ROOT}/AppData/maison` (project name `maison`). This README is copied
there on every deploy.

## Services

| Container | Image | Networks | Role |
|---|---|---|---|
| `maison` | `appshield` | `pcs` | AppShield gate. Owns the `caddy_*` labels, listens on `80`, runs as root |
| `maison-app` | `maison` | `pcs` | The dashboard on `8080`. Holds the Docker socket, `${DATA_ROOT}` (rshared) and the host's `/proc` read-only |

**The names matter.** auth-registrar derives the gate's `client_id` from the caller's
container name, through a PTR lookup on `pcs`, and only allows redirect URIs under
`<client_id>-<suffix>`. The gate therefore has to be called `maison`, which leaves the
`-app` suffix for the backend. If the gate were called `maison-gate`, its callbacks
would go to an unrouted host.

Pin rules, explained in full in `docker-compose.yml`:

- **The Maison image pin and `APPSTORE_URL` move together.** Store assets use
  compose-relative paths, which only Maison 1.1.21 or later resolves. An older image
  shows an iconless grid.
- **The image pin and `x-compose-app.view: system` move together.** Before 1.1.5
  Maison ignores `view` and leaves the stack unprotected.
- The `SMTP_*` keys need Maison 1.1.23 or later, and `.env.app` needs an image that
  reads it. An older image expects `REF_NET` and attaches apps to no network.

## How it is built

`ensure-maison-stack.sh`, which runs after `ensure-auth-stack.sh`, does this:

```
DOCKER_GID     stat -c %g /var/run/docker.sock        → passed to deploy-stack.sh
TZ             /etc/timezone or /etc/localtime        → passed to deploy-stack.sh
.env.app       mesh .env (DOMAIN, PUBLIC_IP*, EMAIL, DEFAULT_PWD)
                                                      → maison/.env.app   (tmp + mv, 0600)
tools/deploy-stack.sh maison … DOCKER_GID=… TZ=…:
  stacks/maison/docker-compose.yml → maison/docker-compose.yml
  stacks/maison/icon.png           → maison/.icon.png
  stacks/maison/README.md          → maison/README.md
  mesh .env, filtered to the compose's keys, + the two keys → maison/.env
  pull → evict name squatters → up
```

- **`.env`** is what the stack needs to run itself: `DOCKER_GID` (added through
  `group_add` so Maison can use the socket), `TZ`, `APPSTORE_URL`, `SMTP_TO`, and so on.
  Because the whole mesh `.env` is copied in, setting `APPSTORE_URL` there overrides
  the default. That only applies on boot: once someone edits the source list in the
  dashboard, Maison stores that list, and it wins.
- **`.env.app`** is what every installed app *receives*: `APP_NET=pcs`,
  `APP_DATA_ROOT`, `APP_DOMAIN`/`domain`, the `APP_PUBLIC_IP*` keys, `APP_EMAIL`,
  `APP_DEFAULT_PASSWORD`/`DefaultPassword`. Maison forwards these into each app's own
  `.env` at install time and again on every start, so apps follow the box when its
  domain or IP changes. The file is written **before** the first deploy. Without it,
  Maison falls back to its standalone default (`APP_NET=mesh`, no domain), and every
  app would fail to start.
- **`DATA_HOST_PATH` must equal `DATA_ROOT`.** Maison opens each app's
  `com.docker.compose.project.working_dir` label, which is a host path, without
  remapping it.

## How it tiles itself

Maison scans `${DATA_ROOT}/AppData` for managed apps and skips any folder whose name
contains a dot. The folder name is `maison`, with no dot, so the dashboard lists itself.
That is deliberate: the stack is not hidden.

The trailing `x-compose-app` block is the tile's metadata, and Maison reads it field by
field in preference to `x-casaos`:

- `view: system` puts the tile in the System grid and makes Maison **refuse to stop or
  uninstall** it. Restart is still offered.
- `webui-host: maison-${DOMAIN}` is the **only** field Maison substitutes `${DOMAIN}`
  into. Maison parses compose with a plain YAML unmarshal and never interpolates
  anything else. It points at the gate and must match `caddy_0`.
- The tile image comes from `.icon.png`, which deploy-stack.sh copies in. The `icon:`
  URL is only a fallback.

## How a login works

The gate registers itself with `http://auth-registrar:9092` on the first login, so no
client id or secret is injected. The registrar returns `internal_issuer_url`
(`http://dex:5556`), and the gate (AppShield 3.1.0 or later) uses it for discovery, the
token exchange and JWKS, so those calls stay on `pcs`. The browser still sees
`https://auth-${DOMAIN}`. While Dex is absent (an unclaimed box), the gate shows its
"sign-in unavailable" page.

Because the gate also serves the bare `${DOMAIN}`, which `REDIRECT_HOST_SUFFIXES`
cannot express, the registrar decides those callbacks (`ROOT_CLIENT_ID` in the auth
stack). `ALLOWED_PATHS` lets exactly `manifest.webmanifest` and `icons` through without
a session, so the PWA can be installed. Every identity header is still stripped on
those paths.

There is no machine/API path. If one is ever needed, set `OAUTH_RESOURCE` on the gate.
AppShield 3.0 removed `AUTH_HASH`.

## On disk

```
${DATA_ROOT}/AppData/maison/
├── docker-compose.yml  .env  .icon.png  README.md   regenerated every self-check — don't edit
├── .env.app                           regenerated every self-check (0600, holds DEFAULT_PWD)
├── settings.json, store cache, …      Maison's own STATE (STATE_DIR defaults to this folder)
└── gate-data/                         the gate's sessions.json and OAuth state
```

deploy-stack.sh only writes the compose file, `.env`, the icon and this README, so it
never touches Maison's state. Without the `gate-data` mount, recreating the container
would log everyone out. The gate runs as root (`0:0`) because Docker creates that
directory root-owned, and a non-root gate fails to persist sessions without saying so.

## What it needs from the other stacks

- **auth** — `auth-registrar` and `dex`, by name on `pcs`. This is why it deploys after
  `ensure-auth-stack.sh`.
- **mesh** — `mesh-router-caddy` routes `maison-*` and the bare domain. `smtp` is
  Maison's relay for backup-health and install mails (`SMTP_HOST=smtp`, no TLS, no
  auth). With no `SMTP_HOST`, nothing is sent.
- **`pcs` network** — external, created by `ensure_pcs_network`.

## Day-to-day

```bash
sudo bash /DATA/AppData/mesh/scripts/self-check/ensure-maison-stack.sh   # redeploy
cat /DATA/AppData/maison/.env.app                                        # what apps receive
docker logs maison        # gate: registration, sessions
docker logs maison-app    # dashboard, store fetches, app operations
```

## Known traps

| Symptom | Cause |
|---|---|
| Login lands on `maison-gate-…` or another unrouted host | The gate container was renamed. It must be `maison` |
| No app tiles at all | `DATA_HOST_PATH` ≠ `DATA_ROOT` |
| Store grid empty | `APPSTORE_URL` points at a deleted branch, or a persisted source list overrides it |
| Store grid iconless | Maison image older than the store's compose-relative assets |
| Apps start on no network / wrong domain | `.env.app` missing or stale. Re-run `ensure-maison-stack.sh` |
| Everyone logged out after a recreate | `gate-data` missing or not writable by the gate |
| Tile links to a literal `https://maison-${DOMAIN}/` | `${DOMAIN}` used in a metadata field other than `webui-host` |

**Never add `ports:`** to either service. Maison with the Docker socket and no
authentication amounts to root on the host.

## See also

- `docker-compose.yml`, the rationale behind every setting.
- `scripts/self-check/ensure-maison-stack.sh`, the `.env.app` contract.
- Maison's own `docs/app-env.md` and `docs/app-model.md`.
