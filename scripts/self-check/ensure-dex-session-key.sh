#!/bin/bash
# ensure-dex-session-key.sh - Mint the AES key Dex uses to encrypt its session
# cookie.
#
# WHY THERE IS A DEX SESSION AT ALL
#
# Dex v2.45.1 and earlier hold no browser session: Dex re-ran its connector on
# every /authorize and advertised no logout of any kind. That is why "log out"
# could not actually log anyone out — each app's gate had to be ended one at a
# time, and the connector chooser reappeared on every app.
#
# Upstream fixed this: RP-Initiated Logout (PR #4674) and Back-Channel Logout
# with a `sid` claim (PR #4945) are merged. With DEX_SESSIONS_ENABLED=true Dex
# keeps a real `dex_session` cookie and advertises `end_session_endpoint` plus
# `backchannel_logout_supported`, which is what lets one logout end every app
# through the spec instead of through bespoke plumbing. Both are still
# UNRELEASED, which is why docker-compose.yml pins Dex by digest.
#
# WHAT THIS KEY IS
#
# `sessions.cookieEncryptionKey` — AES, and Dex accepts ONLY 16, 24 or 32 bytes
# (AES-128/192/256). We mint 32 raw bytes as base64 of 24, which is exactly 32
# ASCII characters. Note this is a *byte length* limit, not a string-format one:
# `openssl rand -hex 32` would be 64 characters and is rejected.
#
# Leaving it empty is legal (cookies then go unencrypted) but the cookie carries
# session state to a browser, so it gets encrypted.
#
# MUST RUN BEFORE ensure-dex.sh, which interpolates ${DEX_SESSION_KEY} into the
# rendered config. Unset renders an empty key: Dex still starts and sessions
# still work, they are merely unencrypted — it fails soft, not closed, which is
# why this is ordered rather than guarded.
#
# ROTATION invalidates every live Dex session, i.e. it costs one round of
# re-logins across every app on the box. Safe at any time.
#
# RECOVERY: nothing to back up. A lost key is re-minted on the next run.

set -e

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

DEX_SESSION_KEY="$(get_env_value DEX_SESSION_KEY)"
if [ -z "$DEX_SESSION_KEY" ]; then
    # 24 random bytes -> 32 base64 characters -> AES-256.
    DEX_SESSION_KEY="$(openssl rand -base64 24)"
    set_env_value DEX_SESSION_KEY "$DEX_SESSION_KEY"
    log_info "Generated DEX_SESSION_KEY (Dex session cookie encryption)"
fi

# No stack recreation here. Nothing in docker-compose.yml interpolates this
# value — it reaches Dex through the config file ensure-dex.sh renders, and that
# script already restarts dex when the rendered config changes.

log_success "Dex session key is in place"
