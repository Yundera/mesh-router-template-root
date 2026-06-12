#!/bin/bash
# Check-only: verify the backend has live routes registered for this user.
# No repair — agent/tunnel re-register on their own refresh loops, and the
# stack was just (re)started by ensure-stack-up.sh. A failure here after a
# fresh start means registration is genuinely broken (bad PROVIDER signature,
# backend down, ...) and needs a human.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

if [ -z "${PROVIDER:-}" ]; then
    echo "ERROR: PROVIDER not set"
    exit 1
fi

# PROVIDER format: backend_url,userid,signature
IFS=',' read -r BACKEND_URL USER_ID _SIG <<< "$PROVIDER"
if [ -z "$BACKEND_URL" ] || [ -z "$USER_ID" ]; then
    echo "ERROR: PROVIDER is malformed (expected backend_url,userid,signature): $PROVIDER"
    exit 1
fi
BACKEND_URL="${BACKEND_URL%/}"

# Routes were registered seconds ago at best — give the agent/tunnel a moment
# after a stack restart before declaring failure.
RESPONSE=""
for attempt in 1 2 3; do
    RESPONSE=$(curl -fsS --max-time 15 "$BACKEND_URL/routes/$USER_ID" 2>&1) && break
    if [ "$attempt" -lt 3 ]; then
        sleep 20
    else
        echo "ERROR: backend route query failed: $RESPONSE"
        exit 1
    fi
done

# Every registered route carries a priority field; an empty/absent route set
# means nothing is registered.
if echo "$RESPONSE" | grep -q '"priority"'; then
    echo "Routes registered with backend for $USER_ID"
    exit 0
fi

echo "ERROR: no routes registered for $USER_ID - response: $RESPONSE"
exit 1
