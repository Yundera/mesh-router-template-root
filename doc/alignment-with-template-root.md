# Aligning this template with `Yundera/template-root`

Working plan for bringing the FOSS mesh template (`mesh-router-template-root`, the
`install.sh` self-serve product) closer to the managed Yundera PCS template
(`Yundera/template-root`, provisioned by `pcs-orchestrator`).

Scope agreed:

1. **Maison instead of CasaOS** — drop CasaOS entirely.
2. **Dex + Authelia** — Authelia becomes the PCS-local credential; `casaos-oidc-bridge` goes.
3. **Admin app** — ship `settings-center-app` here too.
4. **Relevant self-checks** — port what applies, skip what only makes sense on a VM Yundera provisioned.
5. **Env naming** — best-effort convergence on Yundera's key names.

Out of scope, deliberately: the three-file env split (`.pcs.env` / `.pcs.secret.env` /
`.ynd.user.env`). That exists because the orchestrator stages two of those files before
`pcs-init.sh` runs. There is no orchestrator here — `install.sh` writes one file the user
owns, and that stays.

---

## The constraint that shapes the release train

`self-check.sh` slurps `scripts-config.txt` into memory and runs a **single pass**
("Script updates take effect on the NEXT run"). `Yundera/template-root` runs a second pass;
this repo does not.

So on the cycle that applies a new template:

- the new `docker-compose.yml` **is** copied, and `ensure-stack-up.sh` (still in the old
  list) brings it up;
- but ensure-scripts newly **added** to `scripts-config.txt` do **not** run until the next
  nightly cycle.

A release that adds a service *and* the ensure-script that provisions it therefore leaves
boxes with an unprovisioned service for up to 24h. That is what makes the migration engine
a hard prerequisite rather than a nicety: migrations run from the **newly downloaded tree,
before it is swapped in**, so they can prepare state for a version that is not on disk yet.

The engine cannot bootstrap itself — the *old* `ensure-template-sync.sh` is what runs during
the cycle that installs the new one. **Phase 0 must therefore ship alone, one release ahead
of everything else.**

`ensure-template-sync.sh` copies scripts with `cp -a` and no `--delete`, so scripts removed
from a release linger on disk instead of erroring. That is why this repo avoids the "one
noisy self-check cycle" that `template-root` documented for its CasaDash→Maison rebrand.
Dead files are untidy, not harmful; sweeping them is a separate change.

## Release train

Each release needs one nightly cycle to land on existing boxes. Allow a day on `main`
before merging to `stable`.

| Release | Contents |
|---|---|
| 1 | **Phase 0** — migration engine, `env-file-manager.sh`, two-pass self-check, env key renames |
| 2 | **Phases 1+2** — Authelia/Dex, Maison in, CasaOS out, plus one convergence migration |
| 3 | **Phase 3** — move `/DATA/AppData/casaos/apps/mesh` → `/DATA/AppData/mesh` |
| 4 | **Phase 4** — admin app, once the upstream `COMPOSE_FOLDER_PATH` work lands |

Phases 1 and 2 combine safely. Phase 3 is kept separate: it is the only step that touches
the stack's on-disk identity, and it deserves its own rollback boundary.

---

## Phase 0 — migration engine and env rename (release 1)

**Port from `template-root`:**

- `scripts/tools/env-file-manager.sh` — atomic set/get/delete/exists/sanitize with
  mode/owner preservation. Replaces the raw `grep`/`mv` pair in `library/common.sh`.
- `scripts/tools/run-migrations.sh` — filename-ordered, marker-tracked one-shots plus
  `.always.sh` variants. Markers live in `${MESH_ROOT}/migration-markers/`.
- `scripts/migrations/` + its README.

**Wire-up:** `ensure-template-sync.sh` runs migrations from the extracted tree **before**
the atomic swap into `template/`. A failed migration aborts the sync with nothing yet
propagated — no restore-from-backup needed, unlike `template-root`, which rsyncs first.

**Two-pass `self-check.sh`:** after pass 1, re-read `scripts-config.txt` and run entries
that were not in the in-memory list. Makes any future multi-part release converge in one
cycle instead of two.

**Renames:**

| Old | New | Why |
|---|---|---|
| `PROVIDER` | `PROVIDER_STR` | what `settings-center-app` reads (`getConfigBackend.ts`, `DomainPanel`) |
| `DEFAULT_PASSWORD` | `DEFAULT_PWD` | same |
| `MESH_SELF_CHECK_CRON` | `SELF_CHECK_CRON` | the admin app's cron endpoint writes this key |
| `ensure-self-check-cron.sh` | `ensure-nightly-self-check.sh` | the admin app invokes it by name |

Kept as-is: `MESH_AUTO_UPDATE`, `MESH_UPDATE_CHANNEL`, `MESH_TEMPLATE_URL`. Nothing
cross-repo reads them, and the channel model is better than Yundera's single-zip
`UPDATE_URL`.

**Also:** `ensure-public-ip.sh` gains `PUBLIC_IPV4(_DASH)` / `PUBLIC_IPV6(_DASH)` — Maison's
`.env.app` forwards all four to every app it installs.

**Migration:** `2026-08-02-01-rename-env-keys.sh`. `ensure-env-valid.sh` also carries an
in-place fallback (old key present, new key absent → migrate) so a box self-heals whatever
order things land in.

## Phase 1 — Authelia + Dex (release 2, part 1)

**Add:** `auth/configuration.yml.tmpl`, `ensure-authelia.sh`, and an `authelia` service
(`authelia/authelia:4.39`) on `local-auth-${DOMAIN}` with the usual
domain / nip.io / sslip.io label triple.

**Remove:** the `casaos-oidc-bridge` service, `BRIDGE_SECRET`, and the disposable
break-glass admin in `ensure-dex.sh` (its `httpd:2.4-alpine` bcrypt step and the
`dex/admin-password` + `dex/admin-hash` files). Authelia's own reset flow is the recovery
path now.

**Swap:** the `casaos` connector in `dex.config.yaml.tmpl` for the `authelia` one, keyed on
`AUTHELIA_DEX_SECRET`.

**Ordering:** `ensure-authelia.sh` immediately before `ensure-dex.sh` — it mints
`AUTHELIA_DEX_SECRET`, which the same cycle's Dex render interpolates into the connector.

Adaptations rather than verbatim copies:

- Keep this repo's pure-bash `${VAR//…/…}` substitution instead of `envsubst`. Not depending
  on gettext matters for an installer targeting arbitrary boxes. Note the pbkdf2 hash and
  the RSA PEM carry `$` sequences — that is exactly why `template-root` injects them through
  a heredoc outside `envsubst`; bash parameter expansion handles them natively.
- `notifier.smtp` points at `smtp://smtp:587`, the mail-gateway container already in this
  stack, so password reset works unchanged. Retag `sender` / `subject` off "Yundera".
- Port the Yundera Login connector block at the tail of `ensure-dex.sh` as-is: it already
  no-ops when `YUNDERA_API` / `USER_JWT` are unset, and gives forks a hook for their own IdP.
- Port `dex-theme/` but rename the theme directory off `yundera`.

> **User-visible break.** The local credential moves from CasaOS to a fresh Authelia `admin`
> account seeded from `DEFAULT_PWD`. Existing CasaOS passwords do not carry over. Needs
> release notes.

## Phase 2 — Maison in, CasaOS out (release 2, part 2)

**Add:** `stacks/` plus `tools/deploy-stack.sh` (verbatim — copies the stack template,
regenerates `<dest>/.env` from the unified `.env`, pulls and ups with backoff),
`stacks/maison/docker-compose.yml`, `ensure-maison-stack.sh` (minus its CasaDash
legacy-locations block — this repo never shipped `casadash`), `ensure-maison-app-mirror.sh`.

The mirror is still needed with CasaOS gone: existing boxes have apps under
`/DATA/AppData/casaos/apps/<app>`, which Maison lists as *unmanaged* (no env / compose /
update tabs) until mirrored into `/DATA/AppData/<app>/`.

**Remove:** the `casaos` service, and its references in `uninstall.sh`, `install.sh`,
`install.ps1`, `dev/docker-compose.yml`, `dev/README.md`.

**Flip:** `DEFAULT_SERVICE_HOST` from `casaos` to `maison` — the AppShield gate, **not**
`maison-app` — in `ensure-env-valid.sh`, the `Caddyfile` comments, and the three places
`README.md` documents it. Rewrite the root `x-casaos` block. Wire `${PUID}` / `${PGID}` into
`maison-app` (`template-root` hardcodes 1000).

Lost with CasaOS, with no Maison equivalent: the file manager, and CasaOS's magic-link email
sign-in (`USER_EMAIL` + `SMTP_HOST`). Everything else — app grid, store install, updates,
per-app env injection — Maison covers.

**Convergence migration** (this is what makes 1+2 safe in one release). It runs before the
new compose is copied and does the provisioning the newly-added ensure-scripts would
otherwise only do a cycle later:

```
scripts/migrations/2026-XX-XX-01-authelia-maison.sh
  1. mint AUTHELIA_DEX_SECRET into .env, run the NEW tree's ensure-authelia.sh
  2. run the NEW tree's ensure-dex.sh          (renders the authelia connector)
  3. sweep BRIDGE_SECRET, dex/admin-{password,hash}, casaos-oidc-bridge/
  4. docker rm -f casaos casaos-oidc-bridge
  5. retarget DEFAULT_SERVICE_HOST casaos -> maison (only if still 'casaos')
```

Maison itself needs no migration step: `ensure-maison-stack.sh` runs in pass 2 of the same
cycle, and until it does the root domain 502s rather than serving something wrong.

## Phase 3 — folder move (release 3)

`/DATA/AppData/casaos/apps/mesh` → `/DATA/AppData/mesh`, collapsing into the existing
`${DATA_ROOT}/AppData/mesh` so compose folder, scripts, template, log and data share one
root. The stack then becomes a *managed* Maison tile for free (Maison scans `/DATA/AppData`
and skips dotted names), which is why this repo needs no equivalent of `template-root`'s
`ensure-maison-yundera-mirror.sh`.

Must come after phase 2 — while CasaOS is installed, that path is the CasaOS-visible surface.

Touches `library/common.sh` (`APP_DIR`), `install.sh`, `install.ps1`, `uninstall.sh`,
`ensure-template-sync.sh`, `ensure-logrotate.sh`, `README.md`.

**The hazard:** `APP_DIR` and `ENV_FILE` are resolved when `common.sh` is sourced at the top
of a run. The migration that moves the directory executes *inside* `ensure-template-sync.sh`,
which then does `cp "$TEMPLATE_DIR/docker-compose.yml" "$APP_DIR/…"` against the now-stale
old path — recreating the directory it just moved, with `ensure-stack-up.sh` afterwards
running `docker compose` from there.

**The fix:** move, then symlink the old path at the new one. Every stale `APP_DIR` reference
keeps resolving for the rest of that cycle regardless of which `common.sh` is in effect; a
later release drops the symlink. The migration must be re-entrant — it briefly takes the
stack down.

## Phase 4 — admin app (release 4)

Blocked on an upstream change in `settings-center-app`. `COMPOSE_FOLDER_PATH` already exists
in `getConfigBackend.ts` and is already set by the yundera compose, but only 3 call sites use
it; ~15 module-level constants still hardcode `/DATA/AppData/casaos/apps/yundera`.

Upstream needs:

1. Derive every path from `COMPOSE_FOLDER_PATH` — `Health.ts`, `self-check-{run,log,cron,summary}.ts`,
   `support-send-report.ts`, `SupportEnsure.ts`, and the `Migration/steps/*.ts` files.
2. Two config keys, with defaults preserving Yundera behaviour exactly: `PCS_LOG_FILE`
   (default `<root>/log/yundera.log`; here `mesh.log`) and `PCS_ENV_FILE` (default
   `<root>/.pcs.env`; here `.env`). Everything else — `scripts/self-check.sh`,
   `scripts/tools/env-file-manager.sh`, `docker-compose.yml` — has identical names on both sides.
3. Gate the Yundera-only surface on `YUNDERA_API`: `SupportKey.ts` throws when it is unset,
   so the Support and Migration panels must render as unavailable rather than error.

`loadEnvironment.ts` is already deleted upstream — the three-file dotenv load was a no-op
(host paths, not container paths; env actually arrives via compose `env_file:`). That is what
makes a single `.env` sufficient here.

Then, in this repo: the `admin` service (`admin-${DOMAIN}` label triple, `env_file: .env`,
`COMPOSE_FOLDER_PATH`, `PCS_LOG_FILE`, `PCS_ENV_FILE`,
`OIDC_REGISTRAR_URL=http://auth-registrar:9092/register`), a ported `ensure-admin-user.sh`
plus its `tools/ensure-packages.sh` dependency, and `JWT_SECRET` generation in
`ensure-env-valid.sh`.

Worth porting alongside: `self-check-reboot.sh` + `ensure-self-check-at-reboot.sh` — this
repo has nightly cron only, and the admin app's SelfCheck panel invokes the reboot wrapper.

## Not ported

`template-root`'s self-check runs on a VM the orchestrator provisioned. This one runs on a
machine the user already administers, so these would have the installer reconfigure a box
that is not ours:

`ensure-pcs-user.sh`, `ensure-ssh.sh` (rewrites sshd config), `ensure-swap.sh`,
`ensure-ubuntu-up-to-date.sh` (unattended apt upgrades), `ensure-yundera-support-key.sh`,
`ensure-yundera-user-data.sh`, `ensure-outbound-ip-family.sh`, and the Proxmox/LVM handling
in `library/common.sh`.
