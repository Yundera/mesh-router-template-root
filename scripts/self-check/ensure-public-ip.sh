#!/bin/bash
# Re-detect the public IP and update .env if it changed (e.g. after an ISP
# renumbering). ensure-stack-up.sh later recreates containers so the agent
# registers the new IP. Detection failure is a warning, not an error — the
# agent has its own runtime IP detection; this only keeps .env honest.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

DETECTED=""
for service in "ifconfig.me" "api.ipify.org" "icanhazip.com"; do
    DETECTED=$(curl -4s --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]')
    if [[ "$DETECTED" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    DETECTED=""
done

if [ -z "$DETECTED" ]; then
    echo "WARN: could not detect public IP (all services failed), keeping PUBLIC_IP=${PUBLIC_IP:-<empty>}"
    exit 0
fi

if [ "$DETECTED" = "${PUBLIC_IP:-}" ]; then
    echo "Public IP unchanged: $DETECTED"
    exit 0
fi

set_env_value "PUBLIC_IP" "$DETECTED"
set_env_value "PUBLIC_IP_DASH" "$(echo "$DETECTED" | tr '.:' '-')"
echo "Public IP changed: ${PUBLIC_IP:-<empty>} -> $DETECTED (.env updated, stack will be recreated)"
