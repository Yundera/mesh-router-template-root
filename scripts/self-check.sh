#!/bin/bash

# Mesh-router self-check: runs all ensure-*.sh scripts listed in
# self-check/scripts-config.txt, in order.
#
# Triggers:
#   - nightly cron (installed by ensure-self-check-cron.sh)
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

# Slurp the script list into memory FIRST, then iterate. This stays
# deterministic even if ensure-template-sync.sh replaces scripts-config.txt
# mid-run — a naive `while ... done < file` would keep reading the old inode
# via its open FD. Script updates take effect on the NEXT run.
SCRIPTS=()
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
        continue
    fi
    line=$(echo "$line" | xargs)
    [ -n "$line" ] && SCRIPTS+=("$line")
done < "$SCRIPTS_CONFIG_FILE"

OVERALL_FAILED=0
FAILED_SCRIPTS=()
TOTAL=${#SCRIPTS[@]}
idx=0
for script_name in "${SCRIPTS[@]}"; do
    idx=$((idx + 1))
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
