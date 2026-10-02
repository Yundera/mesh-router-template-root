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

# Is Authelia answering right now?
#
# Two independent signals, whichever says yes first:
#
#   1. Authelia's own /api/health over the container's bridge address. Port 9091
#      is `expose`d, not published, so this goes host -> docker bridge; it is the
#      fast signal (true within ~3-6s of a restart).
#   2. The container's health status. The authelia image ships its own HEALTHCHECK
#      (/app/healthcheck.sh), but with interval 30s and start_period 60s, so this
#      only turns "healthy" ~30s in. It is the fallback for a host that cannot
#      reach the bridge directly.
#
# Never fatal: a false negative here only means falling through to the timeout.
authelia_is_ready() {
    local ip health

    # `|| true`: under `set -o pipefail` a container that vanished mid-run would
    # otherwise make this assignment fail and take the whole script with it.
    ip="$(docker inspect authelia \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null \
        | awk '{print $1}')" || true
    if [ -n "$ip" ] && command -v curl >/dev/null 2>&1; then
        if curl -sf --max-time 3 -o /dev/null "http://${ip}:9091/api/health" 2>/dev/null; then
            return 0
        fi
    fi

    health="$(docker inspect authelia \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)"
    [ "$health" = "healthy" ]
}

# How long to wait, once Authelia answers, for mesh-router-caddy to route
# local-auth-${DOMAIN} to it again.
#
# Authelia answering on its bridge address is not what Dex needs: Dex reaches its
# issuer through mesh-router-caddy (the on-box pin, see local_auth_discovery_ok),
# and caddy-docker-proxy DROPS a container's label routes when it restarts, then
# re-adds them only on a later regeneration. Measured on a Yundera box with ~25
# app containers, 2026-10-02: the route came back 20-25s after
# `docker restart authelia`, every night, so a Dex restarted in between could not
# open the Local Account connector.
LOCAL_AUTH_ROUTE_TIMEOUT=60

# The mesh CA that signs local-auth-${DOMAIN} on the on-box path. On the run that
# first delivers data/ca the file is still beside the key: ensure-stack-up.sh,
# later in the list, is what moves it. Same CA either way. Empty when neither
# exists yet.
local_auth_ca() {
    local ca="$MESH_ROOT/data/ca/ca-cert.pem"
    [ -s "$ca" ] || ca="$MESH_ROOT/data/certs/ca-cert.pem"
    [ -s "$ca" ] && printf '%s' "$ca"
    return 0
}

# Does local-auth-$DOMAIN serve a discovery document over the path Dex takes to
# open the Local Account connector? Dex's extra_hosts pins the name to this host's
# :443 — mesh-router-caddy — and SSL_CERT_DIR makes it trust the mesh CA
# (stacks/auth/docker-compose.yml). This is the same request from the host: same
# port, same certificate, same CA file.
#
# `"issuer"` in the BODY is the assertion, not the status code: Caddy answers a
# host it has no route for with an empty 200.
#
# Return codes: 0 serving, 1 not serving, 2 cannot tell here (no DOMAIN, no curl,
# no mesh CA yet) — callers treat 2 as "nothing to wait for".
local_auth_discovery_ok() {
    local domain ca discovery
    domain="$(get_env_value DOMAIN)"
    ca="$(local_auth_ca)"
    if [ -z "$domain" ] || [ -z "$ca" ] || ! command -v curl >/dev/null 2>&1; then
        return 2
    fi
    # Captured, not piped: under pipefail, `grep -q` closing the pipe early would
    # fail curl and read as a failed probe.
    discovery="$(curl -sS --max-time 10 \
            --resolve "local-auth-$domain:443:127.0.0.1" --cacert "$ca" \
            "https://local-auth-$domain/.well-known/openid-configuration" 2>/dev/null || true)"
    grep -q '"issuer"' <<<"$discovery"
}

# Block until Authelia is serving where Dex will look for it, or the budget runs
# out: first Authelia itself, then mesh-router-caddy's route to it. Returns 0
# either way: a box where this never comes up has a bigger problem than a missing
# login button, and aborting here would take the rest of the caller's convergence
# with it.
wait_for_authelia() {
    local waited=0 rc

    while [ "$waited" -lt "$AUTHELIA_READY_TIMEOUT" ]; do
        if authelia_is_ready; then
            log_info "Authelia is answering again after ${waited}s"
            break
        fi
        sleep "$AUTHELIA_READY_INTERVAL"
        waited=$((waited + AUTHELIA_READY_INTERVAL))
    done
    if [ "$waited" -ge "$AUTHELIA_READY_TIMEOUT" ]; then
        log_warn "Authelia did not answer within ${AUTHELIA_READY_TIMEOUT}s of its restart"
        log_warn "  The Local Account connector may be missing from the Dex login page"
        log_warn "  until Dex next restarts (the next self-check at the latest)."
        return 0
    fi

    # Before the mesh stack has run (fresh install: no CA, maybe no Caddy) there
    # is no on-box route to wait for, and the deploy that brings it up starts Dex
    # after it anyway.
    if [ "$(docker container inspect -f '{{.State.Running}}' mesh-router-caddy 2>/dev/null)" != "true" ]; then
        return 0
    fi
    waited=0
    while [ "$waited" -lt "$LOCAL_AUTH_ROUTE_TIMEOUT" ]; do
        rc=0
        local_auth_discovery_ok || rc=$?
        [ "$rc" -eq 2 ] && return 0
        if [ "$rc" -eq 0 ]; then
            [ "$waited" -gt 0 ] && log_info "mesh-router-caddy routes local-auth again after ${waited}s"
            return 0
        fi
        sleep "$AUTHELIA_READY_INTERVAL"
        waited=$((waited + AUTHELIA_READY_INTERVAL))
    done
    log_warn "mesh-router-caddy did not route local-auth to Authelia within ${LOCAL_AUTH_ROUTE_TIMEOUT}s"
    log_warn "  Dex may fail to open the Local Account connector until it next restarts."
    return 0
}
