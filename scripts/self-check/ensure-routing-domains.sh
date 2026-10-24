#!/bin/bash
# Keep the .env's view of the box's routing domains current: REDIRECT_HOST_SUFFIXES
# and ROUTING_DOMAINS.
#
# The auth-registrar accepts an app's OIDC callback only on <app>-<suffix> for each
# suffix in REDIRECT_HOST_SUFFIXES, and Maison publishes every app on the domains of
# its `routing` setting. Both come from routing_domains (library/common.sh): this
# writes the resolved list for the compose files to read, ensure-maison-stack.sh
# hands Maison the templated one. The ip zone is what showed why: apps were routed
# on <app>-<ip>.<IP_ZONE> while the registrar, still on a hand-written list,
# refused their logins there.
#
# ROUTING_DOMAINS is the same list with each domain's proxy labels, for a layer on
# top of this template (template-root) to render its own stacks' routes from; this
# template's stacks render theirs from routing_domains directly.
#
# Derived values, rewritten every run: edit routing_domains, not the .env. Runs
# after ensure-public-ip.sh (the suffixes embed the IP) and before the stacks are
# brought up, so a change reaches the registrar in the same run. Never fatal: with
# a value it needs still unknown, the keys are left as they are, and the compose
# files fall back to the list they spell out.
set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

DOMAINS="$(routing_domains_value)"
if [ -z "$DOMAINS" ]; then
    echo "DOMAIN or PUBLIC_IP_DASH not set yet; REDIRECT_HOST_SUFFIXES and ROUTING_DOMAINS left as they are"
    exit 0
fi

# key value: write it only when it differs.
sync_key() {
    if [ "$(get_env_value "$1")" = "$2" ]; then
        echo "$1 unchanged: $2"
    else
        set_env_value "$1" "$2"
        echo "$1=$2"
    fi
}

sync_key REDIRECT_HOST_SUFFIXES "$(routing_host_suffixes)"
sync_key REDIRECT_DOT_SUFFIXES "$(routing_dot_suffixes)"
sync_key ROUTING_DOMAINS "$DOMAINS"
