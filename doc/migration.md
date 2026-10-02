# Box migration - design note

> **Status: implemented 2026-10-02, not yet run on real boxes.** Mesh side:
> `scripts/tools/migrate.sh` and the routing hold in `ensure-stack-up.sh` (usage in the
> README, "Moving the box to another machine"), and mesh-console's Migration page. Yundera
> side: the orchestrator and dashboard as described in "How Yundera consumes it"; the
> admin-app pipeline is deleted. Written 2026-09-30, revised 2026-10-02 after a design
> review. "What it replaced" records the admin-app pipeline.

Moving a mesh box - domain, apps and data - onto another machine. The claim this
note works from: **migration is mesh scope, not Yundera scope.** The parts that
actually move a box (copying state, moving the domain identity, handing over the
route) are properties of the mesh. Only the lifecycle around it (who allocates the
new machine, who deletes the old one, who gets emailed) belongs to a control plane.

## What it replaced (the admin-app pipeline)

The only implementation is Yundera's, split across two server-tier and PCS-tier
components that this template does not have:

| Piece | Location | Role |
|---|---|---|
| Pipeline (13 steps) | `settings-center-app` `src/backend/server/Migration/` | Runs inside the admin app on the **source**, SSHes to its own host as the `admin` sudoer, rsyncs to the target |
| Migration panel | `settings-center-app` `src/panels/migration/MigrationPanel.tsx` | "Migrate OUT" (source) and "Migrate INTO" (target: enables a password-login `migration` sudoer) |
| Target allocation | `pcs-orchestrator` `library/migration/MigrationTargetBootstrap.ts` | Path B: bare Ubuntu VM + `migration` sudoer + one-time webhook token |
| Automated trigger | `pcs-orchestrator` `library/migration/AutoMigrationJob.ts` | Path C: SSH into the source, `docker exec admin-app` → `/api/local/migration/start` |
| Completion | `pcs-orchestrator` `service/pcsAPI.ts` `/pcs/migration-callback` | Status push from the source; on `done`, promote the target record and soft-delete the source VM |

The current step list (`MigrationTypes.ts` `MIGRATION_STEPS`): preflight → push_key →
online_rsync → docker_pull → stop_source → offline_rsync → target_self_check →
start_user_apps → deregister_source → verify_destination → cleanup → source_down →
webhook.

## What is mesh, what is Yundera

**Mesh-level** - holds for any box running this template:

- **Identity travels with the data.** Route ownership is `PROVIDER_STR`
  (`backend_url,userid,signature`). The signature covers the userid only, not an IP,
  so whichever box holds that string can register routes for the domain. It lives in
  `${DATA_ROOT}/AppData/mesh/.env`, so copying the data *is* the identity transfer.
- **The cutover is a routing problem.** mesh-router-backend stores routes per source
  (`routes:<uid>:agent`, `routes:<uid>:tunnel`, see `mesh-router-backend/src/services/Routes.ts`).
  Two agents on the same identity overwrite each other's key - last writer wins, and
  the domain flaps. The source's agent/tunnel must go silent for the target to own the
  route.
- **The pipeline shape.** Online copy while apps serve, pre-pull images, stop apps,
  offline delta copy, run the target's self-check, start apps, cut over, verify. This
  template already has every self-check the target side relies on
  (`ensure-docker-installed.sh`, `ensure-public-ip.sh`, `ensure-route-registered.sh`).

**Yundera-only** - a control plane this product does not have:

- Allocating the target machine, and the `migration` sudoer + one-time password dance.
  That exists because a Yundera user has no SSH on a VM the orchestrator allocated.
- The Path C trigger via the support key.
- The status webhook, which is only mandatory because the pipeline runs on the source
  and the source goes silent at cutover.
- Promotion in the PCS registry, soft-delete of the source VM, lifecycle emails.

## Yundera assumptions baked into the current pipeline

Things a port must not carry over as-is:

1. **Execution model.** The admin app SSHes to its own host as a sudoer
   (`MigrationSSH.ts`). This template has no SSH or sudoers set up for itself;
   mesh-console's host actions go through an `nsenter` runner container with fixed
   argv. The pipeline also dies if the admin container restarts - it lives in the
   Next.js process.
2. **Hard-coded paths.** `/DATA`, `yndPath(...)`, `log/yundera.log`, the
   `YUNDERA_NIGHTLY_SELFCHECK` cron marker, app discovery under
   `/DATA/AppData/casaos/apps`. This template has a configurable `DATA_ROOT`.
3. **Stack names.** `deregister_source` / `source_down` stop the `yundera` compose
   except `admin`. Since the 2026-09-30 stack split the agent and tunnel are in the
   `mesh` stack, so with the split the cutover is broken (the source agent keeps
   publishing). The split has not reached `stable` (= prod) yet, so this is the
   reason to replace the pipeline, not a live incident. `startUserApps.ts` treats `yundera/maison/kopia/casaos` as the system
   stacks and `MigrationVolumes.ts` excludes only `yundera`, so `mesh`/`auth` volumes
   would be copied as user-app volumes.
4. **Named volumes by host-path rsync** of `/var/lib/docker/volumes`, gated on rootful
   Docker with the default data-root. FOSS boxes do not guarantee that.
5. **Verification** probes `admin-<domain>/api/health` - the admin app. The mesh
   equivalent is `mesh-console-<domain>/api/health` (unauthenticated).


## Principles

- **The mesh migration is self-contained.** A user runs `migrate.sh` on the old box
  and reads the feedback in the terminal or in mesh-console. Getting the new machine
  and deleting the old one are the user's business. Nothing in the mesh needs a
  control plane.
- **Yundera watches from outside.** Allocating the target, starting the migration
  remotely, promoting the target, deleting the source and sending emails stay
  Yundera-only, in the orchestrator. Yundera uses only generic surfaces that any
  operator could use: the target requirements, an optional status push, and the
  existing backend read API.
- **No Yundera logic in the mesh.** mesh-router-backend, the template and
  mesh-console know nothing about pcsIds, tokens, promotion or emails. The design
  needs **no mesh-router-backend change**.
- **Nothing is run on the target to prepare it.** The target must already be in the
  required state. `migrate.sh` lists the requirements and checks them in preflight,
  and refuses if they are not met. It never creates accounts, installs keys or
  changes sshd. The FOSS user prepares the target, and so does Yundera when it
  allocates one.

## Target requirements

The full contract between a source and any target, FOSS or Yundera-allocated.
Preflight checks each item and reports every failure, not just the first one.

| Requirement | Check |
|---|---|
| Ubuntu, same release family as the source (other Linux: out of scope for now) | `/etc/os-release` over SSH |
| sshd reachable from the source | connect with the migration key, `BatchMode=yes` |
| an account (any name, `migration` by convention) with the source's **migration public key** in `authorized_keys` | same connection |
| passwordless sudo for that account | `sudo -n true` |
| `rsync` installed | `command -v rsync` |
| free space on the target's `DATA_ROOT` filesystem >= what the source uses + 5 GiB | `df` on both sides (never `du`: it times out on large trees) |
| no existing box on the target (`DATA_ROOT` absent or empty) | refuse rather than overwrite |
| same `DATA_ROOT` as the source | the copy lands at the source's path; the source's `.env` must sit inside its data root (refused otherwise) |
| clocks within 60 s | `date +%s` on both sides |
| architecture | different arch = warning, not refusal (images are re-pulled; apps without an image for that arch fail at start-apps and are reported) |

Docker is **not** a requirement: the target's own self-check installs it when the
migration runs it (`ensure-docker-installed.sh`), as on a fresh install.

### The migration key

`migrate.sh key` creates the source's migration keypair the first time it is called
(ed25519, root-owned 0600, in `data/migrate/`) and prints the public key.
mesh-console shows the same key on its Migration tab. The key is **excluded from the
copy**, so a migrated box does not carry a key that its old machine can still use.
This replaces today's `push_key` step and the one-time password: there is no
`sshpass` and no password anywhere.

## `scripts/tools/migrate.sh`

```
sudo scripts/tools/migrate.sh key                                     # print the public key
sudo scripts/tools/migrate.sh preflight --to migration@new-box        # requirements only, changes nothing
sudo scripts/tools/migrate.sh start --to migration@new-box [--status-url URL]
sudo scripts/tools/migrate.sh status | log [-f] | cancel
```

**The source drives it, as today.** The box that owns the data, the identity and the
running apps decides when to stop them, and rolling back is local.

**It runs on the host, detached.** `start` launches the pipeline as a transient
systemd unit (`systemd-run --unit=mesh-migrate`) and returns. It does not depend on
the SSH session, the mesh-console container or the runner, so a restart of any of
them does not kill a migration. During the run it holds the **self-check flock**
(`/var/run/mesh-self-check.lock`), so the source's nightly self-check exits
immediately instead of restarting stacks mid-copy. No new lock mechanism is needed.

**Steps:**

| Step | Source apps | What |
|---|---|---|
| `preflight` | serving | the requirements above |
| `online_copy` | serving | rsync `DATA_ROOT` (minus `data/migrate/`) |
| `prepare_target` | serving | install Docker from the copied tree, `docker compose pull` of every project, on the target |
| `stop_apps` | down | stop user apps on the source (platform stacks keep running) |
| `offline_copy` | down | rsync delta with `--delete`; then the user apps' named volumes, host `tar` streamed between the two volumes' `Mountpoint`s (any Docker data-root, no image pull) |
| `target_up` | down | write the **routing hold** on the target, then run its `self-check.sh` over SSH: Docker, public IP, stacks up, **no route published** |
| `start_apps` | down | `compose up -d` of each user app on the target; failures reported, not fatal |
| `verify_target` | down | `mesh-console-<ip-dash>.nip.io/api/health` answers at the target IP, before any cutover |
| `cutover` | down | source: write the routing hold and remove agent/tunnel, then drop its routes (`DELETE /routes/:userid/:sig`, signed with its own `PROVIDER_STR`). Target: remove the hold and run `ensure-stack-up.sh` |
| `verify_domain` | target | `GET /routes/:userid` lists only target `agent` routes, and `mesh-console-<domain>/api/health` answers through the domain |
| `retire` | target | routing hold on the source becomes permanent ("retired, now served by X"), and the log is copied to the target |

**One marker covers the cutover and retirement.** The *routing hold* (e.g.
`MESH_ROUTING_HOLD=<reason>` in the mesh `.env`) makes `self-check.sh` leave
agent/tunnel stopped. Two different uses of the same marker:

- **On the target, during the migration:** the box comes up and is checked without
  competing for the route. Two agents on one identity overwrite each other's
  `routes:<uid>:*` keys, so this removes the flapping window.
- **On the source, after the migration:** the old box cannot steal the domain back
  at `@reboot` (the "zombie PCS" failure). mesh-console shows a banner. Removing the
  marker is the rollback.

**Rollback.** If a step fails before `cutover`, the script restarts the source's apps.
If it fails at or after `cutover`, it stops the target's agent/tunnel (same SSH
path), removes the source's hold and restarts the source's agent/tunnel. Only then
are the source's apps brought back, so both boxes never fight over the route. The
target is left as it is, for inspection; cleaning it up is the user's job.

**Status snapshot.** The script keeps `status.json` next to its log, rewritten on
every change. It is the one state format, and the terminal, mesh-console and the
status push all read it:

```json
{ "version": 1, "id": "20261002-120000", "phase": "starting|running|rolling_back|done|failed|rolled_back|cancelled",
  "startedAt": "…", "finishedAt": "…",
  "source": {"ip": "…", "domain": "…"}, "target": {"host": "…", "user": "…"},
  "steps": [{"key": "online_copy", "label": "Copy data (apps online)", "group": "source",
             "status": "pending|running|success|failed|skipped",
             "startedAt": "…", "finishedAt": "…", "message": "…"}],
  "copy": {"bytes": 0, "percent": 0, "rate": "…", "eta": "…"},
  "error": null, "updatedAt": "…" }
```

The snapshot describes itself: it carries its own step list, labels and grouping
(`source` / `down` / `target`: who serves the apps while the step runs, the colour bands of today's UI). A consumer renders it
without keeping its own copy of the step list. That copy is why today's
`MIGRATION_STEPS` and the pcs-dashboard `MigrationCard` must be kept in sync by hand.

**`--status-url`**, optional and generic: `POST` the snapshot to that URL on every
change, plus every 15 s as a heartbeat. It is best-effort and never fatal, and the
URL is opaque to the mesh (a capability URL, a chat-webhook adapter, anything). It
only reports; nothing on the mesh side waits for an answer.

**Logs** use the self-check line format, so mesh-console's Update-page parser can be
reused.

**Knobs instead of paths:** `PLATFORM_PROJECTS` (the AppData folders that are not
user apps), `MIGRATE_TARGET_SELF_CHECK` (a second self-check to run on the target, for
a deployment with its own template) and `MIGRATE_HOLD_LOCKS` (that template's
self-check lock, held for the whole run). A PCS runs this template unmodified, so
these three knobs are all Yundera needs.

## mesh-console: Migration tab

Admins-only, like the rest of mesh-console:

- the migration public key, with a copy button
- the target requirements as a checklist; "Check target" runs `migrate.sh preflight`
- a form for `user@host` and an optional status URL, then Start
- the live view: steps and copy progress from `status.json`, the log tail, Cancel
- after the migration, on the target: the copied log, i.e. "how this box arrived"
- on a retired source: the "retired, now served by X" banner

Start and preflight are host actions on the runner (fixed argv, validated arguments,
like the two existing ones). `start` returns as soon as the systemd unit is launched,
so the runner is not held for the hours a migration can take.

## How Yundera consumes it

Everything below is orchestrator / pcs-dashboard code. The PCS runs the same
`migrate.sh` as a FOSS box, with Yundera path knobs (`template-root` ships it the way
it ships mesh-console).

| Yundera step | How |
|---|---|
| **Target** | The provider creates an Ubuntu VM that meets the target requirements: a `migration` sudoer with the source's migration public key in `authorized_keys`. **No password and no password-SSH drop-in.** |
| **Getting the key** | *With the support key* (Path C): the orchestrator runs `migrate.sh key` on the source over SSH. *Without it* (Path B, the privacy case): the user copies the key from mesh-console into the dashboard. |
| **Starting it** | *Path C:* `ssh admin@<src> sudo …/migrate.sh start --to migration@<ip> --status-url <url>`. *Path B:* the dashboard shows the target (`migration@<ip>`) and the status URL; the user enters them in the source's mesh-console Migration tab, which is also how they would migrate to a FOSS box. |
| **Live feedback** | The status URL is the orchestrator's progress endpoint (token in the URL). It keeps the latest snapshot as today, and the dashboard `MigrationCard` renders the snapshot's own steps, so the view stays live. |
| **Completion** | **Not on a pushed `done`.** The orchestrator's `MigrationWatcher` checks every migration target every 30 s against the existing public `GET /resolve/v2/<domain>`: the agent routes point only to the target IP and `mesh-console-<domain>/api/health` answers. A pushed `done` lets it promote on the first such observation; with no push (Path B without the status URL, an orchestrator restart) the observation must hold for 10 minutes, longer than `verify_domain`, so a run that is going to roll back has done so. Then: promote the target record, soft-delete the source VM, send the email. A pushed `failed` / `rolled_back` / `cancelled` takes the failure path; a Path C run with neither push nor cutover for an hour is marked lost. |
| **Cancel** | The dashboard soft-deletes the target: the run on the source then fails and rolls back by itself, so the source is no longer rebooted. `pcs cancel-migration` also sends `migrate.sh cancel` over the support key. Path B: the user can cancel in mesh-console. |

The token now only authorizes *reporting progress* for one migration; it no longer
promotes anything. Promotion is based on what the orchestrator can check itself in
the mesh, so a leaked or forged push cannot cause a source deletion.

**Removed:** the admin-app `Migration/` pipeline (~2.9k lines), its panel and
`/api/{admin,local}/migration/*`; the "Migrate INTO" account endpoints;
`AutoTriggerSource`'s `docker exec admin-app`; password generation and the sshd
password drop-in in `MigrationTargetBootstrap`; the promote-on-push claim in
`/migration-callback`; the hard-coded step list in `MigrationCard`.

**Unchanged:** provider allocation, registry promotion, source soft-delete,
lifecycle emails, the `pcs migrate` / `migration-info` / `list-migrations` CLI
(adapted to the new snapshot format).

**Out of scope, with a workaround: a Yundera user migrating out on their own** (to
FOSS or their own server). This works today with the mesh-console tab or the
terminal, since the target is just a machine that meets the requirements. Their
`*.nsl.sh` identity keeps pointing at Yundera's backend. The orchestrator's watcher
only follows migrations it allocated, so a route that moves to an unknown IP is
ignored. The retired source holds its route, and deleting the old PCS stays a
dashboard action. Full user control over the nsl.sh account is future work.

## Later: backend handover and restore

Registrations could carry an instance id / epoch, with the backend accepting a
signed takeover from the newest instance. Cutover would then no longer depend on
reaching the source, which also gives **disaster recovery**: restore a backup onto a
new box, claim, done, even when the old box is dead. That is a generic mesh-router
feature (no Yundera logic), and a separate flow from migration.

## Open questions

- **Snapshot versioning.** `version: 1` lets the dashboard refuse or downgrade
  unknown shapes; agree on it before the orchestrator side is written.
- **Watcher timeout.** How long without cutover before the orchestrator declares a
  migration lost (the copy of a large box can take hours; heartbeats help tell a
  slow copy from a dead one).
- **Windows / WSL boxes** (`install.sh --windows`): no systemd, cron or rsync.
  Out of scope while the target is Ubuntu only; an `export | import` stream mode
  would cover them later.
- **Shared machines.** A mesh box may not own the whole VM: copy only `DATA_ROOT`
  and the managed projects' volumes, never assume "the VM is the box".

## Suggested order

1. Routing hold honoured by `self-check.sh` (agent/tunnel left absent). **Done.**
2. `migrate.sh` with `key`, `preflight`, `start`, `status`, `log`, `cancel`,
   `status.json` and `--status-url`. **Done.**
3. Yundera knobs: `MIGRATE_TARGET_SELF_CHECK` / `MIGRATE_HOLD_LOCKS` from template-root's
   `library/mesh.sh`, and its self-checks skip a retired box. **Done.**
4. mesh-console Migration page (key, preflight, start, cancel verbs + live view). **Done.**
5. Orchestrator: key-based target bootstrap, Path C over SSH, `MigrationWatcher`,
   `MigrationCard` rendering snapshot steps; Path B via dashboard + mesh-console. **Done.**
6. Delete the admin-app pipeline and panel. **Done.**
7. Verify on real boxes: routing hold on holyhorse, FOSS-to-FOSS from the terminal, then
   Yundera Path B and Path C on staging. **Pending.**
8. Later: backend epoch / handover, restore onto a new box.
