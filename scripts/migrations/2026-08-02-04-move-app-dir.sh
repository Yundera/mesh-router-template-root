#!/bin/bash
# Migration: /DATA/AppData/casaos/apps/mesh -> /DATA/AppData/mesh
#
# The compose file and .env lived in a separate directory under CasaOS's apps root,
# because that is what made the stack visible to CasaOS. CasaOS is gone, and Maison
# instead scans ${DATA_ROOT}/AppData for directories containing a docker-compose.yml —
# so with the files where they were, the Mesh Router tile renders as UNMANAGED. Moving
# them collapses everything about this stack into one directory and makes the tile
# managed, with no mirror script needed (which is why this repo has no equivalent of
# template-root's ensure-maison-yundera-mirror.sh).
#
# THE OLD PATH BECOMES A SYMLINK, it is not deleted. Two reasons:
#
#   1. This cycle. APP_DIR and ENV_FILE are resolved when common.sh is sourced, at the
#      TOP of each script. This migration runs inside ensure-template-sync.sh, which
#      then goes on to `cp docker-compose.yml "$APP_DIR/"` using the value it resolved
#      before the move — and ensure-stack-up.sh later runs `docker compose` there too.
#      Without the symlink those writes would recreate the old directory and the stack
#      would be brought up from a stale copy.
#   2. Rollback. Code that predates this release only knows the old path. With the
#      symlink it keeps working; without it, a rolled-back box finds no compose file.
#
# Remove the symlink in the release that drops the other transition shims.
#
# Deliberately does NOT stop the stack: moving a compose file does not affect running
# containers, and the `up -d` later in this same cycle reconciles them. The containers
# do get recreated once, when their working_dir label changes.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

OLD_DIR="/DATA/AppData/casaos/apps/mesh"
NEW_DIR="/DATA/AppData/mesh"

# Already a symlink: this migration has run. Check -L BEFORE anything that follows the
# link, since every path test below would succeed through it and look like work to do.
if [ -L "$OLD_DIR" ]; then
    echo "Already migrated ($OLD_DIR is a symlink)"
    exit 0
fi

if [ ! -d "$OLD_DIR" ]; then
    echo "No $OLD_DIR (fresh install at the new path); nothing to move"
    exit 0
fi

mkdir -p "$NEW_DIR"

# Move everything the old directory holds. In practice that is docker-compose.yml and
# .env, but a crashed env_set can leave a .env.XXXXXX temp file behind and there is no
# reason to strand it.
moved=0
shopt -s dotglob nullglob
for item in "$OLD_DIR"/*; do
    base="$(basename "$item")"
    if [ -e "$NEW_DIR/$base" ]; then
        # The destination already has this name. The old copy is the live one — the new
        # directory is MESH_ROOT, whose contents are template-owned state, so a clash
        # means something unexpected. Keep the live file, park the other.
        echo "WARN: $NEW_DIR/$base already exists; backing it up as $base.pre-move"
        mv -f "$NEW_DIR/$base" "$NEW_DIR/$base.pre-move"
    fi
    mv "$item" "$NEW_DIR/$base"
    moved=$((moved + 1))
done
shopt -u dotglob nullglob

# Replace the directory with a symlink. rmdir (not rm -rf) on purpose: it refuses if
# anything is left, which is the signal that the loop above missed something.
if ! rmdir "$OLD_DIR" 2>/dev/null; then
    echo "ERROR: $OLD_DIR is not empty after moving $moved item(s); leaving it in place"
    ls -A "$OLD_DIR"
    exit 1
fi
ln -s "$NEW_DIR" "$OLD_DIR"

echo "Moved $moved item(s) to $NEW_DIR; $OLD_DIR is now a symlink"
