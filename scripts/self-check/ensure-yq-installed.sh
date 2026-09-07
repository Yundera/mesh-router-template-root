#!/bin/bash
# ensure-yq-installed.sh - install yq (mikefarah v4), the YAML processor
# tools/authelia-user-manager.sh depends on.
#
# WHY THIS EXISTS, AND WHY IT IS THE ONLY ONE OF ITS KIND
#
# This template otherwise requires nothing on the host beyond coreutils, bash,
# curl, tar and docker — which is why it renders templates with bash parameter
# expansion instead of envsubst (no gettext) and shells out to the authelia image
# for hashing instead of needing argon2 locally. `yq` is a deliberate exception,
# taken so authelia-user-manager.sh can be a straight port of the managed
# template's version rather than a second, drifting implementation of the same
# read-modify-write over users_database.yml.
#
# It is NOT a hard dependency of login. Nothing in the boot path needs yq:
# ensure-dex.sh's claimed-ness probe treats a missing yq as "claimed" and renders
# the Local Account connector anyway (fail open). Only the user-management verbs
# — claim, add, delete, set-password — require it, and those are interactive.
#
# Pinned by version, and installed to /usr/local/bin so a distro package (if the
# box grows one later) takes precedence on PATH order without a conflict.
set -e

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

YQ_VERSION="v4.44.1"

if command -v yq >/dev/null 2>&1; then
    echo "yq is already installed: $(yq --version 2>/dev/null || echo unknown)"
    exit 0
fi

# dpkg is Debian/Ubuntu-only; fall back to uname so this degrades on other
# distros instead of dying. A box we cannot map is not a failure — see the exit 0
# below.
if command -v dpkg >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture)"
else
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armhf" ;;
        *)       ARCH="$(uname -m)" ;;
    esac
fi

case "$ARCH" in
    amd64) YQ_BINARY="yq_linux_amd64" ;;
    arm64) YQ_BINARY="yq_linux_arm64" ;;
    armhf) YQ_BINARY="yq_linux_arm" ;;
    *)
        # Deliberately NOT fatal. yq is only needed for the interactive user-
        # management verbs, and failing the whole self-check — which also brings
        # the stack up and registers routes — over an optional tool would take a
        # working box offline for a feature it may never use.
        log_warn "No yq build for architecture '$ARCH'; user-management verbs (claim, set-password) will be unavailable"
        exit 0
        ;;
esac

URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
TMP="$(mktemp)"

echo "Installing yq ${YQ_VERSION} (${YQ_BINARY})..."
if ! curl -fsSL --max-time 120 "$URL" -o "$TMP"; then
    rm -f "$TMP"
    log_warn "Could not download yq from $URL; user-management verbs will be unavailable until the next run"
    exit 0
fi

chmod +x "$TMP"
# Verify it actually runs before installing it — a truncated download or an HTML
# error page saved as the binary would otherwise sit on PATH looking installed
# and fail at the moment someone is trying to claim their account.
if ! "$TMP" --version >/dev/null 2>&1; then
    rm -f "$TMP"
    log_warn "Downloaded yq did not execute; leaving it uninstalled"
    exit 0
fi

mv "$TMP" /usr/local/bin/yq
log_success "yq installed: $(yq --version 2>/dev/null)"
