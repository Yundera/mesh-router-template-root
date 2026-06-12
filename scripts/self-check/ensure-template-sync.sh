#!/bin/bash
# Auto-update: sync the template from GitHub and propagate template-owned
# files to their live locations.
#
# Ownership rule (the contract that makes auto-update safe):
#   template-owned (overwritten here): docker-compose.yml, scripts/
#   user-owned (NEVER touched here):   .env, ${MESH_ROOT}/data/
#
# Flow:
#   1. Download repo tarball -> extract to temp -> atomic swap into
#      ${MESH_ROOT}/template/ (a failed download never leaves a half tree).
#   2. Copy template/docker-compose.yml -> /DATA/AppData/casaos/apps/mesh/
#   3. Copy template/scripts/ -> ${MESH_ROOT}/scripts/ (live scripts; updates
#      take effect on the NEXT self-check run, one cycle of lag by design).
#
# Opt out with MESH_AUTO_UPDATE=false in .env (the rest of the self-check
# still runs). Override the source with MESH_TEMPLATE_URL (dev/testing).

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

case "${MESH_AUTO_UPDATE:-true}" in
    false|disabled|off|0)
        echo "Auto-update disabled (MESH_AUTO_UPDATE=${MESH_AUTO_UPDATE}), skipping template sync"
        exit 0
        ;;
esac

TARBALL_URL="${MESH_TEMPLATE_URL:-https://github.com/yundera/mesh-router-template-root/archive/refs/heads/main.tar.gz}"

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
if [ ! -f "$SRC/docker-compose.yml" ] || [ ! -f "$SRC/scripts/self-check.sh" ]; then
    echo "ERROR: downloaded template is missing docker-compose.yml or scripts/self-check.sh - aborting sync"
    exit 1
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

# Propagate template-owned files to live locations
cp "$TEMPLATE_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"
mkdir -p "$SCRIPTS_DIR"
cp -a "$TEMPLATE_DIR/scripts/." "$SCRIPTS_DIR/"
find "$SCRIPTS_DIR" -type f -name '*.sh' -exec chmod +x {} +

echo "Template synced (compose + scripts updated; script changes apply next run)"
