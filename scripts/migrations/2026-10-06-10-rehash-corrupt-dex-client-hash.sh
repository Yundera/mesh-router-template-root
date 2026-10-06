#!/bin/bash
# Migration: drop a corrupt Dex client hash so ensure-authelia.sh rehashes the existing secret
#
#   ${DATA_ROOT}/AppData/auth/authelia/secrets/dex-client-hash
#
# Until 2026-10-06, authelia_hash (ensure-authelia.sh) read `docker run`'s stderr
# together with its stdout. When the Authelia image was not cached yet, Docker's
# own pull line "Digest: sha256:…" was taken as a digest too, and the file got
# two lines: that sha256 and the real $pbkdf2- hash. Authelia renders both into
# the Dex client's client_secret, which then matches nothing — Local Account
# login fails with invalid_client while every self-check passes. Seen on a fresh
# install (demofoss1) and on a box crossing from Yundera's stable template.
#
# The fix to authelia_hash stops new boxes from writing it. This repairs the boxes
# that already have it: a file that is not exactly one $pbkdf2- line is removed,
# and ensure-authelia.sh — later in this same self-check — hashes the EXISTING
# AUTHELIA_DEX_SECRET again (it is not re-minted, so Dex's side is untouched),
# re-renders configuration.yml and restarts Authelia.
#
# A no-op on a fresh install (no file yet) and on a healthy box.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

HASH_FILE="$AUTHELIA_HOME/secrets/dex-client-hash"

if [ ! -f "$HASH_FILE" ]; then
    echo "No $HASH_FILE - nothing to check"
    exit 0
fi

# Healthy: a single line (written with printf '%s', so no newline at all) that
# starts with the pbkdf2 prefix.
# shellcheck disable=SC2016 # a literal $ in the pattern
if [ "$(wc -l < "$HASH_FILE")" -eq 0 ] && grep -q '^\$pbkdf2-' "$HASH_FILE"; then
    echo "$HASH_FILE is a single pbkdf2 hash - nothing to do"
    exit 0
fi

rm -f "$HASH_FILE"
echo "Removed corrupt $HASH_FILE - ensure-authelia.sh will rehash the existing secret"
