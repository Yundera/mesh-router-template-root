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

# IPv6 is informational here: PUBLIC_IP stays the v4 address that the agent
# registers and that the nip.io / sslip.io labels are built from. (Yundera's
# template prefers v6 for PUBLIC_IP; not adopted — changing which family this
# box registers is a routing change, not an env rename.) Detected purely so the
# key exists for consumers that want it, and absence is normal.
DETECTED_V6=""
for service in "api6.ipify.org" "icanhazip.com"; do
    DETECTED_V6=$(curl -6s --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
    if [[ "$DETECTED_V6" == *:* ]]; then
        break
    fi
    DETECTED_V6=""
done

# Written on every run, not only on change: these keys were added after the
# first releases, so an unchanged box still needs them backfilled once.
# set_env_value is a no-op rewrite when the value already matches.
ensure_key() {
    local key="$1" value="$2"
    [ "$(get_env_value "$key")" = "$value" ] && return 0
    set_env_value "$key" "$value"
}

if [ -n "$DETECTED_V6" ]; then
    ensure_key "PUBLIC_IPV6" "$DETECTED_V6"
    ensure_key "PUBLIC_IPV6_DASH" "$(echo "$DETECTED_V6" | tr '.:' '-')"
fi

if [ -z "$DETECTED" ]; then
    echo "WARN: could not detect public IP (all services failed), keeping PUBLIC_IP=${PUBLIC_IP:-<empty>}"
    exit 0
fi

ensure_key "PUBLIC_IPV4" "$DETECTED"
ensure_key "PUBLIC_IPV4_DASH" "$(echo "$DETECTED" | tr '.:' '-')"

if [ "$DETECTED" = "${PUBLIC_IP:-}" ]; then
    echo "Public IP unchanged: $DETECTED"
    exit 0
fi

set_env_value "PUBLIC_IP" "$DETECTED"
set_env_value "PUBLIC_IP_DASH" "$(echo "$DETECTED" | tr '.:' '-')"
echo "Public IP changed: ${PUBLIC_IP:-<empty>} -> $DETECTED (.env updated, stack will be recreated)"
