# Box migration - design note

> **Status: not implemented.** A design record written 2026-09-30 for future
> reference. Nothing here exists in this template yet; the only working migration
> today is the Yundera one described under "Where it lives today".

Moving a mesh box - domain, apps and data - onto another machine. The claim this
note works from: **migration is mesh scope, not Yundera scope.** The parts that
actually move a box (copying state, moving the domain identity, handing over the
route) are properties of the mesh. Only the lifecycle around it (who allocates the
new machine, who deletes the old one, who gets emailed) belongs to a control plane.

## Where it lives today

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
   `mesh` stack, so on Yundera the cutover is already broken (the source agent keeps
   publishing). `startUserApps.ts` treats `yundera/maison/kopia/casaos` as the system
   stacks and `MigrationVolumes.ts` excludes only `yundera`, so `mesh`/`auth` volumes
   would be copied as user-app volumes.
4. **Named volumes by host-path rsync** of `/var/lib/docker/volumes`, gated on rootful
   Docker with the default data-root. FOSS boxes do not guarantee that.
5. **Verification** probes `admin-<domain>/api/health` - the admin app. The mesh
   equivalent is `mesh-console-<domain>/api/health` (unauthenticated).

## Proposed design

### The old box drives it - same pattern as today

```
# on the OLD box (the source)
sudo bash scripts/tools/migrate.sh --to root@new-box
```

The source stays the driver, as in the Yundera pipeline and as with every other
host action on the box (the self-check, mesh-console's runner): the box that owns
the data, the identity and the running apps decides when to stop them, and
rollback is local - it is its own stack it brings back up. The target only needs
to be a reachable machine; it does not need the template installed first. The
source copies `DATA_ROOT` (which carries the template and `PROVIDER_STR`) and then
runs the target's own `self-check.sh` over SSH, which installs Docker, detects the
new public IP and brings the stacks up - the same bootstrap `install.sh` hands off
to.

**Status after cutover.** Driving from the source is what made the orchestrator
webhook mandatory on Yundera: once the source stops publishing, its domain points
at the target. Without an orchestrator it does not need a webhook:

- The cutover stops only `mesh-router-agent` / `mesh-router-tunnel`. The script
  (a host process, or the console's runner, both outside any compose project) keeps
  running, and so do the source's caddy and mesh-console, still reachable on the
  source's own sslip.io / nip.io names - just no longer on the domain.
- Run from an SSH session, the terminal is the progress view anyway.
- At the end the script copies its log onto the target, so the target's
  mesh-console keeps the record of how the box arrived.
- `--status-url` stays available for a control plane that wants pushes (Yundera).

**Access.** One SSH path, source → target. On a mesh box the user owns both
machines and already has root SSH, so the script uses the user's own access
(key / agent) - no `migration` account, no one-time password, no key push. Yundera
keeps its `migration` sudoer because there the orchestrator allocates the target
and the user has no SSH on it.

### Retiring the source - the mesh equivalent of "delete the old PCS"

Stopping the source is not enough: its `@reboot` self-check would restart the agent
and steal the domain back (the "zombie PCS" failure seen on Yundera).

- **v1 - retire marker on the box.** E.g. `MESH_RETIRED=<target-ip>` in `.env` or a
  `retired` file in the mesh root. `self-check.sh` honours it: never starts
  agent/tunnel, logs "retired - now served by X". mesh-console shows a banner.
  Deleting the machine stays the owner's business. Removing the marker is the
  rollback.
- **v2 - handover in mesh-router-backend.** Registrations carry an instance id /
  epoch; the backend accepts a signed takeover from the newest instance and rejects
  the older one. The cutover then no longer depends on reaching the source - which
  also gives **disaster recovery**: restore a backup onto a new box, claim, done,
  even when the old box is dead. That restore is the one case the new box drives -
  there is no source left to do it - and it is a separate flow, not a migration.

### `scripts/tools/migrate.sh`

- Same step list as today, minus the Yundera steps (push_key, webhook, source_down
  becomes "retire").
- Logs in the self-check format so mesh-console's Update-page parser can be reused.
- Knobs instead of paths, reusing the ones mesh-console already has for running on
  Yundera: data root, stack root, self-check script, `PLATFORM_PROJECTS`.
- Named volumes copied as `docker run -v <vol>:/v … tar` streams, not a
  `/var/lib/docker` rsync - drops the rootful-Docker gate.
- Verify = `mesh-console-<domain>/api/health` pinned to the target IP + backend
  `resolve/v2` returning the target.
- Optional `--status-url <https>`: pushes the same status snapshots the current
  pipeline sends. That is the hook Yundera plugs into.
- A host script, so a container restart no longer kills the migration.

### mesh-console

A third host action on the runner ("migrate"), plus a page that follows the migrate
log the way the Update page follows the self-check. Deliberately after the CLI works.

## How Yundera would consume it

| Today | After |
|---|---|
| admin app `Migration/` pipeline (~2.9k lines) + panel | Deleted. `template-root` ships the same script with its path knobs, as it already does for mesh-console |
| "Migrate INTO" account on the target | Orchestrator-owned only (Path B already creates it) |
| Path C: `docker exec admin-app …` on the source | Orchestrator runs `migrate.sh --to migration@<target>` on the source, through the same support-key SSH (or the console runner) instead of the admin container |
| Webhook, promote, soft-delete, emails | Unchanged in the orchestrator, fed by `--status-url` |
| Progress UI in the admin app / pcs-dashboard `MigrationCard` | mesh-console page; the dashboard card keeps reading the orchestrator's copy |

## Constraints and open questions

- **Differing `DATA_ROOT`.** App compose files still hard-code `/DATA` in many store
  apps (not yet moved to `${DATA_ROOT:-/DATA}`). v1 should refuse unless both boxes use
  the same data root.
- **Windows / WSL boxes** (`install.sh --windows`) have no cron and no rsync. A later
  `export | import` stream mode (tar over any pipe, also usable for cold copies)
  would cover them.
- **Shared machines.** A mesh box may not own the whole VM: copy only `DATA_ROOT` and
  the managed projects' volumes, never assume "the VM is the box".
- **Rollback** is local to the source: `compose up` + removing the retire marker. What
  it cannot undo on its own is the target, which may already be publishing - the
  script must stop the target's agent/tunnel (over the same SSH path) before bringing
  the source back, or both boxes fight over the route.
- **Cross-arch** (amd64 → arm64): images are re-pulled per arch; apps without an arm64
  image fail at start_user_apps, as they do today (reported, not fatal).
- **Who may migrate.** Today the admin panel gates it; in the CLI form it is whoever
  has root on both boxes. The console action must be admins-only like the rest of it.

## Suggested order

1. Retire marker honoured by `self-check.sh`.
2. `scripts/tools/migrate.sh --to <user@host>`, run on the source.
3. Yundera path knobs so `template-root` runs the same script.
4. Rewire orchestrator Path B/C to call it; delete the admin-app pipeline and panel.
5. mesh-console migrate page (third runner action).
6. Backend epoch / handover - turns migration into "move or restore, even from a dead
   box".
