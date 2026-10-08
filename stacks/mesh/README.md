# mesh stack

The box's front door. It gets public traffic to the box (**mesh-router-agent** for direct
routes, **mesh-router-tunnel** over WireGuard), terminates TLS and routes by hostname
(**mesh-router-caddy**), relays app mail (**smtp**), and carries the stack's own web UI
(**mesh-console**). Every other stack is reached through it.

| Host | Serves |
|---|---|
| `${DOMAIN}` | Root domain → `DEFAULT_SERVICE_HOST:DEFAULT_SERVICE_PORT` (default `maison:80`) |
| `<name>-${DOMAIN}` | Any container on `pcs` with `caddy_*` labels |
| `mesh-console-${DOMAIN}` | Mesh Console: status, routing, updates, root-domain app (also the **Mesh Router** tile) |
| any unknown host pointed at the box | Catch-all → the same target as the root domain |

Each host also answers on the `-${PUBLIC_IP_DASH}.nip.io` and `.sslip.io` variants (the
root domain as the bare `${PUBLIC_IP_DASH}.nip.io` / `.sslip.io`).

Deployed to `${DATA_ROOT}/AppData/mesh` (project name `mesh`). Its compose file is the
repo-root `docker-compose.yml`. This README's source lives under `stacks/mesh/` because
the repo-root `README.md` documents the installer, and `ensure-template-sync.sh` copies
it to `${DATA_ROOT}/AppData/mesh/README.md` on every sync.

## Services

| Container | Image | Networks | Role |
|---|---|---|---|
| `mesh-router-agent` | `mesh-router-agent` | `pcs` | Registers direct routes (IP + nip.io/sslip.io) with the backend. Writes the mesh cert, key and CA |
| `mesh-router-tunnel` | `mesh-router-tunnel` | `pcs` | WireGuard tunnel to the gateway for NAT traversal. Forwards to Caddy on 80/443 |
| `mesh-router-caddy` | `mesh-router-caddy` | `pcs` | Caddy + caddy-docker-proxy. **The only service publishing host ports** (80, 443) |
| `smtp` | `mail-gateway` | `pcs` | SMTP on `587` for apps; relays each mail to the backend |
| `mesh-console` | `appshield` | `pcs` | AppShield gate, the only public route to the console. Admins only |
| `mesh-console-app` | `mesh-console` | `pcs` | Console backend. Holds the Docker socket, reads the mesh root `:ro` |

All images are pinned to exact versions in `docker-compose.yml`. A tag that is not yet
published costs every self-check the pull backoff, so publish before moving a pin.

**The transition shim.** `PROVIDER=${PROVIDER_STR:-${PROVIDER}}` (and the same for
`DEFAULT_PWD`) reads the new key with the old one as a fallback. On an update from a
pre-rename template, the new compose file is brought up in the same cycle, before the
rename migration has had a chance to run. Without the fallback, agent and tunnel start
with an empty provider string and the box goes dark once the ~600 s route TTL runs out.
Drop the `:-${OLD}` halves one release after the rename has rolled out (header of
`docker-compose.yml`).

## How it is built

Each self-check, in order (from `scripts/self-check/scripts-config.txt`):

```
ensure-env-valid.sh      fail if PROVIDER_STR / DOMAIN are empty; backfill optional keys
                         (DEFAULT_SERVICE_HOST=maison, …=PORT 80, EMAIL=admin@${DOMAIN}, …);
                         heal renamed keys; repoint a dead `casaos` root target to maison:80;
                         keep PUBLIC_IP_DASH in step with PUBLIC_IP
ensure-template-sync.sh  download UPDATE_URL tarball → run pending migrations from it →
                         swap template/ → copy Caddyfile (in place), docker-compose.yml,
                         stacks/mesh/README.md and scripts/ to the live locations
                         (no-op when MESH_AUTO_UPDATE=false)
ensure-public-ip.sh      PUBLIC_IP(_DASH), PUBLIC_IPV4/6(_DASH) → .env (PUBLIC_IP_MODE=egress|interface,
                         checked by a reachability probe from the backend)
ensure-email-synced.sh   account EMAIL from the backend → .env (best effort, EMAIL_SYNC=false to skip)
ensure-authelia.sh, ensure-dex.sh   (auth stack renders, see stacks/auth/README.md)
ensure-stack-pulled.sh   docker compose pull
ensure-stack-up.sh       restore a missing Caddyfile from template/; move a legacy CA out of
                         data/certs into data/ca; mint MESH_CONSOLE_ASSERTION_SECRET;
                         ensure_pcs_network; evict name squatters; up -d --remove-orphans;
                         wait for the stack to settle; wait for the agent to write the CA
… auth, maison stacks …
ensure-root-domain.sh    check only: https://${DOMAIN} answers
ensure-route-registered.sh  check only: the backend has live routes for this user
```

Script updates take effect one run late: the sync copies new scripts during run N, and
they execute on run N+1. Migrations run from the *downloaded* tree before anything is
copied, so a failed migration leaves the box on its current version.

## Routing

**Agent and tunnel.** Both authenticate with `PROVIDER_STR` =
`<backend_url>,<userid>,<signature>`, an Ed25519 signature over the userid. The backend
verifies it against the stored public key. The agent registers this box's direct routes
(`PUBLIC_IP` and its nip.io / sslip.io forms). The tunnel registers a WireGuard route as
the fallback when the box is not directly reachable. Routes expire after ~10 minutes and
both services re-register on their own loops. The gateway prefers direct and falls back
to the tunnel.

**Caddy.** The base config is the repo's `Caddyfile`, copied to
`${DATA_ROOT}/AppData/mesh/Caddyfile` and bind-mounted read-only. It contains:

- **Global options.** ACME pinned to Let's Encrypt, with an internal-CA fallback (168 h
  leaves) that stops the retry storm on unissuable hostnames.
- **`(gateway_tls)`.** Serves the mesh certificate (`/certs/cert.pem`, `key.pem`, written
  by the agent), which the gateways trust. It also restores `Host` from
  `X-Original-Host`, because the CF worker rewrites `Host` to the nip.io name.
- **The three root addresses**, nothing else.

Everything else comes from container labels, via caddy-docker-proxy on the `pcs`
network (`CADDY_INGRESS_NETWORKS=pcs`). Every web service carries the same triple:

```yaml
labels:
  caddy_0: app-${DOMAIN}                       # via the gateway — mesh cert
  caddy_0.import: gateway_tls
  caddy_0.reverse_proxy: "{{upstreams 8080}}"
  caddy_1: app-${PUBLIC_IP_DASH}.nip.io        # REQUIRED: what CF-worker traffic matches — mesh cert
  caddy_1.import: gateway_tls
  caddy_1.reverse_proxy: "{{upstreams 8080}}"
  caddy_2: app-${PUBLIC_IP_DASH}.sslip.io      # direct — Let's Encrypt, so no import
  caddy_2.reverse_proxy: "{{upstreams 8080}}"
```

**Root domain.** `${DOMAIN}`, `${PUBLIC_IP_DASH}.nip.io` and `${PUBLIC_IP_DASH}.sslip.io`
are defined **only** in the Caddyfile and reverse-proxy to
`DEFAULT_SERVICE_HOST:DEFAULT_SERVICE_PORT`. The same target serves the custom-domain
catch-all, which the mesh-router-caddy entrypoint injects through the Admin API because
caddy-docker-proxy would drop it from the file. Responses from the catch-all carry
`X-Mesh-Catchall`. To change the target:

```bash
sudo /DATA/AppData/mesh/scripts/tools/set-default-app.sh <container> <port>
```

The script writes both keys to `.env`, then re-runs `ensure-stack-up.sh` (Caddy) and
`ensure-auth-stack.sh` (the auth-registrar's `ROOT_CLIENT_ID`, so a login on the bare
domain comes back to the bare domain). It exits `75` while a self-check is running.
Mesh Console's default-app editor calls this same script.

- The target must be on `pcs`, or the root domain answers 502 with nothing to explain
  why. `ensure-root-domain.sh` checks for exactly that.
- **No container may claim a root address with a label.** caddy-docker-proxy merges site
  blocks that share an address, so a second claim gives the apex two `reverse_proxy`
  handlers.

## Mail (`smtp`)

Apps send to `smtp:587` on `pcs`, without authentication. The mail-gateway POSTs each
message to `<backend_url>/router/api/email/send` with `userid:signature` from
`PROVIDER_STR` as the Bearer credential. The backend sends it from
`<app>.<user-domain>@<server-domain>`. Delivery stats for Mesh Console's Email page are
kept in the `mesh_smtp-data` volume. Authelia's password-reset mail goes through this
relay too.

## Mesh Console

There are three parts: the `mesh-console` gate, the `mesh-console-app` backend, and a
one-shot privileged `mesh-console-runner` container in the host's namespaces, started by
the app for host actions. The only host actions are the template's own
`scripts/self-check.sh` ("Update now"), `scripts/tools/set-default-app.sh`,
`scripts/tools/set-update-channel.sh` (the Update page's channel picker) and
`scripts/tools/migrate.sh`. There is no generic command path.

- **Admins only, checked twice.** The gate requires `OIDC_REQUIRED_GROUPS=admins`. The
  app verifies the gate's signed `X-AppShield-Assertion`
  (`MESH_CONSOLE_ASSERTION_SECRET`, audience `mesh-console`) and the group again. Plain
  headers prove nothing, because every container on `pcs` can reach the app.
- **Names are load-bearing.** The registrar derives the client_id from the gate's
  container name, so the gate owns `mesh-console` and the backend takes `-app`.
- **Never add `ports:`** to either service. The app holds the Docker socket.
- The Update page compares `template/.revision.json` (`{url, commit, synced_at}`, written
  by the sync) with the head of the `UPDATE_URL` branch.
- The channel picker calls `set-update-channel.sh <stable|dev|local|custom> [url]`: it
  writes `UPDATE_URL` / `MESH_AUTO_UPDATE` (`local` = downloads off) and exits `75` while a
  self-check runs. It never downloads; the next self-check syncs from the new source.
- With `MESH_UPDATES_MANAGED_BY` set, the Update page is read-only ("managed by …"): the
  picker is disabled, the script exits `77`, and the GitHub "latest" lookup is skipped (the
  operator decides the version). "Update now" stays: it syncs to the pinned source and repairs.
- The gate's OIDC back-channel stays on the box: the registrar hands it
  `internal_issuer_url: http://dex:5556`.

## On disk

```
${DATA_ROOT}/AppData/mesh/
├── docker-compose.yml  Caddyfile  README.md   template-owned — overwritten by every sync
├── .env                          THE config — backfilled, never overwritten. Source of every stack's .env
├── template/                     pristine copy of this repo (+ .revision.json)
├── scripts/                      live scripts — self-check.sh, library/, self-check/, tools/, migrations/
├── migration-markers/            one marker per applied migration
├── log/mesh.log                  self-check log (logrotate: daily, 7 days)
├── data/
│   ├── certs/                    mesh cert + key — agent writes, Caddy reads :ro (re-fetched at agent start)
│   ├── ca/                       the mesh CA alone — agent writes, Dex reads :ro
│   └── caddy/{data,config}       Caddy's ACME state — cache, rebuilt on loss (Let's Encrypt rate limits apply)
└── mesh-console/gate-data/       the console gate's sessions
docker volume mesh_smtp-data      mail delivery stats
```

`.env` is the only state that matters. It holds `PROVIDER_STR`, `DEFAULT_PWD` (handed
to every app, never rotate it) and `MESH_CONSOLE_ASSERTION_SECRET`. The auth stack's
secrets are in `/DATA/AppData/auth/.stack.env`. Hand-edits to the live
`docker-compose.yml` or `Caddyfile` are lost on the next sync. Set
`MESH_AUTO_UPDATE=false` to keep local changes.

## What the other stacks need from it

- **The `pcs` network.** External, created by `ensure_pcs_network` in
  `ensure-stack-up.sh` and owned by no stack. Every stack (mesh, auth, maison) joins
  it, so `down` on one never deletes it under the others.
- **Routing.** Caddy reaches every service by its `caddy_*` labels over `pcs`.
- **The `.env`.** `deploy-stack.sh` generates each auxiliary stack's `.env` from this one
  and the stack's own `.stack.env`, keeping only the keys that stack's compose interpolates.
- **The mesh CA** (`data/ca`) for Dex's on-box call to Authelia, and **`smtp`** for
  Authelia's reset mail.
- **Order.** This stack comes up before auth and maison. Nothing uses
  `depends_on` across projects.

## Day-to-day

```bash
sudo bash /DATA/AppData/mesh/scripts/self-check.sh            # full run, streams output
sudo bash /DATA/AppData/mesh/scripts/self-check.sh --display  # per-step checklist
tail -f /DATA/AppData/mesh/log/mesh.log

cd /DATA/AppData/mesh && docker compose ps
docker logs mesh-router-agent     # registration, cert fetch
docker logs mesh-router-caddy     # ACME, generated config

# how traffic reaches the box
curl -s -D- -o /dev/null -H 'X-Mesh-Trace: 1' https://<domain>/ | grep -i x-mesh-route
curl -s -D- -o /dev/null -H 'X-Mesh-Force: tunnel' -H 'X-Mesh-Trace: 1' https://<domain>/
```

## Known traps

| Symptom | Cause |
|---|---|
| Caddy won't start: `Caddyfile … not a directory` | `compose up` ran before the file existed and Docker created a directory. `ensure-stack-up.sh` removes it and restores the file |
| Root domain 502, every `<app>-${DOMAIN}` fine | `DEFAULT_SERVICE_HOST` is not on `pcs` (or a typo). `ensure-root-domain.sh` reports it |
| Apex serves the wrong app, or both | A container claims a root address with a `caddy_*` label |
| `<app>-${DOMAIN}` works via sslip.io but not via the domain | `caddy_1` (nip.io) label missing. The CF worker routes on it |
| Caddyfile edit not picked up | It was replaced with `mv`: a single-file bind mount pins the inode. Copy in place |
| Box goes dark ~10 min after an update | Agent/tunnel started with an empty `PROVIDER`; see the transition shim |
| `no routes registered` | Bad `PROVIDER_STR` signature or backend down. `docker logs mesh-router-agent` |
| Wrong public IP registered on a cloud VM | `PUBLIC_IP_MODE=egress` picked an upstream SNAT address. Use `interface` |
| Mesh Console answers 403 / refuses everything | Not in `admins`, or `MESH_CONSOLE_ASSERTION_SECRET` unset (re-minted on the next self-check) |

## See also

- `docker-compose.yml` and `Caddyfile`: the rationale behind every setting.
- `scripts/self-check/ensure-*.sh`: their headers. `scripts/tools/set-default-app.sh`.
- The repo `README.md`: install, update channels, `.env` keys, migrations, uninstall.
- `stacks/auth/README.md`: SSO, which every gate here depends on.
