#!/bin/bash
# pre-up.sh <dest-dir> <dest-compose> — run by scripts/tools/deploy-stack.sh after
# the pull and the name-squatter eviction, right before `up`.
#
# Both steps need exactly that point: the DEPLOYED compose file (deploy-stack.sh
# has just copied it) and a box where the mesh-project dex/authelia/auth-registrar
# are already gone.
set -euo pipefail

# The tree this file sits in — template/, or the freshly extracted one when a
# migration runs deploy-stack.sh — so its library matches its compose file.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/library/common.sh"

DEST_COMPOSE="${2:?usage: pre-up.sh <dest-dir> <dest-compose>}"
FAILED=0

# dex-internal was created by the mesh project before the split. Once the eviction
# has detached dex and auth-registrar it is empty; removing it lets this `up`
# recreate it as the auth project's own (see adopt_network).
adopt_network dex-internal auth || FAILED=1

# Never start Authelia on an image older than its database (see
# authelia_enforce_db_floor in library/common.sh). Against the deployed file, so
# the pin it checks is the pin that gets started.
authelia_enforce_db_floor "$DEST_COMPOSE" "$MESH_ROOT/auth" || FAILED=1

exit "$FAILED"
