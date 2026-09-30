#!/bin/bash
# ensure-terminal-stack.sh - Deploy the web Terminal as a system app.
#
# The stack is the Yundera AppStore's Terminal app, copied into stacks/terminal/ (see the
# header there). The app configures itself — its SSH key and authorized_keys line are
# set up by the container at start (TERMINAL_SETUP) — so this script only does what the
# store install would: supply the deployment's variables and bring it up.
#
# The store compose reads the variables Maison gives every app (APP_DOMAIN,
# APP_PUBLIC_IP_DASH, APP_NET, and `domain`), which the mesh .env does not carry, so they
# are passed to deploy-stack.sh here. DATA_ROOT comes through the .env as it is.
#
# HOST USER. A PCS has an `admin` sudoer, the app's default; a mesh box has no managed
# Linux account (its login is an Authelia account), so the session logs in as `root`
# unless TERMINAL_USER in the mesh .env names another. Whichever it is must be allowed
# to log in over SSH with a key — Ubuntu's default `PermitRootLogin prohibit-password`
# is — and the box must run sshd.
#
# Deployed to ${DATA_ROOT}/AppData/terminal (no dot in the name, so Maison's managed
# scan tiles it in the System grid) — the same directory and compose project the store
# app installs into, so a store install is adopted in place.
#
# Opt out with TERMINAL_ENABLED=false (or 0/no/off) in the mesh .env: the stack is taken
# down and not redeployed. Default is enabled.
#
# ORDERING: must run AFTER ensure-auth-stack.sh — the gate needs auth-registrar / dex
# (auth stack) reachable by name on `pcs`.
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

STACK_DIR="${DATA_ROOT:-/DATA}/AppData/terminal"

ENABLED="$(get_env_value TERMINAL_ENABLED || true)"
case "$(printf '%s' "$ENABLED" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off)
        if [ -f "$STACK_DIR/docker-compose.yml" ] && docker compose version >/dev/null 2>&1; then
            log_info "Terminal disabled by TERMINAL_ENABLED in $ENV_FILE - taking the terminal stack down"
            docker compose --project-directory "$STACK_DIR" \
                -f "$STACK_DIR/docker-compose.yml" down --remove-orphans \
                || log_warn "Terminal stack teardown failed; continuing"
        fi
        exit 0
        ;;
esac

DOMAIN="$(get_env_value DOMAIN || true)"
TERMINAL_USER="$(get_env_value TERMINAL_USER || true)"

exec "$SCRIPTS_DIR/tools/deploy-stack.sh" terminal "$STACK_DIR" \
    "APP_NET=pcs" \
    "APP_DOMAIN=$DOMAIN" \
    "domain=$DOMAIN" \
    "APP_PUBLIC_IP_DASH=$(get_env_value PUBLIC_IP_DASH || true)" \
    "TERMINAL_USER=${TERMINAL_USER:-root}"
