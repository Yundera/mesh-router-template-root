#!/bin/bash
# authelia-ready.sh - wait for Authelia to SERVE, not merely to be restarted.
#
# Shared by ensure-authelia.sh (after it restarts Authelia on a re-rendered config)
# and ensure-auth-stack.sh (after the auth stack recreated it). Ported from
# Yundera/template-root (scripts/library/authelia-ready.sh). Expects common.sh.

# How long to wait for Authelia to answer again after a restart, and how often to
# ask. Authelia's own startup is ~3-6s; the ceiling is deliberately generous
# because the two directions cost very different things:
#
#   * overshooting costs seconds on a self-check that already takes minutes;
#   * undershooting costs the box its Local Account login for a WHOLE CYCLE.
#
# Dex opens every connector once, at startup, and the Local Account connector's
# issuer is Authelia. A fire-and-forget `docker restart authelia` followed a
# second or two later by ensure-dex.sh's `docker restart dex` starts Dex against
# an Authelia that is not listening yet — and what Dex could not open at startup
# stays unopened until Dex next restarts, i.e. the next nightly self-check.
# Diagnosed on a Yundera box, 2026-09-28: seven consecutive nights without the
# Local Account button.
#
# The postcondition of ensure-authelia.sh is therefore "Authelia is SERVING", not
# "a restart was requested".
AUTHELIA_READY_TIMEOUT=45
AUTHELIA_READY_INTERVAL=2

# Authelia's address on pcs, the network the host can reach (authelia-internal is
# `internal: true`). Same listener Dex reaches on authelia-internal: Authelia binds
# 0.0.0.0:443. Empty when the container is not there.
authelia_pcs_ip() {
    # `|| true`: under `set -o pipefail` a container that vanished mid-run would
    # otherwise make this assignment fail and take the whole script with it.
    docker inspect authelia \
        --format '{{with index .NetworkSettings.Networks "pcs"}}{{.IPAddress}}{{end}}' 2>/dev/null || true
}

# Does Authelia serve a discovery document the way Dex asks for it? Dex calls
# https://local-auth-$DOMAIN on authelia-internal, where the name is Authelia
# itself, and trusts Authelia's own certificate (rootCAs in the connector, written
# by ensure-authelia.sh). This is the same request from the host: same name, same
# listener, same certificate, over pcs.
#
# `"issuer"` in the BODY is the assertion, not the status code.
#
# Return codes: 0 serving, 1 not serving, 2 cannot tell here (no DOMAIN, no curl,
# no certificate, no container) — callers treat 2 as "nothing to probe".
local_auth_discovery_ok() {
    local domain ip cert="$AUTHELIA_HOME/tls/cert.pem" discovery
    domain="$(get_env_value DOMAIN)"
    ip="$(authelia_pcs_ip)"
    if [ -z "$domain" ] || [ -z "$ip" ] || [ ! -s "$cert" ] || ! command -v curl >/dev/null 2>&1; then
        return 2
    fi
    # Captured, not piped: under pipefail, `grep -q` closing the pipe early would
    # fail curl and read as a failed probe.
    discovery="$(curl -sS --max-time 10 \
            --resolve "local-auth-$domain:443:$ip" --cacert "$cert" \
            "https://local-auth-$domain/.well-known/openid-configuration" 2>/dev/null || true)"
    grep -q '"issuer"' <<<"$discovery"
}

# Is Authelia answering right now?
#
# Two independent signals, whichever says yes first:
#
#   1. the discovery probe above — what Dex needs, true within ~3-6s of a restart;
#   2. the container's health status. The authelia image ships its own HEALTHCHECK
#      (/app/healthcheck.sh), but with interval 30s and start_period 60s, so this
#      only turns "healthy" ~30s in. It is the fallback for a host that cannot
#      probe (no curl, no certificate yet).
#
# Never fatal: a false negative here only means falling through to the timeout.
authelia_is_ready() {
    local health
    local_auth_discovery_ok && return 0
    health="$(docker inspect authelia \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)"
    [ "$health" = "healthy" ]
}

# Block until Authelia is serving, or the budget runs out. Returns 0 either way: a
# box where this never comes up has a bigger problem than a missing login button,
# and aborting here would take the rest of the caller's convergence with it.
#
# Only Authelia itself: Dex no longer goes through mesh-router-caddy, so the
# 20-25s caddy-docker-proxy takes to re-add a restarted container's route
# (measured 2026-10-02) is the browser's concern, not Dex's.
wait_for_authelia() {
    local waited=0

    while [ "$waited" -lt "$AUTHELIA_READY_TIMEOUT" ]; do
        if authelia_is_ready; then
            log_info "Authelia is answering again after ${waited}s"
            return 0
        fi
        sleep "$AUTHELIA_READY_INTERVAL"
        waited=$((waited + AUTHELIA_READY_INTERVAL))
    done
    log_warn "Authelia did not answer within ${AUTHELIA_READY_TIMEOUT}s of its restart"
    log_warn "  The Local Account connector may be missing from the Dex login page"
    log_warn "  until Dex next restarts (the next self-check at the latest)."
    return 0
}
