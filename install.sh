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
# Installs track the 'stable' branch by default. Add --channel main to follow the
# development branch, or --update-url for an arbitrary tarball. Either way the
# resolved FULL URL is persisted as UPDATE_URL in .env, so the nightly self-check
# keeps updating from the same source. UPDATE_URL is the same key name and shape
# Yundera/template-root uses — see doc/alignment-with-template-root.md.
#
# Windows/WSL (--windows) installs are Linux-self-check-incompatible (cron,
# logrotate, apt) and stay on a direct one-shot path: compose up, no auto-update.

APP_DIR="/DATA/AppData/mesh"   # everything: compose, .env, template/, scripts/, data/

# Defaults
PROVIDER_STR=""
DOMAIN=""
EMAIL_ARG=""
PUBLIC_IP=""
DATA_ROOT="/DATA"
LOCAL_COMPOSE=""
WINDOWS_MODE=false
CHANNEL="stable"   # convenience: resolved to a branch URL unless --update-url is given
UPDATE_URL_ARG=""  # explicit full tarball URL; wins over --channel
PUID="1000"
PGID="1000"
# Onboarding. The box seeds its owner account DISABLED, so an install that ends
# without a claim leaves a login nobody can use — see the claim step at the end.
CLAIM_USER=""
CLAIM_PASSWORD=""
CLAIM_GENERATE=false
ASSUME_YES=false

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
  --channel     Update branch: stable (default) or main (development branch).
                Resolved to a full URL and persisted as UPDATE_URL in .env.
  --update-url  Full template tarball URL (.tar.gz), for forks/tags/mirrors.
                Overrides --channel. Persisted as UPDATE_URL.
  --public-ip   Server public IP (auto-detected by self-check if omitted)
  --data-root   Data storage path (default: /DATA)
  --local       Path to a local docker-compose.yml (also pulls scripts/ beside
                it); skips the CDN and disables auto-update — for dev/testing
  --windows     Windows/WSL mode (DATA_ROOT=/c/DATA, user 0:0, no rshared,
                no self-check)

Onboarding (the local login for this box):
  --claim-user  Username for the owner account (lowercase; a-z 0-9 _ -)
  --claim-password
                Password for it. Omit both and you are prompted, if a terminal
                is available; a re-run that finds the box already claimed asks
                nothing.
  --generate    Mint a random password and print it once instead of asking.
  --yes, -y     Never prompt. With no credentials given, the box is left
                UNCLAIMED and you claim it later over SSH with
                scripts/tools/authelia-user-manager.sh claim <username>.
  --help        Show this help
EOF
  exit 1
}

# Parse arguments
#
# need_value guards every option that takes one. Without it a trailing
# `--domain` with no argument ran `shift 2` past the end of "$@" and surfaced as
# an unbound-variable trace from somewhere further down, instead of saying which
# flag was incomplete.
need_value() {
  [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; usage; }
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)  need_value "$@"; PROVIDER_STR="$2"; shift 2 ;;
    --domain)    need_value "$@"; DOMAIN="$2"; shift 2 ;;
    --email)     need_value "$@"; EMAIL_ARG="$2"; shift 2 ;;
    --channel)    need_value "$@"; CHANNEL="$2"; shift 2 ;;
    --update-url) need_value "$@"; UPDATE_URL_ARG="$2"; shift 2 ;;
    --public-ip) need_value "$@"; PUBLIC_IP="$2"; shift 2 ;;
    --data-root) need_value "$@"; DATA_ROOT="$2"; shift 2 ;;
    --local)     need_value "$@"; LOCAL_COMPOSE="$2"; shift 2 ;;
    --windows)   WINDOWS_MODE=true; shift ;;
    --claim-user)     need_value "$@"; CLAIM_USER="$2"; shift 2 ;;
    --claim-password) need_value "$@"; CLAIM_PASSWORD="$2"; shift 2 ;;
    --generate)  CLAIM_GENERATE=true; shift ;;
    --yes|-y)    ASSUME_YES=true; shift ;;
    --help)      usage ;;
    *)           echo "Unknown option: $1"; usage ;;
  esac
done

# Validate required params
if [[ -z "$PROVIDER_STR" ]]; then
  echo "Error: --provider is required"
  usage
fi
if [[ -z "$DOMAIN" ]]; then
  echo "Error: --domain is required"
  usage
fi

# Validate argument *shape* before anything lands in .env.
# These values are written verbatim into .env (PROVIDER_STR=..., DOMAIN=...), which
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

# PROVIDER_STR must be exactly: backend_url,userid,signature
# Allowlist the characters real values use (URL + base58/base64/hex); anything
# else (angle brackets, spaces, quotes, $, backticks, ...) is rejected.
if [[ ! "$PROVIDER_STR" =~ ^[A-Za-z0-9._:/,+=-]+$ ]]; then
  die_bad_arg provider "$PROVIDER_STR" \
    "Expected: backend_url,userid,signature" \
    "It contains characters that aren't valid in a provider string."
fi
IFS=',' read -r -a _provider_parts <<<"$PROVIDER_STR"
if [[ "${#_provider_parts[@]}" -ne 3 ]]; then
  die_bad_arg provider "$PROVIDER_STR" \
    "Expected 3 comma-separated fields (backend_url,userid,signature)," \
    "got ${#_provider_parts[@]}."
fi
if [[ -z "${_provider_parts[0]}" || -z "${_provider_parts[1]}" || -z "${_provider_parts[2]}" ]]; then
  die_bad_arg provider "$PROVIDER_STR" \
    "One of backend_url,userid,signature is empty."
fi
if [[ ! "${_provider_parts[0]}" =~ ^https?://[A-Za-z0-9.-]+ ]]; then
  die_bad_arg provider "$PROVIDER_STR" \
    "The backend URL (first field) must start with http:// or https://." \
    "Got URL: ${_provider_parts[0]}"
fi
# Catch placeholder words pasted without angle brackets (SIGNATURE, USERID, ...).
for _f in "${_provider_parts[@]}"; do
  case "$(printf '%s' "$_f" | tr '[:upper:]' '[:lower:]')" in
    signature|userid|user-id|user_id|your-signature|your-userid|changeme|placeholder|todo|xxx)
      die_bad_arg provider "$PROVIDER_STR" \
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
# mesh_template_url() — keep the two in sync; this bootstrap cannot source the
# library because it is not on disk yet.
#   --update-url > UPDATE_URL from the env > MESH_TEMPLATE_URL (deprecated) > --channel
# The resolved value is what gets written to .env as UPDATE_URL further down, so
# the box keeps updating from whatever this install chose.
TARBALL_URL="$UPDATE_URL_ARG"
[[ -z "$TARBALL_URL" ]] && TARBALL_URL="${UPDATE_URL:-}"
[[ -z "$TARBALL_URL" ]] && TARBALL_URL="${MESH_TEMPLATE_URL:-}"
[[ -z "$TARBALL_URL" ]] && TARBALL_URL="https://github.com/yundera/mesh-router-template-root/archive/refs/heads/${CHANNEL}.tar.gz"

if [[ "$TARBALL_URL" == *.zip ]]; then
  die_bad_arg update-url "$TARBALL_URL" \
    "This template is distributed as .tar.gz and extracts with tar. Use the .tar.gz form."
fi

if [[ $EUID -ne 0 ]]; then
  echo "Error: this installer must run as root." >&2
  echo "Try: curl -fsSL <url> | sudo -E bash -s -- --provider ... --domain ..." >&2
  exit 1
fi

echo "=== Mesh Router Installer ==="
echo ""

# 1. Windows/WSL mode
# On Windows/WSL, host paths use /c/DATA but containers see /DATA. We keep APP_DIR
# at /DATA/... so docker compose labels match, and symlink /DATA -> /c/DATA so files
# land on the Windows filesystem.
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
# APP_DIR now holds everything for this stack; the rest of the tree
# (data, template, scripts, log) lives under ${DATA_ROOT}/AppData/mesh.
echo "[..] Creating directories..."
mkdir -p "$APP_DIR" "$DATA_ROOT" \
  "$MESH_ROOT/data/certs" \
  "$MESH_ROOT/data/caddy/data" \
  "$MESH_ROOT/data/caddy/config" \
  "$MESH_ROOT/log" \
  "$SCRIPTS_DIR" "$TEMPLATE_DIR"
echo "[OK] Layout under $MESH_ROOT"

# Read a key out of the existing .env, if there is one. This is the middle rung
# of the precedence ladder every input follows:
#
#     explicit flag  >  value already in .env  >  interactive prompt  >  default
#
# The practical effect is that a RE-RUN TO UPDATE asks nothing: every value is
# already on disk, so each prompt is skipped for the same reason a flag would
# skip it. There is no separate "am I updating?" branch anywhere in this script.
env_get() {
  local key="$1"
  [[ -f "$APP_DIR/.env" ]] || { echo ""; return 0; }
  grep -E "^${key}=" "$APP_DIR/.env" | head -n1 | cut -d= -f2- || true
}

# Prompt on the CONTROLLING TERMINAL, not stdin.
#
# The documented install path is `curl -fsSL ... | bash -s -- ...`, where stdin
# is the SCRIPT ITSELF — so `read` without a redirect would eat the script's own
# remaining bytes, and `[ -t 0 ]` is false even when the user is sitting at a
# terminal. Reading from /dev/tty is what makes a prompt work in a pipe at all.
# Same idiom as uninstall.sh's confirmation.
#
# Returns 1 when there is no terminal, so callers can fall back rather than hang.
have_tty() { [[ "$ASSUME_YES" != true && -r /dev/tty ]]; }

prompt_line() {
  local prompt="$1" __var="$2" reply=""
  have_tty || return 1
  printf '%s' "$prompt" > /dev/tty
  read -r reply < /dev/tty || return 1
  printf -v "$__var" '%s' "$reply"
}

prompt_secret() {
  local prompt="$1" __var="$2" reply=""
  have_tty || return 1
  printf '%s' "$prompt" > /dev/tty
  # No echo, and restore the terminal even if the read is interrupted.
  stty -echo < /dev/tty 2>/dev/null || true
  read -r reply < /dev/tty || { stty echo < /dev/tty 2>/dev/null || true; return 1; }
  stty echo < /dev/tty 2>/dev/null || true
  printf '\n' > /dev/tty
  printf -v "$__var" '%s' "$reply"
}

# Auto-update toggle (nightly self-check re-syncs compose + scripts from main).
# Preserve a user's opt-out across reruns; default off for --local dev installs
# so the sync doesn't clobber local files with the published template.
MESH_AUTO_UPDATE="$(env_get MESH_AUTO_UPDATE)"
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
  if [[ -z "$src" || ! -f "$src/docker-compose.yml" || ! -f "$src/scripts/self-check.sh" || ! -f "$src/Caddyfile" ]]; then
    echo "Error: downloaded template is incomplete (missing compose, Caddyfile or self-check.sh)" >&2
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
# The base Caddyfile is deliberately NOT placed here on the Linux path: it is
# template-owned, and the self-check below propagates it
# (ensure-template-sync.sh) or restores it from template/ when the sync was
# skipped or failed (ensure-stack-up.sh). All this needs to guarantee is that
# template/ contains a copy. --windows is the exception — it runs no self-check
# and brings the stack up itself, so it places the file explicitly.
if [[ -n "$LOCAL_COMPOSE" ]]; then
  src_dir=$(cd "$(dirname "$LOCAL_COMPOSE")" && pwd)
  if [[ -d "$src_dir/scripts" ]]; then
    echo "[..] Copying template from $src_dir..."
    cp "$LOCAL_COMPOSE" "$APP_DIR/docker-compose.yml"
    cp -a "$src_dir/scripts/." "$SCRIPTS_DIR/"
    # Mirror compose + Caddyfile + scripts into template/ for layout consistency
    # (local mode has auto-update off, so template/ is reference-only and never
    # re-synced).
    mkdir -p "$TEMPLATE_DIR/scripts"
    cp "$LOCAL_COMPOSE" "$TEMPLATE_DIR/docker-compose.yml"
    cp -a "$src_dir/scripts/." "$TEMPLATE_DIR/scripts/"
    cp "$src_dir/Caddyfile" "$TEMPLATE_DIR/Caddyfile"
    # stacks/ and auth/ are read from template/ at runtime (deploy-stack.sh,
    # ensure-authelia.sh) rather than propagated to a live location, so a --local
    # install has to mirror them here too or Maison and Authelia have no source.
    for extra in stacks auth dex-theme; do
      if [[ -d "$src_dir/$extra" ]]; then
        rm -rf "${TEMPLATE_DIR:?}/$extra"
        cp -a "$src_dir/$extra" "$TEMPLATE_DIR/$extra"
      fi
    done
    echo "[OK] Template + Caddyfile + scripts + stacks + dex-theme copied from $src_dir"
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
  # DEFAULT_PASSWORD is the pre-rename name. This path is the ONLY thing that
  # migrates it on Windows: there is no self-check and no template sync here, so
  # scripts/migrations/ never runs. Missing the fallback would regenerate the
  # secret on the first re-run after the rename and break every installed app.
  DEFAULT_PWD=""
  if [[ -f "$APP_DIR/.env" ]]; then
    DEFAULT_PWD=$(grep -E '^DEFAULT_PWD=' "$APP_DIR/.env" | head -n1 | cut -d= -f2- || true)
    if [[ -z "$DEFAULT_PWD" ]]; then
      DEFAULT_PWD=$(grep -E '^DEFAULT_PASSWORD=' "$APP_DIR/.env" | head -n1 | cut -d= -f2- || true)
    fi
  fi
  if [[ -z "$DEFAULT_PWD" ]]; then
    DEFAULT_PWD=$(LC_ALL=C head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)
  fi

  cat > "$APP_DIR/.env" <<EOF
PROVIDER_STR=${PROVIDER_STR}
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_IP_DASH=${PUBLIC_IP_DASH}
DATA_ROOT=${DATA_ROOT}
DEFAULT_PWD=${DEFAULT_PWD}
EMAIL=${EMAIL}
DEFAULT_SERVICE_HOST=maison
DEFAULT_SERVICE_PORT=80
PUID=${PUID}
PGID=${PGID}
MESH_AUTO_UPDATE=false
UPDATE_URL=${TARBALL_URL}
EOF
  chmod 600 "$APP_DIR/.env"
  chown "${PUID}:${PGID}" "$APP_DIR/.env" 2>/dev/null || true
  echo "[OK] .env written"

  # No self-check on this path, so nothing else will place the base Caddyfile
  # that the compose file bind-mounts into mesh-router-caddy. Docker would
  # materialise the missing bind source as a directory and Caddy would not
  # start. On Linux this is handled by ensure-template-sync/ensure-stack-up.
  if [[ -d "$MESH_ROOT/Caddyfile" ]]; then
    rm -rf "$MESH_ROOT/Caddyfile"
  fi
  cp "$TEMPLATE_DIR/Caddyfile" "$MESH_ROOT/Caddyfile"

  echo "[..] Restarting stack (clean down then up)..."
  cd "$APP_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose up -d

  echo ""
  echo "=== Installation complete (Windows) ==="
  echo "  Domain:  https://${DOMAIN}"
  echo "  Install: ${APP_DIR}"
  echo ""
  echo "Open https://${DOMAIN} to sign in to the Maison dashboard. Re-run to update."
  exit 0
fi

# ---------------------------------------------------------------------------
# Linux: write a MINIMAL .env (only what self-check can't derive) and hand off.
# ensure-env-valid backfills DEFAULT_PWD, service host/port, PUID/PGID, and
# EMAIL; ensure-public-ip detects PUBLIC_IP; ensure-template-sync owns compose.
# ---------------------------------------------------------------------------
# Adopt a pre-move .env from the CasaOS-era path BEFORE writing anything.
#
# Until scripts/migrations/2026-08-02-04-move-app-dir.sh has run, the live .env
# is at /DATA/AppData/casaos/apps/mesh/.env while APP_DIR here is already the new
# /DATA/AppData/mesh. Writing straight to APP_DIR creates a SECOND .env, and that
# migration — which runs later in this same invocation, from inside the self-check —
# resolves the clash by keeping the old file. Everything env_set writes below
# (UPDATE_URL, the renamed keys) and everything the migrations then apply to it
# (the casaos:8080 -> maison:80 repoint) is silently discarded, and the box comes
# up on stale config with a 502 on the root domain.
#
# Moving the old file into place first is what makes the "preserving existing keys
# on re-run" promise true ACROSS the layout change: the box's real state
# (DEFAULT_PWD, AUTHELIA_DEX_SECRET, DEX_SESSION_KEY, ...) is the base, and this
# run's values are overlaid on it. Mirrors the APP_DIR fallback in
# scripts/library/common.sh — keep the two in sync. Moving the DIRECTORY (and
# leaving the symlink behind) still belongs to the migration.
LEGACY_APP_DIR="/DATA/AppData/casaos/apps/mesh"
if [[ ! -L "$LEGACY_APP_DIR" && -f "$LEGACY_APP_DIR/.env" && ! -f "$APP_DIR/.env" ]]; then
  mv "$LEGACY_APP_DIR/.env" "$APP_DIR/.env"
  echo "[OK] Adopted existing .env from $LEGACY_APP_DIR"
fi

echo "[..] Writing .env (preserving existing keys on re-run)..."
ENV_FILE="$APP_DIR/.env"
env_set() {
  # Upsert KEY=VALUE in $ENV_FILE without disturbing other keys (atomic). This
  # is what keeps DEFAULT_PWD (and anything ensure-env-valid backfilled)
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
env_set PROVIDER_STR "$PROVIDER_STR"
env_set DOMAIN "$DOMAIN"
env_set DATA_ROOT "$DATA_ROOT"
env_set MESH_AUTO_UPDATE "$MESH_AUTO_UPDATE"
env_set UPDATE_URL "$TARBALL_URL"
# Mirror into the DEPRECATED key, same reasoning as the -02- migration: pre-rename
# code reads MESH_TEMPLATE_URL and cannot see UPDATE_URL, so a box rolled back to
# an older tree would otherwise lose its source and silently fall back to stable.
# Both carry the same URL for one release; MESH_TEMPLATE_URL goes with the other
# transition shims. MESH_UPDATE_CHANNEL is dropped now — old code prefers
# MESH_TEMPLATE_URL over it, so it can no longer have any effect.
env_set MESH_TEMPLATE_URL "$TARBALL_URL"
sed -i -E '/^MESH_UPDATE_CHANNEL=/d' "$ENV_FILE"
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

# ---------------------------------------------------------------------------
# Claim the owner account.
#
# AFTER the self-check, not before: ensure-authelia.sh runs inside it and is what
# creates users_database.yml in the first place, seeding the owner DISABLED. The
# claim names that account, sets its password and enables it.
#
# This is deliberately NOT the same secret as DEFAULT_PWD. That one is an
# app-seed secret injected into every app this box installs
# (default_pwd / PCS_DEFAULT_PASSWORD / APP_DEFAULT_PASSWORD), so using it as the
# human login would put the owner's own credential in every app's environment.
#
# Skipped silently when the box is already claimed, which is what makes a re-run
# to update ask nothing.
# ---------------------------------------------------------------------------
USER_MGR="$SCRIPTS_DIR/tools/authelia-user-manager.sh"
CLAIM_RESULT=""
CLAIMED_NOW=false

if [[ "$SELF_CHECK_RC" -eq 0 && -x "$USER_MGR" ]]; then
  if "$USER_MGR" list 2>/dev/null | grep -q '"disabled":false'; then
    : # already claimed — nothing to do, and nothing to say
  else
    # Username: flag > prompt > default 'admin'
    if [[ -z "$CLAIM_USER" ]]; then
      if ! prompt_line "Choose a username for this server's login [admin]: " CLAIM_USER; then
        CLAIM_USER=""
      fi
    fi
    [[ -n "$CLAIM_USER" ]] || CLAIM_USER="admin"

    # Password: flag > --generate > prompt (twice) > leave unclaimed
    if [[ -n "$CLAIM_PASSWORD" ]]; then
      :
    elif [[ "$CLAIM_GENERATE" == true ]]; then
      :
    else
      _p1=""; _p2=""
      if prompt_secret "Choose a password (min 8 chars, blank to skip): " _p1 && [[ -n "$_p1" ]]; then
        if prompt_secret "Repeat it: " _p2 && [[ "$_p1" == "$_p2" ]]; then
          CLAIM_PASSWORD="$_p1"
        else
          echo "[!!] Passwords did not match — leaving this server unclaimed."
        fi
      fi
      unset _p1 _p2
    fi

    if [[ "$CLAIM_GENERATE" == true ]]; then
      CLAIM_RESULT="$("$USER_MGR" claim --generate "$CLAIM_USER" 2>&1)" && CLAIMED_NOW=true || true
    elif [[ -n "$CLAIM_PASSWORD" ]]; then
      # Password over stdin so it never lands in this script's argv or the host
      # process list — see the note in authelia-user-manager.sh.
      CLAIM_RESULT="$(printf '%s' "$CLAIM_PASSWORD" | "$USER_MGR" claim "$CLAIM_USER" 2>&1)" && CLAIMED_NOW=true || true
    fi
    unset CLAIM_PASSWORD

    if [[ "$CLAIMED_NOW" != true && -n "$CLAIM_RESULT" ]]; then
      echo "[!!] Could not claim the account: $CLAIM_RESULT"
    fi
  fi
fi

echo ""
if [[ "$SELF_CHECK_RC" -eq 0 ]]; then
  echo "=== Installation complete ==="
  echo "  Domain:  https://${DOMAIN}"
  echo "  Install: ${APP_DIR}"
  echo ""
  if [[ "$CLAIMED_NOW" == true ]]; then
    echo "Open https://${DOMAIN} in your browser and sign in as '${CLAIM_USER}'."
    if [[ "$CLAIM_GENERATE" == true ]]; then
      # The ONLY time this password is ever shown. It is not stored anywhere in
      # plaintext — only its argon2 digest reaches users_database.yml.
      _gen="$(printf '%s' "$CLAIM_RESULT" | sed -n 's/.*"password":"\([^"]*\)".*/\1/p')"
      echo ""
      echo "  Password (shown once, not stored): ${_gen}"
      unset _gen
    fi
  elif "$USER_MGR" list 2>/dev/null | grep -q '"disabled":false'; then
    echo "Open https://${DOMAIN} in your browser to sign in."
  else
    echo "This server is NOT CLAIMED YET: no local account can log in, and the"
    echo "login page will show no sign-in button. Claim it over SSH with:"
    echo ""
    echo "  sudo ${USER_MGR} claim <username>"
    echo "      (reads the password from stdin, or pass --generate)"
  fi
  echo ""
  echo "To update, re-run this command (or wait for the nightly self-check)."
else
  echo "=== Installation finished with self-check failures (exit ${SELF_CHECK_RC}) ==="
  echo "  Log:    ${MESH_ROOT}/log/mesh.log"
  echo "  Re-run: sudo bash ${SCRIPTS_DIR}/self-check.sh --display"
fi

exit "$SELF_CHECK_RC"
