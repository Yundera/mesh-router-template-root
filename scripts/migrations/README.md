# Migrations

One-shot scripts that adapt an **already-installed** box to a new template version.
Run by `scripts/tools/run-migrations.sh`, which `ensure-template-sync.sh` invokes against
the freshly downloaded tree **before** that tree is swapped in and before any file is
propagated to its live location.

## Why they exist

`self-check.sh` reads `scripts-config.txt` into memory and runs a single pass, so an
ensure-script **added** by a release does not execute until the *next* nightly cycle — while
the new `docker-compose.yml` is copied and brought up during *this* one. Anything that must
happen in the same cycle as the compose swap (minting a secret a new service needs, removing
a service, renaming an env key) belongs in a migration, not in a new ensure-script.

A migration failure aborts the sync. Nothing has been propagated at that point, so the box
stays on its current version — there is no half-applied state to unwind.

## Naming

```
YYYY-MM-DD-NN-name.sh          one-shot, tracked by a marker file
YYYY-MM-DD-NN-name.always.sh   runs on every sync, must implement its own idempotency
```

Execution is filename order, which the date prefix makes chronological. `NN` is a
within-day sequence number, not an hour.

Markers live in `${MESH_ROOT}/migration-markers/` (i.e. `${DATA_ROOT}/AppData/mesh/`).
Deleting a marker re-runs that migration on the next sync.

## Rules

- **Idempotent.** Even one-shots: a marker can be lost, and `.always.sh` has no marker at all.
- **A no-op on a fresh install.** `install.sh` runs the self-check at the end, so a brand-new
  box executes the whole backlog once with no markers. Every migration must therefore detect
  "nothing to do" and exit 0 — never assume it is running against an older box.
- **Run from the NEW tree.** `$(dirname "$0")/../library/common.sh` is the version being
  migrated *to*, which is what you want — a release that moves things needs its migrations to
  agree with the layout they produce.
- **Never assume the target state exists yet.** The new compose file is not on disk when a
  migration runs. Provision state; don't `docker compose up` against files that are still
  the old version.
- **Quiet on success, verbose on failure** — `run-migrations.sh` captures output and prints
  it only when the migration fails (or on success, as its trace). Keep the success path short.
- Use `scripts/tools/env-file-manager.sh` for every `.env` mutation. Raw `sed`/`grep` loses
  the file's mode and owner, and the mesh `.env` is deliberately owned by `PUID:PGID`.

## Template

```bash
#!/bin/bash
# Migration: one-line description
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

ENV_MGR="$SELF_DIR/../tools/env-file-manager.sh"

# ... migration logic, guarded so a re-run is a no-op ...

echo "done"
```
