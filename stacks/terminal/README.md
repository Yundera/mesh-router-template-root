# terminal stack

A web shell into the host: a browser terminal (ttyd) behind an AppShield gate. Each
session is a real SSH login to the host, opened from inside the host's namespaces, so
the hostname, network, processes, login shell, sudo and systemd are all the host's.

This is the **app store's Terminal app**, shipped as a system app. The services are
copied from the store's `Apps/Terminal/docker-compose.yml` without changes. Only the
trailing metadata differs (`x-compose-app` with `view: system`, where the store has
`x-casaos`). **Change the app in the store and copy it back here. Do not let the two
copies drift.**

| Host | Serves |
|---|---|
| `terminal-${DOMAIN}` | The gate, then ttyd |

The gate also answers on the `-${PUBLIC_IP_DASH}.nip.io` and `.sslip.io` variants.

Deployed to `${DATA_ROOT}/AppData/terminal` (project name `terminal`), which is the same
folder and project a store install uses, so an app installed from the store is adopted
in place. This README is copied there on every deploy.

## Services

| Container | Image | Networks | Role |
|---|---|---|---|
| `terminal` | `appshield` (the store's pin) | `pcs`, `terminal-internal` | AppShield gate, the only route in |
| `terminaltty` (service `terminal-ttyd`) | `tsl0922/ttyd` | `terminal-internal` | ttyd on `7681`. `privileged`, `pid: host` |

The gate's `hostname: terminal` matters: AppShield builds its redirect URIs from
`os.hostname()`, and auth-registrar checks them against the container's PTR name.
ttyd lives only on the stack's private `terminal-internal` bridge, so nothing on `pcs`
can reach it except through the gate.

## How it is built

The app configures itself, so the deploying script only supplies variables:

```
ensure-terminal-stack.sh   (after ensure-auth-stack.sh)
  TERMINAL_ENABLED=false|0|no|off in the mesh .env → `compose down`, stop here
  tools/deploy-stack.sh terminal … APP_NET=pcs APP_DOMAIN=… domain=… APP_PUBLIC_IP_DASH=…
                                   TERMINAL_USER=${TERMINAL_USER:-root}:
    stacks/terminal/docker-compose.yml → terminal/docker-compose.yml
    stacks/terminal/icon.png           → terminal/.icon.png
    stacks/terminal/README.md          → terminal/README.md
    mesh .env (whole) + those keys     → terminal/.env
    pull → evict name squatters → up
```

The store compose reads the `APP_*` variables Maison gives every app, which the mesh
`.env` does not have, so they are passed explicitly.

### What happens at container start

The ttyd container's entrypoint does two things:

1. **`TERMINAL_SETUP`** runs as root in the host's mount namespace (`nsenter --target=1
   --mount`), using the host's own `/bin/sh` and tools. It is idempotent:
   - it generates an ed25519 key once, in `terminal/ssh/` (mode 700);
   - it keeps **exactly one** line for that key in the target user's
     `authorized_keys`, identified by the app's own key comment and restricted to
     `from="127.0.0.1,::1"` with no agent, port or X11 forwarding, and leaves every
     other line alone;
   - it rewrites `terminal/ssh/known_hosts` from the host's
     `/etc/ssh/ssh_host_*_key.pub`, so the client can check host keys strictly.
2. **ttyd** starts. For each browser session it runs `nsenter --target=1 --mount --uts
   --ipc --net --pid -- ssh … ${TERMINAL_USER}@localhost`, with `BatchMode`,
   `StrictHostKeyChecking=yes` and `HostKeyAlias=localhost`. The key and known_hosts
   paths are **host** paths.

Only ttyd and the ssh client count against `mem_limit`. The shell itself runs in the
host's sshd session.

### Which host user

`TERMINAL_USER` in the mesh `.env` chooses it. This template defaults to **`root`**,
because a mesh box has no managed Linux account (its login is an Authelia account). The
store app's own default is `admin`. Either way, the account must be allowed to log in
over SSH with a key (Ubuntu's default `PermitRootLogin prohibit-password` allows that),
and the box must run sshd.

## How it tiles itself

`x-compose-app` puts the tile in Maison's System grid (`view: system`). Maison will not
stop or uninstall it, and `backup.skip: true` keeps it out of the nightly backup and
the Backups tab. The only state is a key the app regenerates, and backing an app up
stops it. `webui-host: terminal-${APP_DOMAIN}` must match `caddy_0`.

## On disk

```
${DATA_ROOT}/AppData/terminal/
├── docker-compose.yml  .env  .icon.png  README.md   regenerated every self-check — don't edit
├── gate-data/                         the gate's sessions (30 days), kept across recreates
└── ssh/                               id_ed25519(.pub) (generated once), known_hosts (rewritten every start)
```

Plus one line in `~${TERMINAL_USER}/.ssh/authorized_keys` on the host.

## What it needs from the other stacks

- **auth** — the gate registers with `auth-registrar` by name on `pcs`, which is why
  it deploys after `ensure-auth-stack.sh`.
- **mesh** — `mesh-router-caddy` routes `terminal-*`.
- **host** — a running sshd, and a `TERMINAL_USER` that can log in with a key.

## Day-to-day

```bash
sudo bash /DATA/AppData/mesh/scripts/self-check/ensure-terminal-stack.sh   # redeploy
echo TERMINAL_ENABLED=false | sudo tee -a /DATA/AppData/mesh/.env            # opt out (next self-check)
docker logs terminaltty    # TERMINAL_SETUP errors, ssh failures
docker logs terminal       # gate: registration, sessions
```

## Known traps

| Symptom | Cause |
|---|---|
| ttyd exits `terminal: no '<user>' user on this host` | `TERMINAL_USER` names an account that doesn't exist |
| Session closes at once with `Permission denied (publickey)` | sshd refuses key login for that user (`PermitRootLogin no`, `AllowUsers`, …), or sshd isn't running |
| `Host key verification failed` | Host keys changed after start. Restart `terminaltty` to rewrite known_hosts |
| OIDC registration fails | The gate's hostname is not `terminal` |
| Gate logs `back-channel via the public issuer` | It registered before the auth stack was up. Restart `terminal` to re-register |

Anything wrong in the compose file comes from the store. Fix it in the store and copy
the result back here, not only here.

## See also

- `docker-compose.yml` and the store's `Apps/Terminal/rationale.md`: why it uses
  nsenter, `privileged` and `pid: host`.
- `scripts/self-check/ensure-terminal-stack.sh`: the variables it supplies.
