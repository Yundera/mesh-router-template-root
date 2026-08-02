#!/bin/bash
# Migration: converge the update source on UPDATE_URL
#
#   MESH_TEMPLATE_URL=<url>       -> UPDATE_URL=<url>
#   MESH_UPDATE_CHANNEL=<branch>  -> UPDATE_URL=https://github.com/.../<branch>.tar.gz
#
# UPDATE_URL is the key name and shape Yundera/template-root uses, and the one
# settings-center-app's /api/admin/update-channel reads and writes through
# env-file-manager.sh. Converging on it is what lets that panel manage this
# template unmodified — see doc/alignment-with-template-root.md, phase 4.
#
# A box that has not run this yet keeps working: mesh_template_url() still reads
# both old keys, one release longer.
#
# Ordering note: this runs AFTER the key-rename migration in the same pass (files
# execute in filename order, -01- then -02-). Both are independent.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

ENV_MGR="$SELF_DIR/../tools/env-file-manager.sh"

if [ ! -f "$ENV_FILE" ]; then
    echo "No .env at $ENV_FILE; nothing to do"
    exit 0
fi

existing="$(bash "$ENV_MGR" get UPDATE_URL "$ENV_FILE")"
old_url="$(bash "$ENV_MGR" get MESH_TEMPLATE_URL "$ENV_FILE")"
old_channel="$(bash "$ENV_MGR" get MESH_UPDATE_CHANNEL "$ENV_FILE")"

if [ -n "$existing" ]; then
    echo "UPDATE_URL already set; dropping any stale pre-rename keys"
elif [ -n "$old_url" ]; then
    # Full-URL override wins, matching mesh_template_url()'s precedence.
    bash "$ENV_MGR" set UPDATE_URL "$old_url" "$ENV_FILE"
    echo "MESH_TEMPLATE_URL -> UPDATE_URL ($old_url)"
elif [ -n "$old_channel" ]; then
    resolved="$(mesh_channel_url "$old_channel")"
    bash "$ENV_MGR" set UPDATE_URL "$resolved" "$ENV_FILE"
    echo "MESH_UPDATE_CHANNEL=$old_channel -> UPDATE_URL ($resolved)"
else
    # Neither key set: the box was on the built-in default. Write it explicitly so
    # the value is visible and editable rather than implied by absence.
    resolved="$(mesh_channel_url "$MESH_DEFAULT_CHANNEL")"
    bash "$ENV_MGR" set UPDATE_URL "$resolved" "$ENV_FILE"
    echo "No update source configured -> UPDATE_URL ($resolved)"
fi

# Mirror the resolved value into the DEPRECATED MESH_TEMPLATE_URL rather than
# deleting it, and keep the two in lockstep for one release.
#
# Deleting it here is silently destructive on a rollback. Pre-rename code reads
# MESH_TEMPLATE_URL first and knows nothing about UPDATE_URL, so a box that has
# run this migration and is then put back on an older tree — a reverted `main`, or
# a pin back to a `stable` that predates the rename — resolves NOTHING, falls
# through to the built-in default, and quietly starts tracking `stable` instead of
# whatever it was on. Observed exactly that on the test box.
#
# With both keys carrying the same URL, old and new code agree either way.
# MESH_UPDATE_CHANNEL can go now: old code prefers MESH_TEMPLATE_URL over it, so
# it can no longer influence anything.
#
# Remove MESH_TEMPLATE_URL in the release that drops the other transition shims.
final_url="$(bash "$ENV_MGR" get UPDATE_URL "$ENV_FILE")"
bash "$ENV_MGR" set MESH_TEMPLATE_URL "$final_url" "$ENV_FILE"
bash "$ENV_MGR" delete MESH_UPDATE_CHANNEL "$ENV_FILE"
echo "mirrored to deprecated MESH_TEMPLATE_URL for rollback safety"
