#!/bin/bash
# Migration: rename .env keys to the Yundera/template-root names
#
#   PROVIDER             -> PROVIDER_STR
#   DEFAULT_PASSWORD     -> DEFAULT_PWD
#   MESH_SELF_CHECK_CRON -> SELF_CHECK_CRON
#
# The first two are what settings-center-app reads (getConfigBackend.ts,
# DomainPanel); the third is the key its cron endpoint writes. Converging the
# names now is what lets the admin app run against this template unmodified
# later — see doc/alignment-with-template-root.md, phase 4.
#
# Runs in the same cycle as the compose file that starts referencing the new
# names: this migration executes before the new docker-compose.yml is copied,
# and every ensure-*.sh re-sources .env at its own start, so scripts running
# later in the same pass already see the new keys.
#
# Values are moved, never regenerated. DEFAULT_PWD in particular is the
# platform secret every installed app derived its DB password and admin token
# from — losing it would break them all.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

ENV_MGR="$SELF_DIR/../tools/env-file-manager.sh"

if [ ! -f "$ENV_FILE" ]; then
    echo "No .env at $ENV_FILE; nothing to rename"
    exit 0
fi

renamed=0

rename_key() {
    local old="$1" new="$2"
    local old_val new_val

    old_val="$(bash "$ENV_MGR" get "$old" "$ENV_FILE")"
    new_val="$(bash "$ENV_MGR" get "$new" "$ENV_FILE")"

    # Nothing under the old name — already migrated, or never set.
    if [ -z "$old_val" ] && ! bash "$ENV_MGR" exists "$old" "$ENV_FILE"; then
        return 0
    fi

    # Both present: the new name wins (a re-run of install.sh writes it), and
    # the stale old key is dropped. Only copy when the new one is absent/empty.
    if [ -z "$new_val" ]; then
        bash "$ENV_MGR" set "$new" "$old_val" "$ENV_FILE"
        echo "Renamed $old -> $new"
    else
        echo "Dropped stale $old ($new already set)"
    fi

    bash "$ENV_MGR" delete "$old" "$ENV_FILE"
    renamed=$((renamed + 1))
}

rename_key PROVIDER             PROVIDER_STR
rename_key DEFAULT_PASSWORD     DEFAULT_PWD
rename_key MESH_SELF_CHECK_CRON SELF_CHECK_CRON

if [ "$renamed" -eq 0 ]; then
    echo "Env keys already use the new names"
fi
