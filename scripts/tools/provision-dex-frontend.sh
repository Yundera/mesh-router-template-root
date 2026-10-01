#!/bin/bash
# Provision the custom Dex frontend (theme + overlaid templates) into the dir
# the compose file bind-mounts over the stock image.
#
# WHY THIS IS A TOOL AND NOT JUST PART OF ensure-dex.sh
#
# The compose file bind-mounts templates/login.html and templates/header.html
# as individual FILES. Docker auto-creates a missing bind-mount source as a
# DIRECTORY. So ANY `docker compose up` that happens before these files exist
# leaves a directory where a file belongs, and from then on `dex` cannot start
# at all:
#
#   error mounting ".../dex/frontend/templates/login.html" to rootfs at
#   "/srv/dex/web/templates/login.html": not a directory
#
# Hence: every caller that is about to bring the stack up runs this first. It is
# idempotent and costs a handful of file copies. ensure-auth-stack.sh calls it for
# the same reason ensure-stack-up.sh clears a stray Caddyfile DIRECTORY.
#
# A missing source (dex-theme/ absent from the template) is not an error — Dex
# just keeps its stock UI.
set -e

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

# Resolve dex-theme/ from THIS SCRIPT'S OWN TREE first, falling back to the
# synced template/ directory — the same two-path rule as ensure-authelia.sh's
# config template, and for the same reason. ensure-template-sync propagates only
# compose/Caddyfile/scripts, so in the LIVE layout template/ is the only copy of
# dex-theme/; but when this runs from a freshly extracted tree (via a migration,
# before the swap) template/ still holds the OLD version, which may have no
# dex-theme/ at all.
SELF_TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
THEME_SRC="$SELF_TREE/dex-theme"
[ -d "$THEME_SRC" ] || THEME_SRC="$TEMPLATE_DIR/dex-theme"

# DEX_THEME_SRC in .env points at another directory of the same shape
# (templates/*.html and themes/<name>/) and replaces the login UI wholesale — a
# deployment's own branding, with no fork of this template. An unset or missing
# path falls back to the shipped theme rather than to Dex's stock UI.
if [ -n "${DEX_THEME_SRC:-}" ]; then
    if [ -d "$DEX_THEME_SRC/templates" ] && [ -d "$DEX_THEME_SRC/themes" ]; then
        THEME_SRC="$DEX_THEME_SRC"
    else
        echo "WARN: DEX_THEME_SRC=$DEX_THEME_SRC has no templates/ and themes/; using the shipped login theme"
    fi
fi

# The SLOT the theme is installed into: `frontend.theme` in
# scripts/self-check/dex.config.yaml.tmpl and the themes/ bind mount in
# stacks/auth/docker-compose.yml both name it, so it stays fixed whatever the
# source directory calls its theme. Nothing a user sees carries this name — the
# templates reference assets as theme/<file>.
THEME_NAME="mesh"
# Lives INSIDE dex/ rather than beside it: same owner, same lifecycle, same "pure
# cache" rule as the rest of dex/ (see the RECOVERY note in ensure-dex.sh). The
# dex container bind-mounts dex/ at /data, so it also sees these files at
# /data/frontend/ — harmless, Dex reads only /data/config.yaml and /data/dex.db.
#
# Was $MESH_ROOT/dex-frontend until the auth state moved into the auth stack's
# folder; ensure-auth-stack.sh sweeps that copy once the stack runs from this one.
DEX_FRONTEND="$DEX_HOME/frontend"

if [ ! -d "$THEME_SRC" ]; then
    echo "dex-theme/ not found in template; Dex will use its stock login UI"
    exit 0
fi

mkdir -p "$DEX_FRONTEND/templates" "$DEX_FRONTEND/themes"

RC=0

# Copy file-by-file, clearing a DIRECTORY sitting where a file belongs. A plain
# `cp -f file dir/` will NOT fix that — cp refuses to overwrite a directory — and
# swallowing the refusal would leave the box logging "provisioned" while having
# no IdP and therefore no login of any kind.
for _src in "$THEME_SRC/templates/"*.html; do
    [ -e "$_src" ] || continue
    _dst="$DEX_FRONTEND/templates/$(basename "$_src")"
    [ -f "$_dst" ] || rm -rf "$_dst"
    if ! cp -f "$_src" "$_dst"; then
        echo "WARN: could not provision $_dst"
        RC=1
    fi
done

# Same trap for the theme, in the other direction: this one IS a directory, and
# Docker would have created it as one too, so only a stale file needs clearing.
[ -d "$DEX_FRONTEND/themes/$THEME_NAME" ] || rm -f "$DEX_FRONTEND/themes/$THEME_NAME"
mkdir -p "$DEX_FRONTEND/themes/$THEME_NAME"

# Refresh the theme's CONTENTS in place. Do NOT `rm -rf` the directory itself:
# compose bind-mounts THIS directory into the dex container, and a bind mount
# follows the inode, not the path. Deleting and re-creating it leaves the running
# container mounted on the deleted inode — visible in the container's
# /proc/self/mountinfo as ".../themes/<name>//deleted" — so every theme/* asset
# 404s and the login page renders with static/main.css only: no wallpaper, no
# card, no logo, browser-default serif type.
#
# `docker restart dex` does NOT re-resolve a bind source, so ensure-dex.sh's
# restart at the end of its run does not repair this; only a force-recreate does.
# Since this tool runs before every stack-up, doing it the wrong way would
# re-break the theme on each self-check.
#
# Emptying the directory and copying into it keeps the inode the container is
# holding, so a running dex picks the new files up with no restart at all.
find "$DEX_FRONTEND/themes/$THEME_NAME" -mindepth 1 -delete 2>/dev/null || true
# From themes/mesh when the source has one, else from its only theme directory —
# a DEX_THEME_SRC is free to name its theme after its own product.
THEME_FROM="$THEME_SRC/themes/$THEME_NAME"
[ -d "$THEME_FROM" ] || THEME_FROM="$(find "$THEME_SRC/themes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n 1)"
if [ -z "$THEME_FROM" ] || ! cp -rf "$THEME_FROM/." "$DEX_FRONTEND/themes/$THEME_NAME/"; then
    echo "WARN: could not provision $DEX_FRONTEND/themes/$THEME_NAME"
    RC=1
fi

echo "Provisioned custom Dex frontend at $DEX_FRONTEND"
exit "$RC"
