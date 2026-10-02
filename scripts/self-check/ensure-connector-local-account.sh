#!/bin/bash
# ensure-connector-local-account.sh - retired: the Local Account connector is
# written by ensure-authelia.sh (`--connector-only` for this step alone).
#
# NOT a self-check step. Kept for a caller that still runs it by path: a
# Yundera/template-root onboarding.sh older than the merge, which updates on its
# own channel. Delete once that release has reached the fleet.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ensure-authelia.sh" --connector-only "$@"
