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
#   curl -fsSL https://cdn.jsdelivr.net/gh/yundera/mesh-router-template-root@stable/install.sh \
#     | sudo -E bash -s -- --provider "https://nsl.sh/router/api,userid,signature" \
#       --domain alice.nsl.sh [--email you@example.com]
#
# Installs track the 'stable' channel by default. Add --channel main to follow
# the development branch instead; the choice is persisted (MESH_UPDATE_CHANNEL in
# .env) so the nightly self-check keeps updating from the same channel.
#
# Desktop installs (--windows, --macos) run Docker Desktop and are
# Linux-self-check-incompatible (cron, logrotate, apt). They stay on a direct
# one-shot path: compose up, no auto-update. On macOS the installer runs as the
# current user (no sudo) and the whole layout lives under $HOME/DATA, because the
# macOS root volume is read-only under SIP.

APP_DIR="/DATA/AppData/casaos/apps/mesh"   # CasaOS-visible surface: compose + .env only

# Defaults
PROVIDER=""
DOMAIN=""
EMAIL_ARG=""
PUBLIC_IP=""
DATA_ROOT="/DATA"
LOCAL_COMPOSE=""
WINDOWS_MODE=false
MACOS_MODE=false
CHANNEL="stable"   # update channel: stable | main (overridden by MESH_TEMPLATE_URL)
PUID="1000"
PGID="1000"

usage() {
  cat <<EOF
Mesh Router Installer

Usage:
  install.sh --provider <provider-string> --domain <domain> [options]

Required:
  --provider    Provider connection string (backend_url,userid,signature)
  --domain      Your domain (e.g. alice.nsl.sh)

Options:
  --email       Account email exposed to installed apps (default: admin@<domain>)
  --channel     Update channel: stable (default) or main (development branch).
                Persisted to .env so nightly updates follow the same channel.
  --public-ip   Server public IP (auto-detected by self-check if omitted)
  --data-root   Data storage path (default: /DATA, or \$HOME/DATA with --macos)
  --local       Path to a local docker-compose.yml (also pulls scripts/ beside
                it); skips the CDN and disables auto-update — for dev/testing
  --windows     Windows/WSL mode (DATA_ROOT=/c/DATA, user 0:0, no rshared,
                no self-check)
  --macos       macOS mode with Docker Desktop (DATA_ROOT=\$HOME/DATA, runs as the
                current user, no rshared, no self-check). Do not use sudo.
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
    --channel)   CHANNEL="$2"; shift 2 ;;
    --public-ip) PUBLIC_IP="$2"; shift 2 ;;
    --data-root) DATA_ROOT="$2"; shift 2 ;;
    --local)     LOCAL_COMPOSE="$2"; shift 2 ;;
    --windows)   WINDOWS_MODE=true; shift ;;
    --macos)     MACOS_MODE=true; shift ;;
    --help)      usage ;;
    *)           echo "Unknown option: $1"; usage ;;
  esac
done

if [[ "$WINDOWS_MODE" == true && "$MACOS_MODE" == true ]]; then
  echo "Error: --windows and --macos are mutually exclusive." >&2
  exit 1
fi

# Windows and macOS both sit on Docker Desktop: no Linux self-check (cron,
# logrotate, apt), no rshared bind propagation, and a complete .env written up
# front instead of one backfilled by the ensure-*.sh scripts.
DESKTOP_MODE=false
if [[ "$WINDOWS_MODE" == true || "$MACOS_MODE" == true ]]; then
  DESKTOP_MODE=true
fi

# Validate required params
if [[ -z "$PROVIDER" ]]; then
  echo "Error: --provider is required"
  usage
fi
if [[ -z "$DOMAIN" ]]; then
  echo "Error: --domain is required"
  usage
fi

# Validate argument *shape* before anything lands in .env.
# These values are written verbatim into .env (PROVIDER=..., DOMAIN=...), which
# is later sourced by bash. An unfilled placeholder like "<SIGNATURE>" — or any
# other shell metacharacter — turns into a redirect/expansion and aborts the
# whole stack with the cryptic "syntax error near unexpected token `newline`"
# instead of telling the user their provider string is wrong. Fail loudly here.
die_bad_arg() {
  # $1 = arg name, $2 = bad value, rest = explanation lines
  local name="$1" value="$2"; shift 2
  echo "Error: --${name} is invalid." >&2
  echo "       Got: ${value}" >&2
  local line
  for line in "$@"; do echo "       ${line}" >&2; done
  if [[ "$value" == *'<'* || "$value" == *'>'* ]]; then
    echo "       Hint: '<' or '>' means you pasted a literal placeholder (e.g." >&2
    echo "             \"<SIGNATURE>\") instead of the generated value. Make sure" >&2
    echo "             your key/signature was actually generated before installing." >&2
  fi
  exit 1
}

# PROVIDER must be exactly: backend_url,userid,signature
# Allowlist the characters real values use (URL + base58/base64/hex); anything
# else (angle brackets, spaces, quotes, $, backticks, ...) is rejected.
if [[ ! "$PROVIDER" =~ ^[A-Za-z0-9._:/,+=-]+$ ]]; then
  die_bad_arg provider "$PROVIDER" \
    "Expected: backend_url,userid,signature" \
    "It contains characters that aren't valid in a provider string."
fi
IFS=',' read -r -a _provider_parts <<<"$PROVIDER"
if [[ "${#_provider_parts[@]}" -ne 3 ]]; then
  die_bad_arg provider "$PROVIDER" \
    "Expected 3 comma-separated fields (backend_url,userid,signature)," \
    "got ${#_provider_parts[@]}."
fi
if [[ -z "${_provider_parts[0]}" || -z "${_provider_parts[1]}" || -z "${_provider_parts[2]}" ]]; then
  die_bad_arg provider "$PROVIDER" \
    "One of backend_url,userid,signature is empty."
fi
if [[ ! "${_provider_parts[0]}" =~ ^https?://[A-Za-z0-9.-]+ ]]; then
  die_bad_arg provider "$PROVIDER" \
    "The backend URL (first field) must start with http:// or https://." \
    "Got URL: ${_provider_parts[0]}"
fi
# Catch placeholder words pasted without angle brackets (SIGNATURE, USERID, ...).
for _f in "${_provider_parts[@]}"; do
  case "$(printf '%s' "$_f" | tr '[:upper:]' '[:lower:]')" in
    signature|userid|user-id|user_id|your-signature|your-userid|changeme|placeholder|todo|xxx)
      die_bad_arg provider "$PROVIDER" \
        "Still contains a placeholder field ('${_f}')." \
        "Generate your real userid/signature before installing." ;;
  esac
done

# DOMAIN must be a plain hostname (no scheme, no path, no metacharacters).
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ || "$DOMAIN" != *.* ]]; then
  die_bad_arg domain "$DOMAIN" \
    "Expected a hostname like alice.nsl.sh (letters, digits, dots, hyphens)."
fi

# EMAIL, if given, lands in .env too — keep it free of shell metacharacters.
if [[ -n "$EMAIL_ARG" && ! "$EMAIL_ARG" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]]; then
  die_bad_arg email "$EMAIL_ARG" \
    "Expected an address like you@example.com."
fi

# CHANNEL is persisted to .env and interpolated into a GitHub branch URL, so
# restrict it to a plain git ref name (letters, digits, ., _, /, -).
if [[ ! "$CHANNEL" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  die_bad_arg channel "$CHANNEL" \
    "Expected a branch name like stable or main."
fi

# Resolve the template tarball source. Precedence mirrors common.sh's
# mesh_template_url() (keep them in sync): an explicit MESH_TEMPLATE_URL full-URL
# override wins, otherwise build the URL from the chosen channel. This bootstrap
# can't source common.sh — the library isn't on disk yet.
TARBALL_URL="${MESH_TEMPLATE_URL:-https://github.com/yundera/mesh-router-template-root/archive/refs/heads/${CHANNEL}.tar.gz}"

# Privilege model differs by platform:
#   Linux/WSL: root is required (apt-installs Docker, writes /DATA, adds cron).
#   macOS:     root is forbidden. Docker Desktop runs as the current user and the
#              whole layout lives under $HOME. Under sudo, $HOME becomes /var/root
#              and the install would land somewhere the user never sees.
if [[ "$MACOS_MODE" == true ]]; then
  if [[ $EUID -eq 0 ]]; then
    echo "Error: --macos must not run as root." >&2
    echo "Re-run without sudo:" >&2
    echo "  curl -fsSL <url> | bash -s -- --macos --provider ... --domain ..." >&2
    exit 1
  fi
elif [[ $EUID -ne 0 ]]; then
  echo "Error: this installer must run as root." >&2
  echo "Try: curl -fsSL <url> | sudo -E bash -s -- --provider ... --domain ..." >&2
  exit 1
fi

echo "=== Mesh Router Installer ==="
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

# 1b. macOS mode (Docker Desktop)
# The macOS root volume is read-only under SIP, so /DATA can neither be created
# nor symlinked the way WSL does it. Keep the whole layout under $HOME and move
# APP_DIR with it. This is safe because the casaos service bind-mounts
# ${DATA_ROOT} to /DATA, so CasaOS still sees /DATA/AppData/casaos/apps/mesh from
# inside the container, which is the only path it actually cares about.
if [[ "$MACOS_MODE" == true ]]; then
  echo "[!!] macOS mode enabled (Docker Desktop)"
  if [[ "$DATA_ROOT" == "/DATA" ]]; then
    DATA_ROOT="$HOME/DATA"   # override the default only; respect an explicit --data-root
  fi
  APP_DIR="$DATA_ROOT/AppData/casaos/apps/mesh"
  PUID="$(id -u)"
  PGID="$(id -g)"
  mkdir -p "$DATA_ROOT"
  echo "[OK] DATA_ROOT: $DATA_ROOT"
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
# Desktop (Windows/WSL, macOS): no Linux self-check (cron/logrotate/apt). Write a
# complete .env and bring the stack up directly — there is no ensure-*.sh to
# backfill anything.
# ---------------------------------------------------------------------------
if [[ "$DESKTOP_MODE" == true ]]; then
  if [[ "$MACOS_MODE" == true ]]; then
    PLATFORM_LABEL="macOS"
  else
    PLATFORM_LABEL="Windows"
  fi

  echo "[..] Patching docker-compose for ${PLATFORM_LABEL} (remove rshared)..."
  # Docker Desktop does not support bind propagation. Note the "-i.bak" form: it
  # is the only in-place spelling accepted by BOTH GNU sed and the BSD sed that
  # macOS ships (a bare "-i" makes BSD sed read the next argument as a suffix).
  sed -i.bak '/bind:/,/propagation: rshared/d' "$APP_DIR/docker-compose.yml"
  rm -f "$APP_DIR/docker-compose.yml.bak"

  # Apple Silicon: casa-img is published for amd64 only, so Docker Desktop has to
  # run it under emulation. Pinning the platform explicitly keeps image selection
  # deterministic on first pull instead of relying on the fallback path. Compose
  # picks docker-compose.override.yml up automatically.
  # If casa-img gains an arm64 manifest, delete this block.
  if [[ "$MACOS_MODE" == true ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
      echo "[..] Apple Silicon detected: pinning casaos to linux/amd64 (emulated)..."
      cat > "$APP_DIR/docker-compose.override.yml" <<'YAML'
services:
  casaos:
    platform: linux/amd64
YAML
    else
      rm -f "$APP_DIR/docker-compose.override.yml"
    fi
  fi

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
    # LC_ALL=C on tr as well as head: BSD tr aborts with "Illegal byte sequence"
    # when it meets non-UTF-8 bytes from /dev/urandom under a UTF-8 locale.
    DEFAULT_PASSWORD=$(LC_ALL=C head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)
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
MESH_UPDATE_CHANNEL=${CHANNEL}
EOF
  chmod 600 "$APP_DIR/.env"
  chown "${PUID}:${PGID}" "$APP_DIR/.env" 2>/dev/null || true
  echo "[OK] .env written"

  echo "[..] Restarting stack (clean down then up)..."
  cd "$APP_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose up -d

  echo ""
  echo "=== Installation complete (${PLATFORM_LABEL}) ==="
  echo "  Domain:  https://${DOMAIN}"
  echo "  Install: ${APP_DIR}"
  echo ""
  if [[ "$MACOS_MODE" == true ]]; then
    echo "First start pulls several images and can take a few minutes."
    echo "Your server is reachable only while this Mac is awake, online, and Docker"
    echo "Desktop is running. For an always on server, use Linux or a VPS."
    echo ""
  fi
  echo "Open https://${DOMAIN} to complete CasaOS first-run setup. Re-run to update."
  exit 0
fi

# ---------------------------------------------------------------------------
# Linux: write a MINIMAL .env (only what self-check can't derive) and hand off.
# ensure-env-valid backfills DEFAULT_PASSWORD, service host/port, PUID/PGID, and
# EMAIL; ensure-public-ip detects PUBLIC_IP; ensure-template-sync owns compose.
# ---------------------------------------------------------------------------
echo "[..] Writing .env (preserving existing keys on re-run)..."
ENV_FILE="$APP_DIR/.env"
env_set() {
  # Upsert KEY=VALUE in $ENV_FILE without disturbing other keys (atomic). This
  # is what keeps DEFAULT_PASSWORD (and anything ensure-env-valid backfilled)
  # intact when the installer is re-run to update — regenerating the platform
  # secret would invalidate every app's DB password and admin token.
  local key="$1" value="$2" tmp
  tmp=$(mktemp "$APP_DIR/.env.XXXXXX")
  if [[ -f "$ENV_FILE" ]]; then
    grep -v -E "^${key}=" "$ENV_FILE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  # Own the .env by PUID:PGID so CasaOS (uid 1000) can read it and group the
  # stack in its dashboard instead of showing it as individual "External Apps".
  chown "${PUID}:${PGID}" "$tmp" 2>/dev/null || true
  mv "$tmp" "$ENV_FILE"
}
env_set PROVIDER "$PROVIDER"
env_set DOMAIN "$DOMAIN"
env_set DATA_ROOT "$DATA_ROOT"
env_set MESH_AUTO_UPDATE "$MESH_AUTO_UPDATE"
env_set MESH_UPDATE_CHANNEL "$CHANNEL"
[[ -n "$EMAIL_ARG" ]] && env_set EMAIL "$EMAIL_ARG"
[[ -n "$PUBLIC_IP" ]] && env_set PUBLIC_IP "$PUBLIC_IP"
echo "[OK] .env written"

# Force a clean down before the self-check brings the stack back up. install.sh
# is user-triggered (manual install/update), so a brief full outage is fine, and
# a clean teardown is the only reliable way to apply an identity change (new
# domain/provider): an in-place `up -d` — what the nightly self-check does — can
# leave stale WireGuard/network state and a stale caddy config behind, which
# surfaces as a 502 on the tunnel path. ensure-stack-up brings it back up next.
#
# Guarded: a fresh install has no Docker yet (ensure-docker-installed runs in the
# self-check below) and no stack to stop, so this is skipped on first install.
if command -v docker >/dev/null 2>&1 && [[ -f "$APP_DIR/docker-compose.yml" ]]; then
  echo "[..] Stopping existing stack for a clean restart..."
  (cd "$APP_DIR" && docker compose down --remove-orphans) || true
  echo "[OK] Stack stopped"
fi

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
