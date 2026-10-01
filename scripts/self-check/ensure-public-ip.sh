#!/bin/bash
# Detect this box's public IP and keep .env in step with it (e.g. after an ISP
# renumbering). ensure-stack-up.sh later recreates containers so the agent
# registers the new IP. Never fatal — the agent has its own runtime detection;
# this only keeps .env honest.
#
# Sets PUBLIC_IP / PUBLIC_IP_DASH — the canonical address: what the agent
# registers and what the nip.io / sslip.io labels are built from — plus
# PUBLIC_IPV4(_DASH) and PUBLIC_IPV6(_DASH) for consumers that want a family.
#
# TWO WAYS TO ANSWER "what is my public IP", for two kinds of box. PUBLIC_IP_MODE
# in .env picks one:
#
#   egress (default)  Ask the outside world which address this box connects
#                     from. Right for a machine behind NAT — a home server whose
#                     router forwards 80/443: the address that matters is the
#                     router's, and it is on no local interface.
#
#   interface         Take the globally-routable address bound to a local
#                     interface, and nothing else. Right for a cloud VM. There
#                     the egress address can be an upstream SNAT gateway that is
#                     not this machine at all (a VM with native IPv6 and NAT'd
#                     IPv4): claiming it registers a route somebody else
#                     answers. With no public IPv4 of its own such a box falls
#                     back to its IPv6, then to 127.0.0.1.
#
# Neither is a refinement of the other: on the IPv6-plus-SNAT VM egress mode
# picks the wrong address, and on the home server interface mode finds none.
# So the mode is stated, not guessed.
#
# REACHABILITY PROBE. Both modes ask mesh-router-backend (the URL in
# PROVIDER_STR, not a hardcoded host) to ping the candidates from the public
# side: POST <backend>/router/api/probe. What is done with the answer differs:
#
#   interface   An address that does not answer is DROPPED. The address is this
#               machine's own, so silence means it is bound but not routed —
#               registering it breaks routing with nothing to show why.
#   egress      A WARNING only. The address is a NAT device's; whether it
#               answers ping says little about whether 443 is forwarded, and a
#               router that drops ICMP is ordinary. Dropping the address would
#               break boxes that work.
#
# The probe is never a hard dependency: any failure to get a clear verdict
# (endpoint missing, timeout, a backend whose own ping is broken) is treated as
# "unverified" and changes nothing. That includes a backend with no route for a
# whole address family: every probe sends a CONTROL address of the same family
# along (a public resolver that answers ping), and when the control comes back
# unreachable too the verdict for that family is thrown away. Not hypothetical —
# on 2026-10-01 the nsl.sh backend had no IPv6 connectivity and reported every
# IPv6 address, Cloudflare's resolver included, as unreachable.
#
# The `interface` mode and the probe are ported from Yundera/template-root. Not
# ported: its netplan step that brings up a secondary IPv6 interface, which is
# specific to those VMs and has to run before this script.

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

MODE="${PUBLIC_IP_MODE:-egress}"
case "$MODE" in
    egress|interface) ;;
    *) echo "WARN: unknown PUBLIC_IP_MODE='$MODE', using 'egress'"; MODE="egress" ;;
esac

PROBE_TIMEOUT_SECONDS=8
# Addresses that answer ICMP from anywhere with working connectivity of that
# family (Cloudflare's resolvers). Only ever pinged BY THE BACKEND, as the
# yardstick for its own vantage point.
PROBE_CONTROL_V4="1.1.1.1"
PROBE_CONTROL_V6="2606:4700:4700::1111"

to_dash() { printf '%s' "$1" | tr '.:' '-'; }

# Written on every run, not only on change: some of these keys were added after
# the first releases, so an unchanged box still needs them backfilled once.
ensure_key() {
    local key="$1" value="$2"
    [ "$(get_env_value "$key")" = "$value" ] && return 0
    set_env_value "$key" "$value"
}

# --- egress detection --------------------------------------------------------
egress_ipv4() {
    local service ip
    for service in "ifconfig.me" "api.ipify.org" "icanhazip.com"; do
        ip=$(curl -4s --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 0
}

egress_ipv6() {
    local service ip
    for service in "api6.ipify.org" "icanhazip.com"; do
        ip=$(curl -6s --max-time 5 "$service" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" == *:* ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 0
}

# --- local-interface detection -----------------------------------------------
# First globally-routable IPv4 on any local interface. Filters loopback,
# RFC1918 private, link-local and RFC6598/CGNAT (100.64/10).
local_ipv4() {
    local ip
    command -v ip >/dev/null 2>&1 || return 0
    while read -r ip; do
        case "$ip" in
            127.*|169.254.*) continue ;;
            10.*) continue ;;
            172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) continue ;;
            192.168.*) continue ;;
            100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) continue ;;
        esac
        printf '%s' "$ip"
        return 0
    done < <(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
    return 0
}

# First globally-routable IPv6 on any local interface. `scope global` already
# excludes loopback and link-local; the filter also drops ULA (fc00::/7), which
# kernels sometimes still tag as global.
local_ipv6() {
    local ip
    command -v ip >/dev/null 2>&1 || return 0
    while read -r ip; do
        case "${ip,,}" in
            ::1|fe80:*) continue ;;
            fc[0-9a-f][0-9a-f]:*|fd[0-9a-f][0-9a-f]:*) continue ;;
        esac
        printf '%s' "$ip"
        return 0
    done < <(ip -6 addr show 2>/dev/null | awk '/inet6.*scope global/ {print $2}' | cut -d/ -f1)
    return 0
}

# --- reachability probe ------------------------------------------------------
# Prints the candidates the backend reports as NOT reachable, one per line.
# Prints nothing on any doubt, which the callers read as "unverified".
#
# Parsed with sed, not jq or python: this template adds no host dependency for a
# check that is advisory by design. The response is one JSON line,
#   {"results":[{"ip":"1.2.3.4","family":"ipv4","reachable":true}, ...]}
# split here into one object per line.
probe_unreachable() {
    local backend payload="" ip response chunk bad="" has_v4=0 has_v6=0
    IFS=',' read -r backend _ <<< "${PROVIDER_STR:-}"
    backend="${backend%/}"
    [ -n "$backend" ] || return 0

    for ip in "$@"; do
        [ -n "$ip" ] || continue
        payload+="${payload:+,}\"$ip\""
        case "$ip" in *:*) has_v6=1 ;; *) has_v4=1 ;; esac
    done
    [ -n "$payload" ] || return 0
    # One control per family present. The endpoint takes four candidates at most,
    # which is exactly one address and one control for each family.
    [ "$has_v4" = 1 ] && payload+=",\"$PROBE_CONTROL_V4\""
    [ "$has_v6" = 1 ] && payload+=",\"$PROBE_CONTROL_V6\""

    response=$(curl -sS --max-time "$PROBE_TIMEOUT_SECONDS" \
        -H "Content-Type: application/json" \
        -d "{\"candidates\":[$payload]}" \
        "$backend/router/api/probe" 2>/dev/null) || return 0
    case "$response" in *'"results"'*) ;; *) return 0 ;; esac

    # A backend whose own ping is broken answers "unreachable" for everything.
    # Acting on that would strip every address, so it counts as no verdict.
    case "$response" in
        *"ping binary not available"*|*"probe unavailable"*) return 0 ;;
    esac

    # `|| [ -n "$chunk" ]`: the last object has no trailing newline, and `read`
    # alone would drop it - the last candidate, silently.
    while IFS= read -r chunk || [ -n "$chunk" ]; do
        case "$chunk" in *'"reachable":false'*|*'"reachable": false'*) ;; *) continue ;; esac
        ip="$(printf '%s\n' "$chunk" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$ip" ] && bad+="$ip"$'\n'
    done < <(printf '%s' "$response" | tr '{' '\n')

    # A family whose control is unreachable has no verdict at all.
    local skip_v4=0 skip_v6=0
    if grep -qxF -- "$PROBE_CONTROL_V4" <<< "$bad"; then
        skip_v4=1
        echo "NOTE: the backend cannot ping its own IPv4 control address - IPv4 left unverified" >&2
    fi
    if grep -qxF -- "$PROBE_CONTROL_V6" <<< "$bad"; then
        skip_v6=1
        echo "NOTE: the backend cannot ping its own IPv6 control address - IPv6 left unverified" >&2
    fi
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        [ "$ip" = "$PROBE_CONTROL_V4" ] || [ "$ip" = "$PROBE_CONTROL_V6" ] && continue
        case "$ip" in
            *:*) [ "$skip_v6" = 1 ] && continue ;;
            *)   [ "$skip_v4" = 1 ] && continue ;;
        esac
        printf '%s\n' "$ip"
    done <<< "$bad"
    return 0
}

is_listed() {
    local needle="$1" list="$2"
    [ -n "$needle" ] && grep -qxF -- "$needle" <<< "$list"
}

# =============================================================================
# interface mode
# =============================================================================
if [ "$MODE" = "interface" ]; then
    V4="$(local_ipv4)"
    V6="$(local_ipv6)"

    UNREACHABLE="$(probe_unreachable "$V4" "$V6")"
    if is_listed "$V4" "$UNREACHABLE"; then
        echo "IPv4 $V4 is on a local interface but not reachable from the backend - dropping it"
        V4=""
    fi
    if is_listed "$V6" "$UNREACHABLE"; then
        echo "IPv6 $V6 is on a local interface but not reachable from the backend - dropping it"
        V6=""
    fi

    # Cleared when absent, unlike egress mode: a family that did not survive the
    # probe must not linger in .env as if it had.
    ensure_key "PUBLIC_IPV4" "$V4"
    ensure_key "PUBLIC_IPV4_DASH" "$(to_dash "$V4")"
    ensure_key "PUBLIC_IPV6" "$V6"
    ensure_key "PUBLIC_IPV6_DASH" "$(to_dash "$V6")"

    # IPv4 first when the box has one of its own, IPv6 otherwise. With neither,
    # 127.0.0.1: routes built from an empty PUBLIC_IP_DASH are malformed
    # hostnames, which is worse than ones that only resolve locally.
    NEW="$V4"
    [ -n "$NEW" ] || NEW="$V6"
    if [ -z "$NEW" ]; then
        echo "WARN: no reachable public address on any local interface, using 127.0.0.1"
        NEW="127.0.0.1"
    fi

    if [ "$NEW" = "${PUBLIC_IP:-}" ]; then
        ensure_key "PUBLIC_IP_DASH" "$(to_dash "$NEW")"
        echo "Public IP unchanged: $NEW (interface mode)"
        exit 0
    fi
    set_env_value "PUBLIC_IP" "$NEW"
    set_env_value "PUBLIC_IP_DASH" "$(to_dash "$NEW")"
    echo "Public IP changed: ${PUBLIC_IP:-<empty>} -> $NEW (interface mode; .env updated, stack will be recreated)"
    exit 0
fi

# =============================================================================
# egress mode (default)
# =============================================================================
DETECTED="$(egress_ipv4)"

# IPv6 is informational in this mode: PUBLIC_IP stays the v4 address. Detected
# so the key exists for consumers that want it; absence is normal.
DETECTED_V6="$(egress_ipv6)"

if [ -n "$DETECTED_V6" ]; then
    ensure_key "PUBLIC_IPV6" "$DETECTED_V6"
    ensure_key "PUBLIC_IPV6_DASH" "$(to_dash "$DETECTED_V6")"
fi

if [ -z "$DETECTED" ]; then
    echo "WARN: could not detect public IP (all services failed), keeping PUBLIC_IP=${PUBLIC_IP:-<empty>}"
    exit 0
fi

if is_listed "$DETECTED" "$(probe_unreachable "$DETECTED")"; then
    echo "WARN: $DETECTED does not answer a ping from the backend. Not changed - a firewall that"
    echo "      drops ICMP is common - but if this box is not reachable on 80/443 either, only"
    echo "      the tunnel route will work."
fi

ensure_key "PUBLIC_IPV4" "$DETECTED"
ensure_key "PUBLIC_IPV4_DASH" "$(to_dash "$DETECTED")"

if [ "$DETECTED" = "${PUBLIC_IP:-}" ]; then
    echo "Public IP unchanged: $DETECTED"
    exit 0
fi

set_env_value "PUBLIC_IP" "$DETECTED"
set_env_value "PUBLIC_IP_DASH" "$(to_dash "$DETECTED")"
echo "Public IP changed: ${PUBLIC_IP:-<empty>} -> $DETECTED (.env updated, stack will be recreated)"
