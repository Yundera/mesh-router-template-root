#!/bin/bash

# Mesh-router self-check: runs all ensure-*.sh scripts listed in
# self-check/scripts-config.txt, in order.
#
# Triggers:
#   - nightly cron (installed by ensure-nightly-self-check.sh)
#   - manual: sudo bash /DATA/AppData/mesh/scripts/self-check.sh
#   - install.sh runs it once at the end of installation
#
# Exit code: 0 if every script succeeded, 1 if any failed. The loop never
# aborts early — every ensure script gets a chance to run regardless of
# earlier failures. Failures are logged via execute_script_with_logging.
#
# Linux only. On Windows installs (--windows) install.sh skips self-check
# setup entirely.

set -e

LOCK_FILE="/var/run/mesh-self-check.lock"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another mesh self-check instance is running, exiting"
    exit 0
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/library/common.sh"

# Display mode (--display or MESH_DISPLAY=1): render a per-step checklist on
# stdout with each step's full output captured to the log only. Default mode
# (nightly cron / manual run) streams every line to stdout as before.
DISPLAY_MODE=0
for _arg in "$@"; do
    [ "$_arg" = "--display" ] && DISPLAY_MODE=1
done
[ "${MESH_DISPLAY:-0}" = "1" ] && DISPLAY_MODE=1

if [ "$DISPLAY_MODE" -eq 1 ]; then
    log_to_file_only "INFO" "=== Mesh self-check starting (display) ==="
else
    log "=== Mesh self-check starting ==="
fi

SCRIPTS_CONFIG_FILE="$SELF_DIR/self-check/scripts-config.txt"

if [ ! -f "$SCRIPTS_CONFIG_FILE" ]; then
    log_error "Scripts configuration file not found: $SCRIPTS_CONFIG_FILE"
    exit 1
fi

# BOOTSTRAP THE EXEC BITS BEFORE TRUSTING ANY SCRIPT IN THE TREE.
#
# ensure-scripts-executable.sh exists to keep this tree executable, and it cannot
# fix the one case that matters: if the tree arrives mode 644,
# execute_script_with_logging refuses to run it, so the repair script is itself
# unrunnable, and so is ensure-template-sync.sh, so no later template can land.
# We are already running, so we can always restore the bits first. Cheap and
# idempotent, and it turns a whole class of delivery bug — a sync that loses
# modes, a bad umask, an archive that drops them — into a self-healing one.
find "$SELF_DIR" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

# Parse scripts-config.txt into the SCRIPTS array (strips comments, empty lines
# and surrounding whitespace).
read_scripts_config() {
    local line
    SCRIPTS=()
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            continue
        fi
        line=$(echo "$line" | xargs)
        [ -n "$line" ] && SCRIPTS+=("$line")
    done < "$SCRIPTS_CONFIG_FILE"
    return 0
}

note() {
    if [ "$DISPLAY_MODE" -eq 1 ]; then
        log_to_file_only "INFO" "$1"
    else
        log "$1"
    fi
}

OVERALL_FAILED=0
FAILED_SCRIPTS=()
TOTAL=0
idx=0

# Run the given list, in order.
#
# `tolerate_missing=1` treats a script that is named in the list but absent on
# disk as a skip rather than a failure: it was retired by a release whose
# scripts-config.txt landed mid-run: ensure-template-sync.sh prunes scripts
# deleted upstream, as Yundera/template-root's sync does. The
# reconcile pass below passes 0 instead: it has just re-read the config from
# disk, so a missing script there means the SHIPPED config names something that
# does not exist, which is a real error.
run_scripts() {
    local tolerate_missing="$1" script_name
    shift
    for script_name in "$@"; do
        idx=$((idx + 1))
        if [ "$tolerate_missing" = "1" ] && [ ! -f "$SELF_DIR/self-check/$script_name" ]; then
            note "Skipping $script_name: listed when this run started, no longer on disk"
            [ "$DISPLAY_MODE" -eq 1 ] && printf '[%2s/%s] %-30s - skipped (removed)\n' "$idx" "$TOTAL" "$script_name"
            continue
        fi
        if [ "$DISPLAY_MODE" -eq 1 ]; then
            if ! execute_script_display "$idx" "$TOTAL" "$SELF_DIR/self-check/$script_name"; then
                OVERALL_FAILED=1
                FAILED_SCRIPTS+=("$script_name")
            fi
        else
            if ! execute_script_with_logging "$SELF_DIR/self-check/$script_name"; then
                OVERALL_FAILED=1
                FAILED_SCRIPTS+=("$script_name")
            fi
        fi
    done
}

# Main pass: slurp the script list into memory FIRST, then iterate. This stays
# deterministic even if ensure-template-sync.sh replaces scripts-config.txt
# mid-run — a naive `while ... done < file` would keep reading the old inode
# via its open FD.
read_scripts_config
STARTED_WITH=("${SCRIPTS[@]}")
TOTAL=${#STARTED_WITH[@]}
run_scripts 1 "${STARTED_WITH[@]}"

# Reconcile pass. ensure-template-sync.sh may have replaced scripts-config.txt
# (and the scripts themselves) during the main pass, which ran the OLD list from
# memory. When the list changed, re-run the WHOLE list in its configured order.
#
# This used to append only the entries the main pass had not run. That converged
# in one cycle, but a newly delivered script then ran after every pre-existing
# one — so each ordering rule in scripts-config.txt was false on exactly the
# cycle that mattered, the one that first delivers the script, and scripts had to
# compensate one by one (re-invoking the peers they had just invalidated).
# Yundera/template-root hit the same thing and fixed it here once; this is that
# fix, so the two runners behave alike.
#
# Re-running everything is safe by construction: these scripts are convergent
# reconcilers, that being the premise of the self-check. It costs one slow cycle,
# only on the rare run that changes the list. Work that must land BEFORE the new
# compose file is first brought up still belongs in scripts/migrations/, which
# runs before the new tree is even swapped in.
read_scripts_config
if [ "${SCRIPTS[*]}" != "${STARTED_WITH[*]}" ]; then
    note "scripts-config.txt changed during this run - re-running the full list in its configured order"
    [ "$DISPLAY_MODE" -eq 1 ] && printf '\nThe update changed the step list - running it again in order:\n'
    # The complete second pass is the authoritative verdict: a script that failed
    # above only because its dependency had not run yet gets its real answer
    # here, and reporting the stale failure too would be noise.
    OVERALL_FAILED=0
    FAILED_SCRIPTS=()
    idx=0
    TOTAL=${#SCRIPTS[@]}
    run_scripts 0 "${SCRIPTS[@]}"
fi

if [ "$DISPLAY_MODE" -eq 1 ]; then
    OK=$((TOTAL - ${#FAILED_SCRIPTS[@]}))
    echo ""
    if [ "$OVERALL_FAILED" -eq 0 ]; then
        echo "=== Self-check complete: $OK/$TOTAL OK ==="
    else
        echo "=== Self-check complete: $OK/$TOTAL OK, failed: ${FAILED_SCRIPTS[*]} ==="
    fi
fi

if [ "$OVERALL_FAILED" -eq 0 ]; then
    COMPLETION_MSG="=== Mesh self-check completed successfully ==="
else
    COMPLETION_MSG="=== Mesh self-check completed with failures ==="
fi
if [ "$DISPLAY_MODE" -eq 1 ]; then
    log_to_file_only "INFO" "$COMPLETION_MSG"
else
    log "$COMPLETION_MSG"
fi

exit "$OVERALL_FAILED"
