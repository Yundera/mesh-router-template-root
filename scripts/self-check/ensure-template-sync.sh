#!/bin/bash
# Auto-update: sync the template from GitHub and propagate template-owned
# files to their live locations.
#
# Ownership rule (the contract that makes auto-update safe):
#   template-owned (overwritten here): docker-compose.yml, Caddyfile, scripts/
#   user-owned (NEVER touched here):   .env, ${MESH_ROOT}/data/
#
# Flow:
#   1. Download repo tarball -> extract to temp -> atomic swap into
#      ${MESH_ROOT}/template/ (a failed download never leaves a half tree).
#   2. Copy template/docker-compose.yml -> /DATA/AppData/casaos/apps/mesh/
#   3. Copy template/Caddyfile -> ${MESH_ROOT}/ (bind-mounted into
#      mesh-router-caddy; see the in-place-copy note at the copy site).
#   4. Copy template/scripts/ -> ${MESH_ROOT}/scripts/ (live scripts; updates
#      take effect on the NEXT self-check run, one cycle of lag by design).
#
# Runs before ensure-stack-up.sh in scripts-config.txt, which is load-bearing:
# the compose file bind-mounts the Caddyfile, and Docker silently creates a
# DIRECTORY at a bind source that does not exist yet. This script is not the
# only guarantee though — it is skipped entirely when MESH_AUTO_UPDATE=false, so
# ensure-stack-up.sh restores the file from template/ if it is still absent.
#
# Opt out with MESH_AUTO_UPDATE=false in .env (the rest of the self-check
# still runs). Pick the source channel with MESH_UPDATE_CHANNEL (stable|main,
# default stable) or override entirely with MESH_TEMPLATE_URL (dev/testing).

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

case "${MESH_AUTO_UPDATE:-true}" in
    false|disabled|off|0)
        echo "Auto-update disabled (MESH_AUTO_UPDATE=${MESH_AUTO_UPDATE}), skipping template sync"
        exit 0
        ;;
esac

# Resolved from MESH_UPDATE_CHANNEL / MESH_TEMPLATE_URL in the sourced .env, so
# a box stays on the channel it was installed from across nightly syncs.
TARBALL_URL="$(mesh_template_url)"

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR" "${TEMPLATE_DIR}.new" "${TEMPLATE_DIR}.old"; }
trap cleanup EXIT

echo "Downloading template from $TARBALL_URL"
curl -fsSL --max-time 120 "$TARBALL_URL" -o "$TMP_DIR/template.tar.gz"

mkdir -p "$TMP_DIR/extract"
tar -xzf "$TMP_DIR/template.tar.gz" -C "$TMP_DIR/extract"

# Tarball contains a single top-level dir (mesh-router-template-root-main)
SRC=$(find "$TMP_DIR/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)
if [ -z "$SRC" ]; then
    echo "ERROR: tarball did not contain a directory"
    exit 1
fi

# Sanity check before swapping anything live
if [ ! -f "$SRC/docker-compose.yml" ] || [ ! -f "$SRC/scripts/self-check.sh" ] || [ ! -f "$SRC/Caddyfile" ]; then
    echo "ERROR: downloaded template is missing docker-compose.yml, Caddyfile or scripts/self-check.sh - aborting sync"
    exit 1
fi

# Migrations, from the DOWNLOADED tree, before anything is swapped or copied.
#
# This is the only hook that can act in the same cycle as the compose swap:
# self-check.sh runs the script list it read at startup, so an ensure-script
# added by this release does not run until pass 2 at the earliest (and its
# declared ordering not until the next cycle). Work that must land alongside the
# new docker-compose.yml — minting a secret a new service needs, dropping a
# removed one, renaming an env key — goes in scripts/migrations/.
#
# Running BEFORE the swap is what makes failure cheap: nothing has been
# propagated, so a non-zero exit just leaves the box on its current version.
# There is no half-applied tree to restore.
if [ -d "$SRC/scripts/migrations" ]; then
    echo "Running migrations from downloaded template..."
    bash "$SRC/scripts/tools/run-migrations.sh" "$SRC/scripts/migrations"
fi

# Atomic swap into TEMPLATE_DIR
rm -rf "${TEMPLATE_DIR}.new"
mkdir -p "$(dirname "$TEMPLATE_DIR")"
cp -a "$SRC" "${TEMPLATE_DIR}.new"
if [ -d "$TEMPLATE_DIR" ]; then
    mv "$TEMPLATE_DIR" "${TEMPLATE_DIR}.old"
fi
mv "${TEMPLATE_DIR}.new" "$TEMPLATE_DIR"
rm -rf "${TEMPLATE_DIR}.old"

# Propagate template-owned files to live locations.
#
# Caddyfile BEFORE docker-compose.yml, deliberately: the compose file is what
# introduces the bind mount, and self-check.sh does not abort on a failed step —
# so if this script died between the two copies, ensure-stack-up.sh would still
# run `up -d` against a compose file whose mount source does not exist, and
# Docker would materialise it as a directory.
#
# Caddyfile: bind-mounted as a single file into mesh-router-caddy.
#   - A stale run (or a compose up before this file existed) can leave a
#     DIRECTORY here; clear it or the cp below fails and Caddy never starts.
#   - Copy IN PLACE. A single-file bind mount pins the inode, so writing via a
#     temp file + mv would leave the running container reading the old content
#     until the next recreate, and the entrypoint's inotify watcher — which
#     watches the file, not the directory — would never fire.
mkdir -p "$MESH_ROOT"
if [ -d "$MESH_ROOT/Caddyfile" ]; then
    echo "Removing stray Caddyfile directory (created by a bind mount with no source file)"
    rm -rf "$MESH_ROOT/Caddyfile"
fi
cp "$TEMPLATE_DIR/Caddyfile" "$MESH_ROOT/Caddyfile"

cp "$TEMPLATE_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"

mkdir -p "$SCRIPTS_DIR"
cp -a "$TEMPLATE_DIR/scripts/." "$SCRIPTS_DIR/"
find "$SCRIPTS_DIR" -type f -name '*.sh' -exec chmod +x {} +

echo "Template synced (compose + Caddyfile + scripts updated; script changes apply next run)"
