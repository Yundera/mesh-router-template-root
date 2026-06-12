#!/bin/bash
# Manage the nightly self-check cron entry from MESH_SELF_CHECK_CRON in .env.
#
# Behavior:
#   - MESH_SELF_CHECK_CRON unset or empty → default "0 3 * * *" (03:00 daily)
#   - MESH_SELF_CHECK_CRON="disabled"     → no cron entry
#   - MESH_SELF_CHECK_CRON="<expr>"       → use that 5-field cron expression
#
# Nightly only — no @reboot entry by design (the docker stack restarts itself
# via restart: unless-stopped; the self-check is maintenance, not boot-path).
#
# Idempotent: strips any prior entry with our marker, then writes the current
# desired entry.

set -e

if [ -f /.dockerenv ]; then
    echo "Inside Docker - dev environment detected. Skipping cron setup."
    exit 0
fi

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

MARKER="# MESH_ROUTER_SELFCHECK"
SCRIPT_FILE="$SCRIPTS_DIR/self-check.sh"

# Install cron if missing (Debian/Ubuntu — the supported install target)
if ! command -v crontab >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing cron..."
        apt-get update -qq && apt-get install -y -qq cron
    else
        echo "ERROR: crontab not available and apt-get not found - install cron manually"
        exit 1
    fi
fi

chmod +x "$SCRIPT_FILE"

SCHEDULE="${MESH_SELF_CHECK_CRON:-0 3 * * *}"

# Strip any prior managed entry (lines containing our marker)
CURRENT=$(crontab -l 2>/dev/null || true)
FILTERED=$(echo "$CURRENT" | grep -vF "$MARKER" || true)

if [ "$SCHEDULE" = "disabled" ] || [ "$SCHEDULE" = "off" ]; then
    echo "Nightly self-check disabled (MESH_SELF_CHECK_CRON=$SCHEDULE)"
    printf '%s\n' "$FILTERED" | crontab -
    exit 0
fi

# Append the managed entry. Trailing newline is required: crontab refuses
# input with "new crontab file is missing newline before EOF" otherwise.
NEW=$(printf '%s\n%s bash %s > /dev/null 2>&1 %s\n' "$FILTERED" "$SCHEDULE" "$SCRIPT_FILE" "$MARKER")
printf '%s\n' "$NEW" | crontab -
echo "Nightly self-check cron set to: $SCHEDULE"
