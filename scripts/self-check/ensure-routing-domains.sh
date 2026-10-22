#!/bin/bash
# Keep REDIRECT_HOST_SUFFIXES in .env equal to the box's routing domains.
#
# The auth-registrar accepts an app's OIDC callback only on <app>-<suffix> for each
# suffix in REDIRECT_HOST_SUFFIXES, and Maison publishes every app on the domains of
# its `routing` setting. Both come from routing_domains (library/common.sh): this
# writes the resolved list for the compose files to read, ensure-maison-stack.sh
# hands Maison the templated one. The ip zone is what showed why: apps were routed
# on <app>-<ip>.<IP_ZONE> while the registrar, still on a hand-written list,
# refused their logins there.
#
# A derived value, rewritten every run: edit routing_domains, not the .env. Runs
# after ensure-public-ip.sh (the suffixes embed the IP) and before the stacks are
# brought up, so a change reaches the registrar in the same run. Never fatal: with
# a value it needs still unknown, the key is left as it is, and the compose files
# fall back to the list they spell out.
set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

SUFFIXES="$(routing_host_suffixes)"
if [ -z "$SUFFIXES" ]; then
    echo "DOMAIN or PUBLIC_IP_DASH not set yet; REDIRECT_HOST_SUFFIXES left as it is"
    exit 0
fi

if [ "$(get_env_value REDIRECT_HOST_SUFFIXES)" = "$SUFFIXES" ]; then
    echo "REDIRECT_HOST_SUFFIXES unchanged: $SUFFIXES"
    exit 0
fi

set_env_value REDIRECT_HOST_SUFFIXES "$SUFFIXES"
echo "REDIRECT_HOST_SUFFIXES=$SUFFIXES"
