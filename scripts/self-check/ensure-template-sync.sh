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
#   2. Copy template/docker-compose.yml -> /DATA/AppData/mesh/
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
# still runs). Choose the source with UPDATE_URL (a full tarball URL; default is
# the stable branch) — see mesh_template_url() in library/common.sh.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

case "${MESH_AUTO_UPDATE:-true}" in
    false|disabled|off|0)
        echo "Auto-update disabled (MESH_AUTO_UPDATE=${MESH_AUTO_UPDATE}), skipping template sync"
        exit 0
        ;;
esac

# Resolved from UPDATE_URL (or the deprecated channel keys) in the loaded .env, so
# a box stays on the source it was installed from across nightly syncs.
TARBALL_URL="$(mesh_template_url)"

# Yundera/template-root's UPDATE_URL points at a .zip; this template ships a
# .tar.gz and extracts with tar. Same key name, different archive format — say so
# plainly instead of failing later with an opaque "tar: not in gzip format".
case "$TARBALL_URL" in
    *.zip)
        echo "ERROR: UPDATE_URL points at a .zip ($TARBALL_URL)."
        echo "       This template is distributed as .tar.gz and extracts with tar."
        echo "       Use the .tar.gz form, e.g. .../archive/refs/heads/main.tar.gz"
        exit 1
        ;;
esac

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

# Scripts: copy to a temp file in the destination directory, then rename over the
# target. NEVER a plain `cp` onto the live path — that is the exact opposite of
# the Caddyfile rule above, and for a good reason.
#
# THIS SCRIPT AND self-check.sh ARE RUNNING RIGHT NOW, FROM THIS DIRECTORY.
# Bash does not read a script into memory up front; it reads and parses lazily,
# tracking a byte offset into the open file. Overwrite that file in place and the
# interpreter carries on at its old offset inside the NEW bytes, which lands
# mid-token and dies with a syntax error that points at a line the old file never
# had. Observed on a real update: `ensure-template-sync.sh: line 121: syntax
# error near unexpected token '('` from a 105-line script, plus self-check.sh
# faulting in its own loop — while both files were perfectly valid on disk.
# The abort left migrations unrun and the template half-applied.
#
# `mv` is a rename: the destination gets a NEW inode and the old one lives on,
# unlinked, held open by the running interpreter, which reads it cleanly to the
# end. Next run picks up the new content — the same one-cycle lag as before.
#
# Files deleted upstream are NOT removed here (there is no --delete), so a
# retired script lingers until something prunes it. Harmless: scripts-config.txt
# is the only thing that decides what runs.
mkdir -p "$SCRIPTS_DIR"
# Clear temp files from a previous run that died between mktemp and mv.
find "$SCRIPTS_DIR" -type f -name '.sync.*' -delete 2>/dev/null || true

while IFS= read -r -d '' src; do
    rel="${src#"$TEMPLATE_DIR/scripts/"}"
    dst="$SCRIPTS_DIR/$rel"
    mkdir -p "$(dirname "$dst")"
    tmp="$(mktemp "$(dirname "$dst")/.sync.XXXXXX")"
    cp -a "$src" "$tmp"
    # chmod BEFORE the rename so the script is never briefly visible
    # non-executable to a concurrent run.
    case "$src" in *.sh) chmod +x "$tmp" ;; esac
    mv -f "$tmp" "$dst"
done < <(find "$TEMPLATE_DIR/scripts" -type f -print0)

echo "Template synced (compose + Caddyfile + scripts updated; script changes apply next run)"
