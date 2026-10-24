#!/bin/bash
# Follow the backend's view of this box's zone: when <label>.<server-domain> is
# delegated to the mesh nameservers and the delegation is live in the parent zone,
# Caddy gets the box's own Let's Encrypt certificates by DNS-01 — *.<domain> and
# <domain> — through the backend's acme-dns API, with the box's route signature as
# the credential. The nameservers then answer the box's IP (not the gateway's) once
# the backend's probe sees those certificates.
#
# The state lives in data/dns/ (mounted read-only into mesh-router-caddy at /data/dns):
#   site_tls.caddy   the root domain's TLS: `import gateway_tls`, or the DNS-01 block
#   wildcard.caddy   empty, or the *.{$DOMAIN} site with the DNS-01 block
#   tls_passthrough  SNIs served from Caddy's own certificates instead of the gateway
#                    CA (read by the image's entrypoint), one per name whose ACME
#                    certificate is in Caddy's storage
#   tls_automate     names Caddy must obtain even though the gateway CA certificate
#                    (cert0, *.<zone>) already covers them: the root <domain>; without
#                    it automatic HTTPS skips the name (read by the entrypoint too)
# plus DNS_DOT_FORM=1 in .env once the wildcard is there, which turns on the dot form
# <app>.<domain> for store apps (routing_domains, ensure-routing-domains.sh).
#
# Not live = the files' defaults, which give the exact config the Caddyfile had before
# these hooks. Backend unreachable = nothing changes. Never fatal.
set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

ensure_dns_state_files

DOMAIN="$(get_env_value DOMAIN)"
IFS=',' read -r BACKEND_URL USER_ID SIG <<< "${PROVIDER_STR:-}"
if [ -z "$DOMAIN" ] || [ -z "$BACKEND_URL" ] || [ -z "$USER_ID" ] || [ -z "$SIG" ]; then
    echo "DOMAIN or PROVIDER_STR not set yet; DNS delegation state left as it is"
    exit 0
fi
API_URL="${BACKEND_URL%/}/router/api"
LABEL="${DOMAIN%%.*}"

if ! RESOLVE="$(curl -fsS --max-time 15 "$API_URL/resolve/v2/$LABEL" 2>/dev/null)"; then
    echo "WARN: backend unreachable; DNS delegation state left as it is"
    exit 0
fi
# Parsed with a pattern, not jq: this template adds no host dependency for it. "live"
# is only in the backend's dns block, true when the parent zone delegates to us.
LIVE=0
case "$RESOLVE" in *'"live":true'*) LIVE=1 ;; esac

CERTS="$MESH_ROOT/data/caddy/data/caddy/certificates"

# have_cert <name>: Caddy's storage holds an ACME certificate for <name> valid for at
# least one more day. Only ACME issuer directories: local/ holds Caddy's internal CA,
# which no browser trusts.
have_cert() {
    local dir="${1//\*/wildcard_}" crt
    for crt in "$CERTS"/acme*/"$dir"/"$dir".crt; do
        [ -s "$crt" ] || continue
        if command -v openssl >/dev/null 2>&1; then
            openssl x509 -checkend 86400 -noout -in "$crt" >/dev/null 2>&1 && return 0
        else
            return 0
        fi
    done
    return 1
}

if [ "$LIVE" = 1 ]; then
    DNS01="    tls {
        dns acmedns {
            username \"$USER_ID\"
            password \"$SIG\"
            subdomain \"$LABEL\"
            server_url \"$API_URL/acme-dns\"
        }
    }"
    SITE_TLS="(site_tls) {
$DNS01
}"
    WILDCARD="*.{\$DOMAIN} {
$DNS01
    reverse_proxy {\$DEFAULT_SERVICE_HOST}:{\$DEFAULT_SERVICE_PORT}
}"
    AUTOMATE="$DOMAIN"
    PASSTHROUGH=""
    have_cert "$DOMAIN" && PASSTHROUGH+="$DOMAIN"$'\n'
    have_cert "*.$DOMAIN" && PASSTHROUGH+="*.$DOMAIN"$'\n'
    if have_cert "*.$DOMAIN"; then DOT_FORM=1; else DOT_FORM=""; fi
else
    SITE_TLS="$DNS_SITE_TLS_DEFAULT"
    WILDCARD=""
    AUTOMATE=""
    PASSTHROUGH=""
    DOT_FORM=""
fi

# write_state <file> <content>: rewrite only on change; prints the file name if it did.
write_state() {
    local file="$DNS_STATE_DIR/$1" content="$2" tmp
    tmp="$(mktemp "$DNS_STATE_DIR/.tmp.XXXXXX")"
    if [ -n "$content" ]; then printf '%s\n' "$content" >"$tmp"; fi
    chmod 600 "$tmp"
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$file"
    echo "$1 "
}

CHANGED=""
CHANGED+="$(write_state site_tls.caddy "$SITE_TLS")"
CHANGED+="$(write_state wildcard.caddy "$WILDCARD")"
# write_list <file> <lines>: like write_state, the file removed when empty. Prints
# "<file> " on a change, "<file>- " when the change removed names (only a restart
# drops those: the entrypoint adds missing names by itself).
write_list() {
    local file="$DNS_STATE_DIR/$1" old
    old="$(cat "$file" 2>/dev/null || true)"
    if [ -n "$2" ]; then
        [ -n "$(write_state "$1" "${2%$'\n'}")" ] || return 0
    elif [ -f "$file" ]; then
        rm -f "$file"
    else
        return 0
    fi
    if [ -n "$old" ] && [ -n "$(comm -23 <(printf '%s\n' "$old" | sort) <(printf '%s' "$2" | sort))" ]; then
        echo "$1- "
    else
        echo "$1 "
    fi
}
LISTS_CHANGED="$(write_list tls_passthrough "$PASSTHROUGH")$(write_list tls_automate "$AUTOMATE")"

if [ "$(get_env_value DNS_DOT_FORM)" != "$DOT_FORM" ]; then
    if [ -n "$DOT_FORM" ]; then
        set_env_value DNS_DOT_FORM 1
    else
        bash "$ENV_MGR" delete DNS_DOT_FORM "$ENV_FILE" >/dev/null
    fi
    echo "DNS_DOT_FORM=${DOT_FORM:-<unset>}"
fi

echo "Zone $DOMAIN: $([ "$LIVE" = 1 ] && echo "delegated to the mesh nameservers" || echo "not delegated (gateway CA)")" \
    "$([ -n "$PASSTHROUGH" ] && printf '| own certificates: %s' "$(printf '%s' "$PASSTHROUGH" | tr '\n' ' ')")"

# The Caddyfile imports are read when Caddy (re)builds its config: restart it for a
# changed import. The entrypoint adds new passthrough / automate names by itself within
# seconds, but only a restart drops a removed one.
if [ -n "$CHANGED" ] || [[ "$LISTS_CHANGED" == *"- "* ]]; then
    if docker ps --format '{{.Names}}' | grep -qx mesh-router-caddy; then
        echo "DNS state changed (${CHANGED}${LISTS_CHANGED}); restarting mesh-router-caddy"
        docker restart mesh-router-caddy >/dev/null
    fi
fi
