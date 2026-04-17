#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[FAIL] install.sh line $LINENO exited $?" >&2' ERR

# Mesh Router Installer
# Usage: curl -fsSL https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main/install.sh | bash -s -- \
#   --provider "https://nsl.sh/router/api,userid,signature" --domain alice.nsl.sh

REPO_BASE="https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@main"
INSTALL_DIR="/DATA/AppData/casaos/apps/mesh"

# Defaults
PROVIDER=""
DOMAIN=""
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
  --public-ip   Server public IP (auto-detected if omitted)
  --data-root   Data storage path (default: /DATA)
  --local       Path to local docker-compose.yml (skip CDN download)
  --windows     Windows/WSL mode (DATA_ROOT=/c/DATA, user 0:0, no rshared)
  --help        Show this help
EOF
  exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)  PROVIDER="$2"; shift 2 ;;
    --domain)    DOMAIN="$2"; shift 2 ;;
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

# 1. Check/install Docker
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  echo "[OK] Docker is installed"
else
  echo "[..] Docker not found, installing..."
  curl -fsSL https://get.docker.com | sh
  echo "[OK] Docker installed"
fi

# 2. Auto-detect public IP if not provided
if [[ -z "$PUBLIC_IP" ]]; then
  echo "[..] Detecting public IP..."
  PUBLIC_IP=$(curl -4s --max-time 5 ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$PUBLIC_IP" ]]; then
    echo "[OK] Public IP: $PUBLIC_IP"
  else
    echo "[!!] Could not detect public IP (direct routing via agent will be disabled)"
  fi
else
  echo "[OK] Public IP: $PUBLIC_IP"
fi

# 3. Windows/WSL mode
# On Windows/WSL, host paths use /c/DATA but CasaOS inside the container sees /DATA.
# We keep INSTALL_DIR at /DATA/... so docker compose labels match what CasaOS expects,
# but create a symlink from /DATA -> /c/DATA so files are on the Windows filesystem.
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
  # INSTALL_DIR stays at /DATA/... path so compose labels match CasaOS
fi

# 4. Compute derived values
PUBLIC_IP_DASH=$(echo "$PUBLIC_IP" | tr '.:' '-')
EMAIL="admin@${DOMAIN}"

# 5. Create directories
echo "[..] Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_ROOT"
mkdir -p "$DATA_ROOT/AppData/yundera/data/certs"
mkdir -p "$DATA_ROOT/AppData/yundera/data/caddy/data"
mkdir -p "$DATA_ROOT/AppData/yundera/data/caddy/config"
echo "[OK] Install dir: $INSTALL_DIR"

# Seed a platform secret consumed by app-store apps via $APP_DEFAULT_PASSWORD /
# $PCS_DEFAULT_PASSWORD. Preserve across reruns — regenerating would invalidate
# every app's DB password and admin token.
DEFAULT_PASSWORD=""
if [[ -f "$INSTALL_DIR/.env" ]]; then
  DEFAULT_PASSWORD=$(grep -E '^DEFAULT_PASSWORD=' "$INSTALL_DIR/.env" | head -n1 | cut -d= -f2- || true)
fi
if [[ -z "$DEFAULT_PASSWORD" ]]; then
  DEFAULT_PASSWORD=$(LC_ALL=C head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)
fi

# 6. Get docker-compose.yml
if [[ -n "$LOCAL_COMPOSE" ]]; then
  echo "[..] Copying local docker-compose.yml..."
  cp "$LOCAL_COMPOSE" "$INSTALL_DIR/docker-compose.yml"
  echo "[OK] docker-compose.yml copied from $LOCAL_COMPOSE"
else
  echo "[..] Downloading docker-compose.yml..."
  curl -fsSL "$REPO_BASE/docker-compose.yml" -o "$INSTALL_DIR/docker-compose.yml"
  echo "[OK] docker-compose.yml downloaded"
fi

# 7. Patch docker-compose.yml for Windows mode
if [[ "$WINDOWS_MODE" == true ]]; then
  echo "[..] Patching docker-compose for Windows..."
  # Remove rshared propagation (not supported on Docker Desktop)
  sed -i '/bind:/,/propagation: rshared/d' "$INSTALL_DIR/docker-compose.yml"
  echo "[OK] Windows patches applied"
fi

# 8. Write .env
cat > "$INSTALL_DIR/.env" <<EOF
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
EOF
chmod 600 "$INSTALL_DIR/.env"
echo "[OK] .env written"

# 9. Start containers
echo "[..] Starting containers..."
cd "$INSTALL_DIR"
docker compose up -d

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Domain:    https://${DOMAIN}"
echo "  Install:   ${INSTALL_DIR}"
echo ""
echo "Open https://${DOMAIN} in your browser to complete CasaOS first-run setup."
echo "To update, re-run this command."
