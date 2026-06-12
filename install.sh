#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[FAIL] install.sh line $LINENO exited $?" >&2' ERR

# Mesh Router Installer
#
# Thin bootstrap: lay down the template (docker-compose.yml + self-check scripts)
# and a minimal .env, then hand off to self-check.sh. The self-check installs
# Docker, backfills .env defaults, syncs the template, pulls images, brings the
# stack up, and verifies routing — shown live as a per-step checklist (--display).
#
# Usage:
#   curl -fsSL https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh \
#     | sudo -E bash -s -- --provider "https://nsl.sh/router/api,userid,signature" \
#       --domain alice.nsl.sh [--email you@example.com]
#
# Windows/WSL (--windows) installs are Linux-self-check-incompatible (cron,
# logrotate, apt) and stay on a direct one-shot path: compose up, no auto-update.

TARBALL_URL="${MESH_TEMPLATE_URL:-https://github.com/yundera/mesh-router-template-root/archive/refs/heads/main.tar.gz}"
APP_DIR="/DATA/AppData/casaos/apps/mesh"   # CasaOS-visible surface: compose + .env only

# Defaults
PROVIDER=""
DOMAIN=""
EMAIL_ARG=""
PUBLIC_IP=""
DATA_ROOT="/DATA"
LOCAL_COMPOSE=""
WINDOWS_MODE=false
PUID="1000"
PGID="1000"

usage() {
  cat <<EOF
Yundera Mesh Router Installer

Usage:
  install.sh --provider <provider-string> --domain <domain> [options]

Required:
  --provider    Provider connection string (backend_url,userid,signature)
  --domain      Your domain (e.g. alice.nsl.sh)

Options:
  --email       Account email exposed to installed apps (default: admin@<domain>)
  --public-ip   Server public IP (auto-detected by self-check if omitted)
  --data-root   Data storage path (default: /DATA)
  --local       Path to a local docker-compose.yml (also pulls scripts/ beside
                it); skips the CDN and disables auto-update — for dev/testing
  --windows     Windows/WSL mode (DATA_ROOT=/c/DATA, user 0:0, no rshared,
                no self-check)
  --help        Show this help
EOF
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)  PROVIDER="$2"; shift 2 ;;
    --domain)    DOMAIN="$2"; shift 2 ;;
    --email)     EMAIL_ARG="$2"; shift 2 ;;
    --public-ip) PUBLIC_IP="$2"; shift 2 ;;
    --data-root) DATA_ROOT="$2"; shift 2 ;;
    --local)     LOCAL_COMPOSE="$2"; shift 2 ;;
    --windows)   WINDOWS_MODE=true; shift ;;
    --help)      usage ;;
    *)           echo "Unknown option: $1"; usage ;;
  esac
done

# Validate required params
if [[ -z "$PROVIDER" ]]; then
  echo "Error: --provider is required"
  usage
fi
if [[ -z "$DOMAIN" ]]; then
  echo "Error: --domain is required"
  usage
fi

if [[ $EUID -ne 0 ]]; then
  echo "Error: this installer must run as root." >&2
  echo "Try: curl -fsSL <url> | sudo -E bash -s -- --provider ... --domain ..." >&2
  exit 1
fi

echo "=== Yundera Mesh Router Installer ==="
echo ""

# 1. Windows/WSL mode
# On Windows/WSL, host paths use /c/DATA but CasaOS inside the container sees
# /DATA. We keep APP_DIR at /DATA/... so docker compose labels match what CasaOS
# expects, but symlink /DATA -> /c/DATA so files land on the Windows filesystem.
if [[ "$WINDOWS_MODE" == true ]]; then
  echo "[!!] Windows mode enabled"
  DATA_ROOT="/c/DATA"
  PUID="0"
  PGID="0"
  mkdir -p "$DATA_ROOT"
  if [[ ! -e /DATA ]]; then
    ln -sf /c/DATA /DATA
    echo "[OK] Symlinked /DATA -> /c/DATA"
  fi
fi

MESH_ROOT="$DATA_ROOT/AppData/mesh"
SCRIPTS_DIR="$MESH_ROOT/scripts"
TEMPLATE_DIR="$MESH_ROOT/template"

# 2. Create directories
# APP_DIR holds only what CasaOS needs to see (compose + .env); everything else
# (data, template, scripts, log) lives under ${DATA_ROOT}/AppData/mesh.
echo "[..] Creating directories..."
mkdir -p "$APP_DIR" "$DATA_ROOT" \
  "$MESH_ROOT/data/certs" \
  "$MESH_ROOT/data/caddy/data" \
  "$MESH_ROOT/data/caddy/config" \
  "$MESH_ROOT/log" \
  "$SCRIPTS_DIR" "$TEMPLATE_DIR"
echo "[OK] Layout under $MESH_ROOT"

# Auto-update toggle (nightly self-check re-syncs compose + scripts from main).
# Preserve a user's opt-out across reruns; default off for --local dev installs
# so the sync doesn't clobber local files with the published template.
MESH_AUTO_UPDATE=""
if [[ -f "$APP_DIR/.env" ]]; then
  MESH_AUTO_UPDATE=$(grep -E '^MESH_AUTO_UPDATE=' "$APP_DIR/.env" | head -n1 | cut -d= -f2- || true)
fi
if [[ -z "$MESH_AUTO_UPDATE" ]]; then
  if [[ -n "$LOCAL_COMPOSE" ]]; then
    MESH_AUTO_UPDATE="false"
  else
    MESH_AUTO_UPDATE="true"
  fi
fi

# Fetch the repo tarball and lay down template/, scripts/, and compose.
download_template() {
  local tmp; tmp=$(mktemp -d)
  curl -fsSL --max-time 120 "$TARBALL_URL" -o "$tmp/template.tar.gz"
  mkdir -p "$tmp/extract"
  tar -xzf "$tmp/template.tar.gz" -C "$tmp/extract"
  local src; src=$(find "$tmp/extract" -mindepth 1 -maxdepth 1 -type d | head -n1)
  if [[ -z "$src" || ! -f "$src/docker-compose.yml" || ! -f "$src/scripts/self-check.sh" ]]; then
    echo "Error: downloaded template is incomplete (missing compose or self-check.sh)" >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$TEMPLATE_DIR"
  cp -a "$src" "$TEMPLATE_DIR"
  cp -a "$TEMPLATE_DIR/scripts/." "$SCRIPTS_DIR/"
  cp "$TEMPLATE_DIR/docker-compose.yml" "$APP_DIR/docker-compose.yml"
  rm -rf "$tmp"
}

# 3. Copy template into place (compose + scripts)
if [[ -n "$LOCAL_COMPOSE" ]]; then
  src_dir=$(cd "$(dirname "$LOCAL_COMPOSE")" && pwd)
  if [[ -d "$src_dir/scripts" ]]; then
    echo "[..] Copying template from $src_dir..."
    cp "$LOCAL_COMPOSE" "$APP_DIR/docker-compose.yml"
    cp -a "$src_dir/scripts/." "$SCRIPTS_DIR/"
    # Mirror compose + scripts into template/ for layout consistency (local mode
    # has auto-update off, so template/ is reference-only and never re-synced).
    mkdir -p "$TEMPLATE_DIR/scripts"
    cp "$LOCAL_COMPOSE" "$TEMPLATE_DIR/docker-compose.yml"
    cp -a "$src_dir/scripts/." "$TEMPLATE_DIR/scripts/"
    echo "[OK] Template + scripts copied from $src_dir/scripts"
  else
    echo "[..] No scripts/ beside $LOCAL_COMPOSE — fetching template from CDN..."
    download_template
    cp "$LOCAL_COMPOSE" "$APP_DIR/docker-compose.yml"
    echo "[OK] Scripts fetched; compose taken from $LOCAL_COMPOSE"
  fi
else
  echo "[..] Downloading template..."
  download_template
  echo "[OK] Template installed"
fi
find "$SCRIPTS_DIR" -type f -name '*.sh' -exec chmod +x {} +

# ---------------------------------------------------------------------------
# Windows: no Linux self-check (cron/logrotate/apt). Write a complete .env and
# bring the stack up directly — there is no ensure-*.sh to backfill anything.
# ---------------------------------------------------------------------------
if [[ "$WINDOWS_MODE" == true ]]; then
  echo "[..] Patching docker-compose for Windows (remove rshared)..."
  sed -i '/bind:/,/propagation: rshared/d' "$APP_DIR/docker-compose.yml"

  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP=$(curl -4s --max-time 5 ifconfig.me 2>/dev/null || echo "")
  fi
  PUBLIC_IP_DASH=$(echo "$PUBLIC_IP" | tr '.:' '-')
  EMAIL="${EMAIL_ARG:-admin@${DOMAIN}}"

  # Platform secret consumed by app-store apps. Preserve across reruns —
  # regenerating would invalidate every app's DB password and admin token.
  DEFAULT_PASSWORD=""
  if [[ -f "$APP_DIR/.env" ]]; then
    DEFAULT_PASSWORD=$(grep -E '^DEFAULT_PASSWORD=' "$APP_DIR/.env" | head -n1 | cut -d= -f2- || true)
  fi
  if [[ -z "$DEFAULT_PASSWORD" ]]; then
    DEFAULT_PASSWORD=$(LC_ALL=C head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)
  fi

  cat > "$APP_DIR/.env" <<EOF
PROVIDER=${PROVIDER}
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_IP_DASH=${PUBLIC_IP_DASH}
DATA_ROOT=${DATA_ROOT}
DEFAULT_PASSWORD=${DEFAULT_PASSWORD}
EMAIL=${EMAIL}
DEFAULT_SERVICE_HOST=casaos
DEFAULT_SERVICE_PORT=8080
PUID=${PUID}
PGID=${PGID}
MESH_AUTO_UPDATE=false
EOF
  chmod 600 "$APP_DIR/.env"
  echo "[OK] .env written"

  echo "[..] Starting containers..."
  cd "$APP_DIR"
  docker compose up -d

  echo ""
  echo "=== Installation complete (Windows) ==="
  echo "  Domain:  https://${DOMAIN}"
  echo "  Install: ${APP_DIR}"
  echo ""
  echo "Open https://${DOMAIN} to complete CasaOS first-run setup. Re-run to update."
  exit 0
fi

# ---------------------------------------------------------------------------
# Linux: write a MINIMAL .env (only what self-check can't derive) and hand off.
# ensure-env-valid backfills DEFAULT_PASSWORD, service host/port, PUID/PGID, and
# EMAIL; ensure-public-ip detects PUBLIC_IP; ensure-template-sync owns compose.
# ---------------------------------------------------------------------------
echo "[..] Writing .env..."
{
  echo "PROVIDER=${PROVIDER}"
  echo "DOMAIN=${DOMAIN}"
  [[ -n "$EMAIL_ARG" ]] && echo "EMAIL=${EMAIL_ARG}"
  [[ -n "$PUBLIC_IP" ]] && echo "PUBLIC_IP=${PUBLIC_IP}"
  echo "DATA_ROOT=${DATA_ROOT}"
  echo "MESH_AUTO_UPDATE=${MESH_AUTO_UPDATE}"
} > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
echo "[OK] .env written"

echo ""
echo "[..] Running self-check (installs Docker, brings up the stack, verifies routing)..."
echo ""
SELF_CHECK_RC=0
bash "$SCRIPTS_DIR/self-check.sh" --display || SELF_CHECK_RC=$?

echo ""
if [[ "$SELF_CHECK_RC" -eq 0 ]]; then
  echo "=== Installation complete ==="
  echo "  Domain:  https://${DOMAIN}"
  echo "  Install: ${APP_DIR}"
  echo ""
  echo "Open https://${DOMAIN} in your browser to complete CasaOS first-run setup."
  echo "To update, re-run this command (or wait for the nightly self-check)."
else
  echo "=== Installation finished with self-check failures (exit ${SELF_CHECK_RC}) ==="
  echo "  Log:    ${MESH_ROOT}/log/mesh.log"
  echo "  Re-run: sudo bash ${SCRIPTS_DIR}/self-check.sh --display"
fi

exit "$SELF_CHECK_RC"
