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

# Block until authelia_is_ready or the budget runs out. Returns 0 either way: a
# box where this never comes up has a bigger problem than a missing login button,
# and aborting here would take the rest of the caller's convergence with it.
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
