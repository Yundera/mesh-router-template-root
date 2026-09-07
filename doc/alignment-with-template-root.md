# Aligning this template with `Yundera/template-root`

Working record of bringing the FOSS mesh template (`mesh-router-template-root`,
the `install.sh` self-serve product) into step with the managed Yundera PCS
template (`Yundera/template-root`, provisioned by `pcs-orchestrator`).

## Scope

**In scope**, and the subject of releases 1-5 below:

1. **Maison instead of CasaOS** - CasaOS dropped entirely.
2. **Dex + Authelia** - Authelia is the box-local credential; `casaos-oidc-bridge` gone.
3. **Relevant self-checks** - port what applies, skip what only makes sense on a VM
   Yundera provisioned.
4. **Env naming** - best-effort convergence on Yundera's key names.
5. **Dex sessions** - real single-logout, custom login theme, `dex-grpc` alias.
6. **Onboarding** - the owner claims the box's login, at install time or over SSH.

**Permanently OUT of scope.** These are not "later", they are decided:

| Not ported | Why |
|---|---|
| The admin app (`settings-center-app`) | A managed-PCS surface. This template's admin interface is the shell. What was "phase 4" below is cancelled, not deferred. |
| Yundera-cloud integration | `YUNDERA_API`, `USER_JWT`, `OPERATOR_API`, the support key, `ensure-yundera-user-data.sh` - all assume a control plane this product does not have. |
| The "Yundera Login" connector | `ensure-yundera-login.sh` federates to Yundera's IdP. The `connectors.d/` mechanism it used IS ported, so a fork can add its own; the connector is not. |
| Backup / kopia | The credentials come from `YUNDERA_API` with a `USER_JWT`. Porting it means designing a bring-your-own-storage path first - a separate piece of work. |

The three-file env split (`.pcs.env` / `.pcs.secret.env` / `.ynd.user.env`) is also
deliberately not adopted. It exists because the orchestrator stages two of those
files before `pcs-init.sh` runs. There is no orchestrator here - `install.sh`
writes one file the user owns, and that stays.

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
| 1 | **Phase 0** - migration engine, `env-file-manager.sh`, two-pass self-check, env key renames ✅ shipped |
| 2 | **Phases 1+2** - Authelia/Dex, Maison in, CasaOS out, plus one convergence migration ✅ implemented |
| 3 | **Phase 3** - move `/DATA/AppData/casaos/apps/mesh` → `/DATA/AppData/mesh` ✅ implemented |
| 4 | ~~admin app~~ **CANCELLED** - out of scope, see the table above |
| 5 | **Version bumps + Dex sessions + onboarding** ✅ implemented, see "Release 5" below |

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

### What the first live test changed (2026-08-02, test2.nsl.sh)

Installing `stable` and updating to this tree on a real box found two problems. Both fixes
are in phase 0.

**1. The sync destroyed the interpreters running it.** `ensure-template-sync.sh` propagated
new scripts with a plain `cp` onto the live paths — including `self-check.sh` and itself,
both of which were executing. Bash parses lazily by byte offset, so both resumed inside the
new bytes:

```
ensure-template-sync.sh: line 121: syntax error near unexpected token `('   # from a 105-line file
self-check.sh: line 85: syntax error near unexpected token `then'
```

The files were valid on disk the whole time. Latent since long before phase 0 — it only
bites when a release shifts file length enough to move the parser onto a bad boundary, and
phase 0 grew both files by ~45 lines. **It will bite phases 1–3 harder.** Fixed by copying
each script to a temp file in the destination directory and `mv`-ing it into place: the
rename gives a new inode and the running interpreter reads its own unlinked copy to the end.

Note the asymmetry: **the fix cannot protect the cycle that installs it**, because the *old*
sync is the one running then. A box coming from a pre-fix template will always take one
noisy cycle. That is survivable — see below — and every cycle after it is clean.

**2. The transition cycle ran the stack on blank credentials.** In that same cycle the new
`docker-compose.yml` is installed and `ensure-stack-up.sh` applies it, but the rename
migration cannot have run yet. `mesh-router-agent` came up with an empty `PROVIDER`. The
public URLs kept answering for the ~600s route TTL and would then have gone dark until the
next nightly cycle — up to 24h. Fixed with two transition shims, to be removed together one
release after this one has rolled out:

- `docker-compose.yml` reads `${PROVIDER_STR:-${PROVIDER}}` / `${DEFAULT_PWD:-${DEFAULT_PASSWORD}}`.
- `library/common.sh` aliases the three renamed keys **in memory only** (`: "${NEW:=${OLD}}"`),
  so scripts reading the new name work before the file is rewritten. It writes nothing, so the
  migration and `heal_renamed_key` still see the real file state and still perform the rename.

**Rollout shape for phase 0, confirmed on the box:**

| Cycle | What happens |
|---|---|
| 1 | Old sync self-destructs (two syntax errors, exit 2). New scripts land anyway. `.env` still on old names. **Stack stays on valid credentials via the shims**; all endpoints 200. |
| 2 | Fixed sync runs. Migration renames the keys, marker written. 12/12, exit 0. |
| 3+ | Clean. Migration skipped via marker. |

Verified end to end: `PROVIDER_STR` and `DEFAULT_PWD` fingerprints identical before and
after (values moved, never regenerated), `.env` still `600` / `1000:1000`, `PUBLIC_IPV4/6`
backfilled, cron running under the new script name, no blank-variable warnings, CasaOS and
the Dex connector chooser both rendering.

Regression coverage lives in the scratchpad harnesses (56 assertions): the self-overwrite
case is reproduced with no network and no docker by serving the tree as a `file://` tarball
through `MESH_TEMPLATE_URL`.

### `UPDATE_URL` — the update source, renamed

`UPDATE_URL` is now the canonical key and holds a **full tarball URL**, matching
`template-root`'s key name and shape, and matching what `settings-center-app`'s
`/api/admin/update-channel` reads and writes through `env-file-manager.sh`. That endpoint is
why this rename mattered enough to do before the rest: without it the admin app's update
panel cannot drive this template (phase 4).

- Resolution order in `mesh_template_url()`: `UPDATE_URL` → `MESH_TEMPLATE_URL` (deprecated)
  → `MESH_UPDATE_CHANNEL` (deprecated, expanded to a branch URL) → stable branch.
- `install.sh` keeps `--channel` as a convenience and gains `--update-url` for an arbitrary
  tarball; either way the resolved full URL is persisted.
- Migrated by `scripts/migrations/2026-08-02-02-rename-update-url.sh`.
- **Format difference kept:** this template ships `.tar.gz` and extracts with `tar`;
  `template-root` ships `.zip`. A `.zip` URL is rejected with an explicit message rather
  than failing inside `tar` — same key, still not interchangeable archives. Adding `unzip`
  support would close that, at the cost of a new host dependency.

**Rollback trap found while testing this, and designed around.** The first version of the
migration *deleted* `MESH_UPDATE_CHANNEL` and `MESH_TEMPLATE_URL` once `UPDATE_URL` was
written. Pre-rename code reads `MESH_TEMPLATE_URL` and knows nothing about `UPDATE_URL`, so
a box that ran the migration and was then put back on an older tree — a reverted `main`, or
a pin to a `stable` that predates the rename — resolved nothing, fell through to the
built-in default, and **silently started tracking `stable` instead of the branch it was
on**. Reproduced on the test box: `mesh_template_url()` returned the stable URL while
`.env` clearly said `main`.

The migration and `install.sh` therefore **mirror** the resolved URL into
`MESH_TEMPLATE_URL` instead of deleting it, so old and new code agree either way.
`MESH_UPDATE_CHANNEL` is dropped immediately — old code prefers `MESH_TEMPLATE_URL` over it,
so it can no longer influence anything. `MESH_TEMPLATE_URL` goes with the other transition
shims one release later.

## Phases 1+2 — IMPLEMENTED (release 2)

**The port target moved before this was written.** `template-root` finished its own
phases 2 and 3 on 2026-08-02: `casaos` and `stacks/casaos/` are gone there,
`ensure-casaos-stack.sh` is deleted, and only `stacks/maison/` remains. So the
cohabitation shape planned below was skipped — this repo ports the **final** state
directly, which is simpler and matches upstream today.

What shipped:

| | |
|---|---|
| Added to the mesh stack | `authelia` (4.39) on `local-auth-${DOMAIN}` |
| Removed from the mesh stack | `casaos`, `casaos-oidc-bridge` |
| New stack | `stacks/maison/` → deployed to `${DATA_ROOT}/AppData/maison` |
| New scripts | `ensure-authelia.sh`, `ensure-maison-stack.sh`, `ensure-maison-app-mirror.sh`, `tools/deploy-stack.sh` |
| New template | `auth/configuration.yml.tmpl` |
| Dex connector | `casaos` → `authelia`; `enablePasswordDB` + break-glass admin removed |
| Root domain | `DEFAULT_SERVICE_HOST` `casaos:8080` → `maison:80` |
| Migration | `2026-08-02-03-authelia-maison.sh` |

Two things worth knowing about the implementation:

- **`stacks/` and `auth/` are read from `$TEMPLATE_DIR`, not a live location.**
  `ensure-template-sync.sh` propagates only `docker-compose.yml`, the `Caddyfile` and
  `scripts/`. Rather than adding two more propagation steps, `deploy-stack.sh` and
  `ensure-authelia.sh` read from `template/` — a pristine copy of the whole repo,
  refreshed on every sync, so it is always current. `install.sh --local` had to be
  taught to mirror both directories, since that path assembles `template/` by hand.
- **`uninstall.sh` no longer names containers.** It now runs `docker compose down
  --remove-orphans -v` against both project directories, with a named sweep only as a
  fallback. The old hand-maintained list already missed `dex`, `casaos-oidc-bridge`
  and `auth-registrar`; this release would have added three more.

The original plan for these phases follows, kept for the reasoning.

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

## Phase 3 — folder move — IMPLEMENTED (release 3)

`APP_DIR` is now `/DATA/AppData/mesh`, the same directory as `MESH_ROOT`, so compose,
`.env`, `template/`, `scripts/`, `log/` and `data/` all live in one place. Migration:
`2026-08-02-04-move-app-dir.sh`.

Two things the implementation needed beyond the plan:

- **The old path becomes a symlink, not a deletion** — as planned, for the stale
  `APP_DIR` in the running cycle and for rollback. `uninstall.sh` removes the link
  (never its target).
- **`common.sh` falls back to the old path when the new one has no `.env`.** Without
  it, migration *ordering* becomes load-bearing: migrations source `common.sh`, so on a
  box running the whole backlog in one cycle the earlier migrations would resolve
  `ENV_FILE` to a path the move migration has not created yet, find no `.env`, and mark
  themselves applied having done nothing. With the fallback every script works either
  side of the move and the migrations can run in any order. This shim goes with the
  others.

The Mesh Router tile in Maison flips from `UNMANAGED` to managed as a side effect —
Maison's managed scan is `stat(${DATA_ROOT}/AppData/<name>/docker-compose.yml)`.

The original plan follows.

### Original plan

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

## Phase 4 — admin app — CANCELLED

Not deferred, cancelled. The admin app (`settings-center-app`) is a managed-PCS
surface; this product's admin interface is the shell. See the scope table at the
top.

Two consequences worth recording, because they undo earlier decisions:

- **The script-name convergence is off.** `ensure-env-valid.sh` vs
  `ensure-env-vars-valid.sh`, `ensure-scripts-executable.sh` vs
  `ensure-script-executable.sh`, `ensure-stack-{pulled,up}.sh` vs
  `ensure-user-compose-{pulled,stack-up}.sh` — the only reason to rename was that
  the admin app invokes some of them by name. Keep this repo's names.
- **Phase 0's key renames are now unmotivated but stay anyway.** `PROVIDER_STR`,
  `DEFAULT_PWD` and `SELF_CHECK_CRON` were renamed because `settings-center-app`
  reads those names. They have shipped and boxes have migrated; renaming back
  would cost another migration for nothing.

## Release 5 — version bumps, Dex sessions, onboarding — IMPLEMENTED

### Version bumps

| Image | was | now |
|---|---|---|
| `mesh-router-tunnel` | 1.2.10 | 1.3.0 |
| `mesh-router-agent` | 1.0.11 | 1.1.1 |
| `mesh-router-caddy` | 1.2.5 | 1.2.6 |
| `mesh-auth` | 1.1.3 | 1.1.6 |
| `authelia` | 4.39 | 4.39.20 |
| `dex` | v2.43.1 | digest `af946950…a026b` |
| `maison` | 1.1.0 | 1.1.25 |
| `appshield` | 2.0.6 | 3.0.0 |

Only two carried mandatory config changes.

**`PROTECTED_APPS` → `x-compose-app.view: system`.** Maison **1.1.5 removed
`PROTECTED_APPS`**, so on 1.1.25 the key is silently ignored and the platform
stack becomes stoppable and uninstallable from the dashboard — and since phase 3
the mesh stack is a *managed* Maison tile, so it is directly exposed. `view` does
not raise `schema_version` and is inert on older images, so it shipped in its own
commit **before** the bump. It is set in both `stacks/maison/docker-compose.yml`
and the root `docker-compose.yml`.

**`APPSTORE_URL` became overridable**, and its comment now carries the pin
relationship: compose-relative store assets need Maison ≥ 1.1.21, so the image pin
and the store URL move together. This repo was already on the wrong side of that
— maison 1.1.0 against a post-conformance `AppStore@main` — so the store grid was
rendering iconless before this release.

Also picked up: `ROOT_CLIENT_ID: "${DEFAULT_SERVICE_HOST:-maison}"` on
`auth-registrar` (mesh-auth ≥ 1.1.4), which names the one app allowed to register
callbacks on the **bare** `${DOMAIN}`. Without it a login on the bare domain is
bounced to `<app>-${DOMAIN}` mid-flow — "SSO moved me to a different URL". And the
Maison tile icon URL, which had been 404ing since the AppStore repo renamed
`Apps/CasaDash/` to `Apps/CasaOS/`.

**AppShield 3.0.0 is drop-in here.** It removed `AUTH_HASH`/`AUTH_HASH_MODE`,
which this template never set. Its identity-propagation variables all live on the
admin gate, which does not exist here.

### Dex sessions, theme, and the `dex-grpc` alias

`DEX_SESSIONS_ENABLED=true` plus the `sessions:` block — **these move together**,
Dex refuses to start with one and not the other. 720h absolute *and* idle: Dex
defaults to 24h absolute with a **1h idle** timeout, so taking the defaults would
quietly cut SSO to one hour of inactivity.

The image is pinned **by digest to a `master` build**, deliberately. RP-Initiated
Logout (PR #4674) and Back-Channel Logout with a `sid` claim (PR #4945) are merged
upstream but unreleased; v2.45.1 predates both and advertises no logout at all.
By digest and not `:master` so a push to trunk cannot reach the fleet on its own.
**Repin to a release as soon as one carries both PRs.**

`ensure-dex-session-key.sh` mints `DEX_SESSION_KEY` — 24 random bytes as base64,
which is exactly 32 ASCII characters. Dex accepts only 16/24/32 **bytes**, so
`openssl rand -hex 32` (64 chars) would be rejected.

`dex-theme/` lives at the repo root and is read through the
own-tree-then-`$TEMPLATE_DIR` fallback that `ensure-authelia.sh` already uses for
its config template — `ensure-template-sync.sh` propagates only compose, the
Caddyfile and `scripts/`, so `template/` is the only copy in the live layout.
The theme is renamed off `yundera` to `mesh`; `icon-yundera.svg` and
`icon-casaos.svg` are dropped with their CSS rules, since neither connector
exists here. The login page names the box's own domain (`frontend.issuer`), which
is both vendor-neutral and the anti-phishing cue.

`tools/provision-dex-frontend.sh` is a **tools/** script with two callers
(`ensure-dex.sh` and `ensure-stack-up.sh`) because compose bind-mounts
`login.html`/`header.html` as single FILES: any `docker compose up` before they
exist makes Docker create them as DIRECTORIES and `dex` can never start again.
It empties the theme directory in place rather than `rm -rf`-ing it — a bind mount
follows the **inode**, so recreating the directory leaves a running container
mounted on the deleted one and every asset 404s.

The pinned `ipv4_address: 172.31.7.2` is replaced by a network-scoped `dex-grpc`
alias. Docker will not reconfigure an existing network's IPAM, so
`migrations/2026-09-07-10-drop-dex-internal-ipam.always.sh` sweeps the stale
bridge. It is `.always.sh`, **not** a one-shot: `run-migrations.sh` writes a
one-shot's marker on *any* successful exit, so a deferral (the network still has
attached endpoints mid-cycle) would be recorded as done and the sweep would never
happen.

### Onboarding

The box now seeds its owner account **unclaimed** — present but `disabled: true`,
which Authelia enforces at authentication. Two hard Authelia 4.39 schema
constraints shape that seed, and violating either kills the container at startup,
taking every interactive login with it: a user entry must carry a **non-empty
`password:`** (hence a throwaway random hash, never printed), and `users:` must
**not be empty** (hence a placeholder key that `claim` renames rather than
create-then-delete).

`DEFAULT_PWD` is no longer the login password. It is an app-seed secret injected
into every installed app as `default_pwd` / `PCS_DEFAULT_PASSWORD` /
`APP_DEFAULT_PASSWORD`, so using it as the human credential put the owner's own
password in every app's environment. It still flows to apps unchanged.

`install.sh` gained the precedence ladder **flag > existing `.env` > prompt >
default**, so a re-run to update asks nothing — every value is already on disk.
Prompts read `/dev/tty`, not stdin: the documented install path is
`curl … | bash`, where stdin is the script itself and `[ -t 0 ]` is false even
with a terminal present. Four paths, all exercised:

| Invocation | Result |
|---|---|
| `--claim-user` + `--claim-password` | claimed, no prompt |
| `--generate` | claimed, password printed once, never stored |
| neither, with a terminal | prompts for username + password (twice, no echo) |
| `--yes` with neither | left unclaimed, prints the SSH claim command |

`tools/authelia-user-manager.sh` is ported nearly verbatim, which is why
`ensure-yq-installed.sh` exists: `yq` is a deliberate exception to this repo's
no-host-dependencies rule, taken so the read-modify-write over
`users_database.yml` is one implementation rather than two. It is **not** a
dependency of login — `ensure-dex.sh`'s claimed-ness probe fails **open** without
it, and the installer treats a failed yq install as non-fatal.

The Local Account connector moved out of `dex.config.yaml.tmpl` into
`ensure-dex.sh` and is now conditional on claimed-ness, which is also what makes
the `connectors.d/` drop-in mechanism possible (drop-ins cannot be appended to a
template whose `connectors:` key already has inline items). An unclaimed box
renders **zero** connectors, which is valid YAML and a legitimate transient state;
the script logs it loudly with the exact fix command.

`authentication_backend.file.watch: true` was added to the Authelia config: the
user manager rewrites `users_database.yml` from the host, and without `watch` a
claim or password change does not take effect until `docker restart authelia`,
which drops every session on the box.

## Open follow-ups

- ~~`MESH_UPDATE_CHANNEL` is a branch name, not a URL.~~ **Done** — see below.
- ~~`uninstall.sh` removes a stale container list.~~ **Done** with phases 1+2 — it now
  runs `docker compose down --remove-orphans -v` against both project directories.
- **Dex cold-boot crash loop.** On a fresh install Dex validates its connector's issuer over
  the *public* gateway before `ensure-route-registered.sh` has run, gets
  `502 {"error":"No routes available"}` and exits; `restart: unless-stopped` recovers it a
  few seconds later. Cosmetic but alarming in logs. Phase 1 does not fix it — Authelia's
  issuer is gateway-routed the same way. Real fix is ordering, or lazy connector opening.

  Release 5 narrows the window without meaning to: an **unclaimed** box renders no
  connectors at all, so there is nothing for Dex to resolve on that first boot. The
  loop is back the moment the box is claimed.
- **Repin Dex to a release.** The digest pin is a `master` build. Repin as soon as an
  upstream release carries PR #4674 and PR #4945 (expected > v2.45.1). Tracked here
  rather than only in the compose comment, so it surfaces on the next pass.
- **Drop the phase-0 transition shims.** `${PROVIDER_STR:-${PROVIDER}}` /
  `${DEFAULT_PWD:-${DEFAULT_PASSWORD}}` in `docker-compose.yml`, the in-memory aliases in
  `library/common.sh`, the `MESH_TEMPLATE_URL` mirror, and the old-`APP_DIR` symlink from
  phase 3. All were "remove one release later"; that release has not happened. With the
  admin app cancelled there is nothing left to coordinate with, so this is now free.

## Not ported

`template-root`'s self-check runs on a VM the orchestrator provisioned. This one runs on a
machine the user already administers, so these would have the installer reconfigure a box
that is not ours:

`ensure-pcs-user.sh`, `ensure-ssh.sh` (rewrites sshd config), `ensure-swap.sh`,
`ensure-ubuntu-up-to-date.sh` (unattended apt upgrades), `ensure-support-key.sh`,
`ensure-yundera-user-data.sh`, `ensure-outbound-ip-family.sh`, and the Proxmox/LVM handling
in `library/common.sh`.

Nor the pieces listed in the scope table at the top: the admin app and its
`ensure-admin-user.sh` / `ensure-admin-gate-secret.sh`, `ensure-yundera-login.sh`,
`ensure-maison-yundera-mirror.sh` (unnecessary since phase 3 made this stack a managed
tile), and the whole backup/kopia set (`ensure-backup-{config,credentials}.sh`,
`ensure-kopia-stack.sh`, `stacks/kopia/`, `library/kopia.sh`).

`onboarding.sh` is **not** ported either, but for a different reason: it is a thin wrapper
over the `claim` verb plus a state marker the admin app's wizard reads. `install.sh` and
`authelia-user-manager.sh claim` cover the same ground here. Its deployment-override seam
(an executable drop-in in the runtime data dir, `exec`'d in place of the shipped script)
is worth remembering if this template ever needs per-deployment onboarding behaviour.
