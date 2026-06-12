#!/bin/bash
# Sync the account email from the backend into .env (EMAIL), so installed apps
# receive the user's real address via ${APP_EMAIL} instead of the synthetic
# admin@<domain> fallback that ensure-env-valid.sh backfills.
#
# Authenticated by the same Ed25519 signature already in PROVIDER (no new key
# material). Best-effort: on ANY failure (backend down, no email on file,
# malformed response) the existing EMAIL is left untouched — a transient blip
# must never clobber a good value or break the stack. Runs before the stack
# scripts so a changed email is picked up when containers are (re)created.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ -z "${PROVIDER:-}" ]; then
    echo "PROVIDER not set; skipping email sync"
    exit 0
fi

# PROVIDER format: backend_url,userid,signature. backend_url is a bare origin;
# the REST API lives under /router/api (the same prefix the agent appends).
IFS=',' read -r BACKEND_URL USER_ID SIG <<< "$PROVIDER"
if [ -z "$BACKEND_URL" ] || [ -z "$USER_ID" ] || [ -z "$SIG" ]; then
    echo "PROVIDER malformed; skipping email sync"
    exit 0
fi
BACKEND_URL="${BACKEND_URL%/}"
API_URL="$BACKEND_URL/router/api"

RESPONSE=$(curl -fsS --max-time 15 "$API_URL/user/email/$USER_ID/$SIG" 2>/dev/null) || {
    echo "Backend email lookup unavailable; keeping EMAIL=${EMAIL:-<unset>}"
    exit 0
}

# Extract "email":"..." without a jq dependency.
FETCHED=$(printf '%s' "$RESPONSE" | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -z "$FETCHED" ]; then
    echo "No email returned by backend; keeping EMAIL=${EMAIL:-<unset>}"
    exit 0
fi

# Sanity check: must look like an email before we trust it.
case "$FETCHED" in
    *@*.*) : ;;
    *) echo "Backend returned implausible email '$FETCHED'; keeping EMAIL=${EMAIL:-<unset>}"; exit 0 ;;
esac

CURRENT=$(get_env_value EMAIL)
if [ "$FETCHED" = "$CURRENT" ]; then
    echo "EMAIL already up to date ($FETCHED)"
    exit 0
fi

set_env_value EMAIL "$FETCHED"
echo "EMAIL updated: ${CURRENT:-<unset>} -> $FETCHED (.env updated, stack will be recreated)"
