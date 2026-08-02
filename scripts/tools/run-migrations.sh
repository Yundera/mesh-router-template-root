#!/bin/bash
# run-migrations.sh <migrations_directory>
#
# Runs migration scripts in filename order. Called by ensure-template-sync.sh
# against the NEWLY DOWNLOADED tree, before that tree is swapped into
# template/ and before anything is propagated to its live location — so a
# migration can prepare state for a template version that is not on disk yet.
# That ordering is the whole point of the mechanism: this repo's self-check is
# single-pass over an in-memory copy of scripts-config.txt, so an ensure-script
# added by a release does not run until the NEXT cycle. Work that must happen
# in the same cycle as the compose swap belongs in a migration.
#
# A non-zero exit here aborts the sync. Nothing has been propagated at that
# point, so the box simply stays on its current version — no restore needed
# (unlike Yundera/template-root, which rsyncs first and restores from backup).
#
# Naming:
#   YYYY-MM-DD-NN-name.sh          one-shot, tracked by a marker file
#   YYYY-MM-DD-NN-name.always.sh   runs every sync, must self-guard
#
# Markers live in ${MESH_ROOT}/migration-markers/ (override with
# MESH_MIGRATION_MARKERS, which the dev container uses).
#
# See doc/alignment-with-template-root.md and scripts/migrations/README.md.

set -euo pipefail

MIGRATIONS_DIR="${1:-}"

if [ -z "$MIGRATIONS_DIR" ]; then
    echo "Error: Usage: $0 <migrations_directory>"
    exit 1
fi

if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo "Error: Migrations directory does not exist: $MIGRATIONS_DIR"
    exit 1
fi

# Resolve MESH_ROOT from the live .env via this tree's own common.sh. Sourcing
# the NEW tree's copy is deliberate — a release that changes where things live
# needs its migrations to agree with the version they are migrating TO.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

MARKER_DIR="${MESH_MIGRATION_MARKERS:-$MESH_ROOT/migration-markers}"
mkdir -p "$MARKER_DIR"

migration_count=$(find "$MIGRATIONS_DIR" -name "*.sh" -type f | wc -l)
if [ "$migration_count" -eq 0 ]; then
    echo "No migrations to run"
    exit 0
fi

executed_count=0
skipped_count=0

while IFS= read -r -d '' migration_file; do
    migration_name=$(basename "$migration_file")

    # A migration arriving via tarball extraction may have lost its exec bit
    # depending on how the archive was produced; run it with bash regardless
    # rather than silently skipping it (upstream skips non-executable files,
    # which would turn a permissions accident into a missed migration).
    marker_file=""
    if [[ "$migration_file" != *.always.sh ]]; then
        marker_file="$MARKER_DIR/$(basename "$migration_file" .sh).marker"
        if [ -f "$marker_file" ]; then
            echo "✓ $migration_name (skipped - already applied)"
            skipped_count=$((skipped_count + 1))
            continue
        fi
    fi

    migration_output=$(mktemp)
    echo ""
    echo "=== $migration_name ==="

    if bash "$migration_file" >"$migration_output" 2>&1; then
        cat "$migration_output" 2>/dev/null || echo "(no output)"
        echo "✓ $migration_name completed"

        if [ -n "$marker_file" ]; then
            {
                echo "Migration completed at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo "Migration: $migration_name"
            } > "$marker_file"
        fi

        rm -f "$migration_output"
        executed_count=$((executed_count + 1))
    else
        exit_code=$?
        # Verbose on failure — this is the one place the sync gives up, so the
        # log needs everything the migration printed.
        cat "$migration_output" 2>/dev/null || echo "(no output)"
        echo "✗ $migration_name failed (exit $exit_code) - aborting template sync"
        rm -f "$migration_output"
        exit "$exit_code"
    fi

done < <(find "$MIGRATIONS_DIR" -name "*.sh" -type f -print0 | sort -z)

if [ "$executed_count" -gt 0 ] || [ "$skipped_count" -gt 0 ]; then
    echo "Migration summary: $executed_count completed, $skipped_count skipped"
fi

exit 0
