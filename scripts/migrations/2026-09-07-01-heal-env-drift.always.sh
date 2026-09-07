#!/bin/bash
# Migration: re-apply the .env normalisations a clobbered/restored .env reverts.
#
# WHY .always.sh AND NOT A ONE-SHOT
#
# Migrations -01- (key renames), -02- (channel -> UPDATE_URL) and -03- (root domain
# casaos:8080 -> maison:80) each write a marker as soon as they succeed. -04- then
# moves the app directory, and until this release it resolved a .env clash by keeping
# the copy from the OLD path — the pre-migration one. On a stable -> main upgrade done
# by re-running install.sh (the documented update path), that sequence applies all
# three content migrations to a .env and then throws that .env away, while the markers
# stay behind saying the work is done. The box ends the cycle with:
#
#   DEFAULT_SERVICE_HOST=casaos   -> 502 on ${DOMAIN}, both bare-IP hostnames and the
#                                    catch-all, because no casaos container exists
#   no UPDATE_URL, MESH_UPDATE_CHANNEL=stable
#                                 -> mesh_template_url() resolves the stable branch,
#                                    so the next nightly silently rolls the box back
#   PROVIDER= / DEFAULT_PASSWORD= -> old key schema, alive only on the compose
#                                    ${PROVIDER_STR:-${PROVIDER}} fallbacks
#
# -04- is fixed to merge instead of pick, so this cannot recur. This file repairs the
# boxes that already ran it. A one-shot would not: their markers are already written,
# and a marker cannot be "un-set" from a release. Being marker-free is also the right
# shape independently — a marker records that a migration RAN, not that its outcome
# survived, and anything that restores a .env from a backup (an operator, a snapshot,
# a rollback) resurrects exactly this drift.
#
# The renames themselves are NOT repeated here: ensure-env-valid.sh already carries
# heal_renamed_key for precisely this case, and it runs every cycle. What follows is
# the part that has no self-healing equivalent yet.
#
# Must stay a no-op on a fresh install and on an already-healthy box.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

ENV_MGR="$SELF_DIR/../tools/env-file-manager.sh"

[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE yet; nothing to heal"; exit 0; }

HEALED=0

# --- 1. rescue the update source from the parked copy -------------------------
# .env.pre-move is the file -04- discarded. The only thing in it that cannot be
# reconstructed from anywhere else is the install intent: which branch this box was
# installed from. Everything else in it was either backfilled from defaults or is a
# secret the LIVE file already holds a better copy of — so this reads exactly one key
# and never adopts the file wholesale (its DEFAULT_PWD is a freshly generated value
# that no installed app has ever seen; adopting it would break every app's DB login).
PRE_MOVE="$APP_DIR/.env.pre-move"
if [ -f "$PRE_MOVE" ] && [ -z "$(bash "$ENV_MGR" get UPDATE_URL "$ENV_FILE" 2>/dev/null || true)" ]; then
    rescued="$(bash "$ENV_MGR" get UPDATE_URL "$PRE_MOVE" 2>/dev/null || true)"
    if [ -n "$rescued" ]; then
        bash "$ENV_MGR" set UPDATE_URL "$rescued" "$ENV_FILE"
        echo "Rescued UPDATE_URL from .env.pre-move: $rescued"
        HEALED=1
    fi
fi

# --- 2. MESH_UPDATE_CHANNEL -> UPDATE_URL (re-apply of -02-) ------------------
# Same precedence -02- established: the canonical key is UPDATE_URL and it holds a
# full URL. A surviving MESH_UPDATE_CHANNEL means the box is still resolving its
# update source through the deprecated path (common.sh mesh_template_url step 3).
channel="$(bash "$ENV_MGR" get MESH_UPDATE_CHANNEL "$ENV_FILE" 2>/dev/null || true)"
if [ -n "$channel" ]; then
    if [ -z "$(bash "$ENV_MGR" get UPDATE_URL "$ENV_FILE" 2>/dev/null || true)" ]; then
        bash "$ENV_MGR" set UPDATE_URL "$(mesh_channel_url "$channel")" "$ENV_FILE"
        echo "Expanded MESH_UPDATE_CHANNEL=$channel into UPDATE_URL"
    fi
    bash "$ENV_MGR" delete MESH_UPDATE_CHANNEL "$ENV_FILE"
    echo "Dropped deprecated MESH_UPDATE_CHANNEL"
    HEALED=1
fi

# --- 3. root domain: casaos:8080 -> maison:80 (re-apply of -03- step 3) -------
# CasaOS is not in this template's compose file, so `casaos` can never resolve on the
# `pcs` network again — this is a dead value, not a preference. An operator who chose
# some other service keeps their choice, same rule as -03-.
current_host="$(bash "$ENV_MGR" get DEFAULT_SERVICE_HOST "$ENV_FILE" 2>/dev/null || true)"
if [ -z "$current_host" ] || [ "$current_host" = "casaos" ]; then
    bash "$ENV_MGR" set DEFAULT_SERVICE_HOST "maison" "$ENV_FILE"
    bash "$ENV_MGR" set DEFAULT_SERVICE_PORT "80" "$ENV_FILE"
    echo "Root domain repointed: casaos:8080 -> maison:80"
    HEALED=1
fi

# --- 4. sweep dead state (re-apply of -03- step 5) ---------------------------
if bash "$ENV_MGR" exists BRIDGE_SECRET "$ENV_FILE"; then
    bash "$ENV_MGR" delete BRIDGE_SECRET "$ENV_FILE"
    echo "Dropped dead BRIDGE_SECRET from .env"
    HEALED=1
fi

# --- 5. retire the parked copy ------------------------------------------------
# Renamed rather than deleted: it is the only record of what the box looked like
# before the move, and step 1 keys off the .pre-move name, so leaving it in place
# would make this file's first section re-runnable against stale data forever.
if [ "$HEALED" -eq 1 ] && [ -f "$PRE_MOVE" ]; then
    mv -f "$PRE_MOVE" "$PRE_MOVE.healed"
    echo "Retired .env.pre-move -> .env.pre-move.healed"
fi

[ "$HEALED" -eq 1 ] || echo "No .env drift to heal"
