#!/bin/bash
# Migration: move Authelia's and Dex's state from the mesh root into the auth stack's folder
#
#   ${DATA_ROOT}/AppData/mesh/auth  ->  ${DATA_ROOT}/AppData/auth/authelia
#   ${DATA_ROOT}/AppData/mesh/dex   ->  ${DATA_ROOT}/AppData/auth/dex
#
# The auth stack was split out of the mesh stack on 2026-09-30 but left its state
# behind in the mesh root. Each stack now keeps its state in its own folder — the
# same layout as Yundera/template-root. The logic, and why a rename is safe while
# the containers keep running, is adopt_auth_state in library/common.sh; the
# stack deploy later in this same self-check (ensure-auth-stack.sh) recreates the
# containers from the compose file this sync is about to deliver.
#
# A HARD FAILURE ON PURPOSE, unlike most migrations here. A non-zero exit aborts
# the template sync, so the box keeps its old tree and its old compose file, both
# of which still agree with where the state is. Exiting 0 without having moved
# would be the dangerous outcome: the runner would write the marker, the new
# compose file would land, and the stack would come up on empty folders — an
# unclaimed box.
#
# A no-op on a fresh install (nothing at the old paths) and on a re-run.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/../library/common.sh"

adopt_auth_state
echo "Auth state is in $AUTH_STACK_DIR"
