#!/bin/bash
# ensure-maison-app-mirror.sh - Project every CasaOS-installed app into Maison's layout.
#
# For each app under /DATA/AppData/casaos/apps/<app> (CasaOS's AppsPath), write:
#     ${DATA_ROOT}/AppData/<app>/docker-compose.yml   copy of CasaOS's compose file
#     ${DATA_ROOT}/AppData/<app>/.env                 CasaOS's injected variables, materialised
#     ${DATA_ROOT}/AppData/<app>/.casaos-mirror       provenance marker (this script's own)
#
# WHY, NOW THAT CASAOS IS GONE: boxes installed before this release have their apps
# under CasaOS's tree, and those containers keep running (Docker's restart policy) —
# but CasaOS itself is no longer there to manage them. Maison already *sees* them
# (it reads the compose from the `com.docker.compose.project.working_dir` label over
# the Docker socket), yet only as "unmanaged" tiles: open, start/stop/restart, logs,
# stats. These files promote them to "managed" — plus Env / Compose / Override /
# WebUI editors and store Updates — because Maison's isManaged() is simply
# stat(${DATA_ROOT}/AppData/<app>/docker-compose.yml).
#
# A fresh install has no such tree and this script is a no-op.
#
# THIS SCRIPT NEVER RUNS `docker compose up`. It writes files only.
#
# COPY, NOT HARDLINK. A hardlink between the two paths does not survive: Maison's
# "Apply update" does os.WriteFile() on docker-compose.yml, which truncates in place —
# through a shared inode that would rewrite the source too, destroying its
# install-time substitutions and baked-in labels.
#
# THE .env IS THE VERIFICATION ARTEFACT. CasaOS used no per-app .env at all: it
# interpolated each compose at up-time from the *casaos container's own* environment.
# We materialise exactly that variable set so the mirrored folder renders identically,
# which this script then asserts with `docker compose config` on both sides, reporting
# MIRROR_DRIFT on any mismatch. A drifting mirror must not be trusted.
#
# Ported from Yundera/template-root (scripts/self-check/ensure-maison-app-mirror.sh).
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

APPS_DIR="/DATA/AppData/casaos/apps"
DST_ROOT="${DATA_ROOT:-/DATA}/AppData"
MARKER_NAME=".casaos-mirror"

if [ ! -d "$APPS_DIR" ]; then
    echo "No CasaOS apps directory, nothing to mirror"
    exit 0
fi

# The variables CasaOS injected at compose-up. These must match what the casaos
# container actually supplied or the render comparison below is meaningless.
M_DEFAULT_PWD="$(get_env_value DEFAULT_PWD)"
M_DOMAIN="$(get_env_value DOMAIN)"
M_PUBLIC_IPV4="$(get_env_value PUBLIC_IPV4)"
M_PUBLIC_IPV6="$(get_env_value PUBLIC_IPV6)"
M_PUBLIC_IP_DASH="$(get_env_value PUBLIC_IP_DASH)"
M_PUBLIC_IPV4_DASH="$(get_env_value PUBLIC_IPV4_DASH)"
M_PUBLIC_IPV6_DASH="$(get_env_value PUBLIC_IPV6_DASH)"
M_EMAIL="$(get_env_value EMAIL)"
[ -z "$M_EMAIL" ] && M_EMAIL="admin@$M_DOMAIN"

if [ -f /etc/timezone ]; then
    M_TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"
elif [ -L /etc/localtime ]; then
    M_TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
else
    M_TZ="UTC"
fi

mirrored_count=0
skipped_count=0
conflict_count=0
unverified_count=0
drifted_apps=()

# Render a compose file the way CasaOS did: variables supplied through the process
# environment.
#
# HERMETIC (`env -i`), like render_from_dotenv below. Both sides must see exactly the
# variables we name and nothing else, or the comparison depends on WHO ran the
# self-check: an interactive `sudo` shell carries a rich environment, the 3am cron
# carries almost none. An app compose referencing any ambient variable would render
# differently between the two, and drift would appear or vanish depending on the
# invoker rather than on the mirror actually being wrong.
render_as_casaos() {
    local compose_file="$1" app_name="$2" dir="$3"
    env -i PATH="$PATH" HOME="${HOME:-/root}" \
    AppID="$app_name" \
    PUID="${PUID:-1000}" \
    PGID="${PGID:-1000}" \
    TZ="$M_TZ" \
    default_pwd="$M_DEFAULT_PWD" \
    public_ip="$M_PUBLIC_IPV4" \
    domain="$M_DOMAIN" \
    PCS_DEFAULT_PASSWORD="$M_DEFAULT_PWD" \
    PCS_DOMAIN="$M_DOMAIN" \
    PCS_DATA_ROOT="${DATA_ROOT:-/DATA}" \
    PCS_PUBLIC_IP="$M_PUBLIC_IPV4" \
    PCS_PUBLIC_IPV6="$M_PUBLIC_IPV6" \
    PCS_EMAIL="$M_EMAIL" \
    APP_DEFAULT_PASSWORD="$M_DEFAULT_PWD" \
    APP_DOMAIN="$M_DOMAIN" \
    APP_DATA_ROOT="${DATA_ROOT:-/DATA}" \
    APP_PUBLIC_IP="$M_PUBLIC_IPV6" \
    APP_PUBLIC_IP_DASH="$M_PUBLIC_IP_DASH" \
    APP_PUBLIC_IPV4="$M_PUBLIC_IPV4" \
    APP_PUBLIC_IPV4_DASH="$M_PUBLIC_IPV4_DASH" \
    APP_PUBLIC_IPV6="$M_PUBLIC_IPV6" \
    APP_PUBLIC_IPV6_DASH="$M_PUBLIC_IPV6_DASH" \
    APP_EMAIL="$M_EMAIL" \
    APP_NET="pcs" \
    COMPOSE_PROJECT_NAME="$app_name" \
    docker compose --project-directory "$dir" -f "$compose_file" config 2>/dev/null
}

# Render the mirrored folder the way Maison will: nothing in the process
# environment, everything from the generated .env. `env -i` is what makes this a real
# test — inheriting our own exports would prove nothing about the .env.
render_from_dotenv() {
    local dir="$1"
    env -i PATH="$PATH" HOME="${HOME:-/root}" \
        docker compose --project-directory "$dir" -f "$dir/docker-compose.yml" config 2>/dev/null
}

for app_dir in "$APPS_DIR"/*/; do
    [ -d "$app_dir" ] || continue

    app_name="$(basename "$app_dir")"
    src_compose="$app_dir/docker-compose.yml"

    # The mesh stack is the template itself, not a user app.
    [ "$app_name" = "mesh" ] && continue
    [ -f "$src_compose" ] || continue

    # Maison ignores any directory whose name contains a dot, so a mirror of such an
    # app could never be seen. Don't create a misleading folder.
    if [[ "$app_name" == *.* ]]; then
        log_warn "Skipping '$app_name': Maison ignores directory names containing a dot"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    dst_dir="$DST_ROOT/$app_name"
    dst_compose="$dst_dir/docker-compose.yml"
    marker="$dst_dir/$MARKER_NAME"

    # $dst_dir almost always exists already — it is the app's DATA directory, and
    # Maison's flat layout deliberately puts the compose next to the data. What we
    # must never do is clobber a compose we did not write: one present WITHOUT our
    # marker means a Maison-native app owns this folder.
    if [ -f "$dst_compose" ] && [ ! -f "$marker" ]; then
        log_warn "Skipping '$app_name': $dst_compose exists but is not a mirror (Maison-native app?)"
        conflict_count=$((conflict_count + 1))
        continue
    fi

    mkdir -p "$dst_dir"

    # Preserve any pre-existing .env exactly once, before we first take the folder over.
    if [ ! -f "$marker" ] && [ -f "$dst_dir/.env" ]; then
        cp -p "$dst_dir/.env" "$dst_dir/.env.pre-maison.bak"
        log_warn "Backed up pre-existing $dst_dir/.env to .env.pre-maison.bak"
    fi

    # --- compose file (only write on change, to keep mtimes stable) ---
    if ! cmp -s "$src_compose" "$dst_compose"; then
        cp "$src_compose" "$dst_compose"
        chmod 644 "$dst_compose"
    fi

    # --- .env: the variables CasaOS injected, materialised ---
    tmp_env="$(mktemp)"
    chmod 600 "$tmp_env"
    {
        echo "# AUTO-GENERATED FILE - DO NOT EDIT"
        echo "# Mirror of the environment CasaOS injected into '$app_name' at compose-up"
        echo "# time. Written by scripts/self-check/ensure-maison-app-mirror.sh and"
        echo "# regenerated on every self-check."
        echo ""

        # An app may ship its OWN .env in its app directory, holding secrets generated
        # at install time (DB passwords, signing keys). Compose auto-loads that file
        # from the project directory, so CasaOS resolved those variables — and a mirror
        # without them renders the app with empty passwords. Merge it in.
        #
        # It goes FIRST, before the injected cocktail below, because duplicate keys in
        # a .env resolve last-wins: that reproduces CasaOS's precedence, where the
        # process environment overrode the project .env.
        if [ -f "$app_dir/.env" ]; then
            echo "# --- from ${app_dir}.env (app-owned, generated at install) ---"
            cat "$app_dir/.env"
            echo ""
        fi

        echo "# --- injected by CasaOS at compose-up (overrides the above) ---"
        # Pins the project identity independently of the directory name, so this
        # folder always acts on the SAME docker project CasaOS created.
        echo "COMPOSE_PROJECT_NAME=$app_name"
        echo "AppID=$app_name"
        echo "PUID=${PUID:-1000}"
        echo "PGID=${PGID:-1000}"
        echo "TZ=$M_TZ"
        echo ""
        echo "# (deprecated) V1"
        echo "default_pwd=$M_DEFAULT_PWD"
        echo "public_ip=$M_PUBLIC_IPV4"
        echo "domain=$M_DOMAIN"
        echo ""
        echo "# (deprecated) V2"
        echo "PCS_DEFAULT_PASSWORD=$M_DEFAULT_PWD"
        echo "PCS_DOMAIN=$M_DOMAIN"
        echo "PCS_DATA_ROOT=${DATA_ROOT:-/DATA}"
        echo "PCS_PUBLIC_IP=$M_PUBLIC_IPV4"
        echo "PCS_PUBLIC_IPV6=$M_PUBLIC_IPV6"
        echo "PCS_EMAIL=$M_EMAIL"
        echo ""
        echo "# V3"
        echo "APP_DEFAULT_PASSWORD=$M_DEFAULT_PWD"
        echo "APP_DOMAIN=$M_DOMAIN"
        echo "APP_DATA_ROOT=${DATA_ROOT:-/DATA}"
        echo "APP_PUBLIC_IP=$M_PUBLIC_IPV6"
        echo "APP_PUBLIC_IP_DASH=$M_PUBLIC_IP_DASH"
        echo "APP_PUBLIC_IPV4=$M_PUBLIC_IPV4"
        echo "APP_PUBLIC_IPV4_DASH=$M_PUBLIC_IPV4_DASH"
        echo "APP_PUBLIC_IPV6=$M_PUBLIC_IPV6"
        echo "APP_PUBLIC_IPV6_DASH=$M_PUBLIC_IPV6_DASH"
        echo "APP_EMAIL=$M_EMAIL"
        echo "APP_NET=pcs"
    } > "$tmp_env"

    if ! cmp -s "$tmp_env" "$dst_dir/.env"; then
        mv "$tmp_env" "$dst_dir/.env"
        chmod 600 "$dst_dir/.env"
    else
        rm -f "$tmp_env"
    fi

    echo "mirrored by ensure-maison-app-mirror.sh" > "$marker"

    # Keep the mirrored files readable by the maison container (PUID/PGID).
    chown "${PUID:-1000}:${PGID:-1000}" "$dst_compose" "$dst_dir/.env" "$marker" 2>/dev/null || true

    # --- verification: both sides must render identically ---
    # Capture rather than diff <(…) directly: a compose that fails to render produces
    # EMPTY output, and two empty renders compare equal — a vacuous pass. Some apps
    # genuinely don't render (they reference variables nobody injects); that is
    # pre-existing behaviour, so it is reported as unverifiable rather than as drift.
    # But an empty mirror render against a good source render is a real failure.
    casaos_render="$(render_as_casaos "$src_compose" "$app_name" "$app_dir" || true)"
    mirror_render="$(render_from_dotenv "$dst_dir" || true)"

    if [ -z "$casaos_render" ] && [ -z "$mirror_render" ]; then
        log_warn "Cannot verify '$app_name': neither side renders this compose"
        unverified_count=$((unverified_count + 1))
    elif [ "$casaos_render" != "$mirror_render" ]; then
        drifted_apps+=("$app_name")
    fi

    mirrored_count=$((mirrored_count + 1))
done

echo "Maison mirror: $mirrored_count mirrored, $skipped_count skipped, $conflict_count conflicts, $unverified_count unverifiable, ${#drifted_apps[@]} drifted"

if [ "${#drifted_apps[@]}" -gt 0 ]; then
    # The mirrored folder does NOT render the same compose as the source. Managing
    # this app from Maison would produce a different container spec. Surface it.
    for app in "${drifted_apps[@]}"; do
        echo "MIRROR_DRIFT: $app: mirrored render differs from source render"
    done
    exit 1
fi

exit 0
