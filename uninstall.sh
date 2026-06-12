#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[FAIL] uninstall.sh line $LINENO exited $?" >&2' ERR

# Mesh Router Uninstaller
#
# Removes the mesh-router install WITHOUT touching user data. It:
#   - stops & removes the docker stack `mesh` (tunnel, agent, caddy, smtp,
#     casaos) and its caddy volumes
#   - removes the nightly self-check cron entry and the logrotate config
#   - deletes the two mesh-owned folders:
#       /DATA/AppData/casaos/apps/mesh   (docker-compose.yml + .env)
#       ${DATA_ROOT}/AppData/mesh        (template, scripts, log, data/certs+caddy)
#
# It does NOT remove: Docker, user-installed apps, the `pcs` network if it is
# still in use, or any user data (/DATA/Documents, /DATA/Downloads, /DATA/Media,
# /DATA/AppData/<other apps>).
#
# Usage:
#   curl -fsSL https://nsl.sh/dashboard/uninstall.sh | sudo bash -s -- --yes
#   sudo bash uninstall.sh [--yes] [--data-root /DATA]

APP_DIR="/DATA/AppData/casaos/apps/mesh"   # CasaOS-visible surface: compose + .env
ENV_FILE="$APP_DIR/.env"

ASSUME_YES=false
DATA_ROOT_OVERRIDE=""

usage() {
  cat <<EOF
Yundera Mesh Router Uninstaller

Usage:
  uninstall.sh [options]

Options:
  -y, --yes        Skip the confirmation prompt
  --data-root DIR  Data root to clean (default: read from .env, else /DATA)
  --help           Show this help

Removes the mesh stack, its cron + logrotate, and the mesh folders.
User data under /DATA is never touched.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=true; shift ;;
    --data-root) DATA_ROOT_OVERRIDE="$2"; shift 2 ;;
    --help)      usage ;;
    *)           echo "Unknown option: $1"; usage ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Error: this uninstaller must run as root." >&2
  exit 1
fi

# Resolve DATA_ROOT: explicit override > .env > default /DATA
DATA_ROOT="/DATA"
if [[ -n "$DATA_ROOT_OVERRIDE" ]]; then
  DATA_ROOT="$DATA_ROOT_OVERRIDE"
elif [[ -f "$ENV_FILE" ]]; then
  ENV_DATA_ROOT=$(grep -E '^DATA_ROOT=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)
  [[ -n "$ENV_DATA_ROOT" ]] && DATA_ROOT="$ENV_DATA_ROOT"
fi
MESH_ROOT="$DATA_ROOT/AppData/mesh"

# Safety: never rm -rf an unexpected path
if [[ -z "$DATA_ROOT" || "$DATA_ROOT" == "/" ]]; then
  echo "Error: refusing to operate with DATA_ROOT='$DATA_ROOT'" >&2
  exit 1
fi
case "$MESH_ROOT" in
  */AppData/mesh) : ;;
  *) echo "Error: refusing to remove unexpected MESH_ROOT='$MESH_ROOT'" >&2; exit 1 ;;
esac

echo "=== Yundera Mesh Router Uninstaller ==="
echo ""
echo "This will remove:"
echo "  - docker stack 'mesh' (tunnel, agent, caddy, smtp, casaos) + caddy volumes"
echo "  - the nightly self-check cron entry + /etc/logrotate.d/mesh-router"
echo "  - $APP_DIR"
echo "  - $MESH_ROOT"
echo ""
echo "It will NOT touch Docker, user-installed apps, or user data"
echo "(/DATA/Documents, /DATA/Downloads, /DATA/Media, other /DATA/AppData apps)."
echo ""

if [[ "$ASSUME_YES" != true ]]; then
  if [[ -r /dev/tty ]]; then
    printf "Type 'yes' to proceed: "
    read -r reply < /dev/tty || reply=""
    if [[ "$reply" != "yes" ]]; then
      echo "Aborted."
      exit 0
    fi
  else
    echo "Error: no terminal to confirm. Re-run with --yes to proceed." >&2
    exit 1
  fi
fi

# 1. Stop & remove the docker stack
if command -v docker >/dev/null 2>&1; then
  if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
    echo "[..] Stopping mesh stack (docker compose down)..."
    (cd "$APP_DIR" && docker compose down -v --remove-orphans) || true
  else
    echo "[..] compose file missing; removing known containers by name..."
    docker rm -f mesh-router-tunnel mesh-router-agent mesh-router-caddy smtp casaos >/dev/null 2>&1 || true
  fi
  # Remove the pcs network only if nothing else is attached (fails harmlessly otherwise).
  docker network rm pcs >/dev/null 2>&1 || true
  echo "[OK] Stack removed"
else
  echo "[!!] docker not found; skipping container removal"
fi

# 2. Remove the nightly self-check cron entry (marker-based, like the installer)
if command -v crontab >/dev/null 2>&1; then
  MARKER="# MESH_ROUTER_SELFCHECK"
  CURRENT=$(crontab -l 2>/dev/null || true)
  if echo "$CURRENT" | grep -qF "$MARKER"; then
    FILTERED=$(echo "$CURRENT" | grep -vF "$MARKER" || true)
    printf '%s\n' "$FILTERED" | crontab - || true
    echo "[OK] Removed self-check cron entry"
  else
    echo "[OK] No self-check cron entry found"
  fi
fi

# 3. Remove the logrotate config
if [[ -f /etc/logrotate.d/mesh-router ]]; then
  rm -f /etc/logrotate.d/mesh-router
  echo "[OK] Removed /etc/logrotate.d/mesh-router"
fi

# 4. Remove the mesh-owned folders (no user data lives here)
echo "[..] Removing mesh folders..."
rm -rf "$APP_DIR"
rm -rf "$MESH_ROOT"
echo "[OK] Removed $APP_DIR and $MESH_ROOT"

echo ""
echo "=== Uninstall complete ==="
echo "User data under /DATA (Documents, Downloads, Media, other apps) was left intact."
