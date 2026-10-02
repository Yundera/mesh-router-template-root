#!/bin/bash
# migrate.sh - move this box (domain, apps and data) onto another machine.
#
#   migrate.sh key                                   print this box's migration public key
#   migrate.sh preflight --to user@host [--json]     check the target, change nothing
#   migrate.sh start --to user@host [--status-url URL]
#   migrate.sh status | log [-f] | cancel
#
# Run as root on the box being migrated away from (the SOURCE). The design and
# the reasons behind it are in doc/migration.md; the short version:
#
# THE SOURCE DRIVES IT. The box that owns the data, the identity and the running
# apps decides when to stop them, and rolling back is local. `start` launches the
# pipeline as a transient systemd unit (mesh-migrate) and returns, so neither an
# SSH session nor the mesh-console container is needed while it runs.
#
# NOTHING IS RUN ON THE TARGET TO PREPARE IT. The target is any Ubuntu machine the
# user (or an operator) already put in the required state: an account that accepts
# this box's migration key (`migrate.sh key`) and has passwordless sudo, rsync, the
# disk space, and no box on it yet. `preflight` checks all of it and changes nothing.
#
# IDENTITY TRAVELS WITH THE DATA. PROVIDER_STR is in the mesh .env, so copying
# DATA_ROOT is the identity transfer. The cutover is a routing problem: the source's
# agent and tunnel must go silent before the target's publish. MESH_ROUTING_HOLD
# (honoured by ensure-stack-up.sh) keeps the target off the domain while it is
# brought up and checked, and keeps the source off it after: `retired:<ip>`.
#
# KNOBS (mesh .env):
#   PLATFORM_PROJECTS          the AppData folders that are platform, not user apps
#   MIGRATE_TARGET_SELF_CHECK  a second self-check to run on the target after the
#                              mesh one (an operator's own template)
#   MIGRATE_HOLD_LOCKS         extra flock files to hold for the whole run, so an
#                              operator's own nightly self-check skips meanwhile
#
# STATE: $MESH_ROOT/data/migrate/ - the key, status.json, migrate.log, the cancel
# flag. Never copied to the target; the log and final status are, at the end, under
# data/migrate/arrived/.
#
# Exit: 0 ok, 1 failed (see the log), 2 bad arguments, 75 a migration is already
# running.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

usage() {
    sed -n '3,8p' "$SELF" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

TARGET="" STATUS_URL="" RUN_ID="" JSON=0 FOLLOW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --to)          TARGET="${2:-}"; shift 2 ;;
        --status-url)  STATUS_URL="${2:-}"; shift 2 ;;
        --id)          RUN_ID="${2:-}"; shift 2 ;;
        --json)        JSON=1; shift ;;
        -f|--follow)   FOLLOW=1; shift ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

# Same rules as mesh-console validates with: a POSIX user name, then a hostname
# or an IP (IPv6 bare or bracketed). No shell metacharacters reach ssh or rsync.
TARGET_USER="" TARGET_HOST=""
parse_target() {
    if ! [[ "$TARGET" =~ ^([a-z_][a-z0-9_-]{0,31})@(\[?[0-9a-fA-F:]+\]?|[a-zA-Z0-9][a-zA-Z0-9.-]{0,252})$ ]]; then
        echo "invalid target: '$TARGET' (expected user@host)" >&2
        exit 2
    fi
    TARGET_USER="${BASH_REMATCH[1]}"
    TARGET_HOST="${BASH_REMATCH[2]#[}"
    TARGET_HOST="${TARGET_HOST%]}"
}
if [ -n "$STATUS_URL" ] && ! [[ "$STATUS_URL" =~ ^https://[^[:space:]\"\'\`\$\\]+$ ]]; then
    echo "invalid status URL: must be https:// with no spaces or quotes" >&2
    exit 2
fi
if [ -n "$RUN_ID" ] && ! [[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    echo "invalid id: '$RUN_ID'" >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "migrate.sh must be run as root" >&2
    exit 1
fi

# shellcheck disable=SC1091
source "$(cd "$(dirname "$SELF")/.." && pwd)/library/common.sh"

MIG_DIR="$MESH_ROOT/data/migrate"
KEY="$MIG_DIR/id_ed25519"
STATUS_FILE="$MIG_DIR/status.json"
CANCEL_FILE="$MIG_DIR/cancel"
KNOWN_HOSTS="$MIG_DIR/known_hosts"
UNIT="mesh-migrate"
PLATFORM="${PLATFORM_PROJECTS:-mesh,auth,maison,terminal}"
# mesh-console reads this directory through its read-only /mesh mount: world-
# readable, except the private key.
mkdir -p "$MIG_DIR"
chmod 755 "$MIG_DIR"
LOG_FILE="$MIG_DIR/migrate.log"

SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
          -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN_HOSTS"
          -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

# =============================================================================
# Small helpers
# =============================================================================

is_platform() { [[ ",$PLATFORM," == *",$1,"* ]]; }

# The user apps on this box: AppData folders with a compose file that are not
# platform stacks.
user_apps() {
    local f name
    for f in "${DATA_ROOT:-/DATA}"/AppData/*/docker-compose.yml; do
        [ -f "$f" ] || continue
        name="$(basename "$(dirname "$f")")"
        is_platform "$name" || echo "$name"
    done
}

ensure_key() {
    if [ ! -s "$KEY" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "mesh-migrate@${DOMAIN:-$(hostname)}" -f "$KEY"
    fi
    chmod 600 "$KEY"
    chmod 644 "$KEY.pub"
}

json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"
    s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
    printf '"%s"' "$s"
}
json_or_null() { if [ -n "$1" ]; then json_str "$1"; else printf 'null'; fi; }
now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Run a command, mirroring each output line to the migration log as OUTPUT, the
# way execute_script_with_logging does for self-check steps.
run_logged() {
    "$@" 2>&1 | while IFS= read -r line; do
        echo "$line"
        log_to_file_only "OUTPUT" "$line"
    done
    return "${PIPESTATUS[0]}"
}

rsync_host() { if [[ "$TARGET_HOST" == *:* ]]; then echo "[$TARGET_HOST]"; else echo "$TARGET_HOST"; fi; }
curl_host()  { if [[ "$1" == *:* ]]; then echo "[$1]"; else echo "$1"; fi; }

# ssh_target <timeout> <remote command...> - stdin is passed through. Transient
# connection failures are retried (8 x 10s): fresh cloud VMs reboot right after
# provisioning, and a long migration can see a blip. An authentication refusal or
# a changed host key is final, never retried.
ssh_target() {
    local t="$1"; shift
    local input attempt rc errf="$MIG_DIR/ssh.err"
    input="$(cat)"
    for attempt in 1 2 3 4 5 6 7 8; do
        rc=0
        timeout "$t" ssh "${SSH_OPTS[@]}" "$TARGET_USER@$TARGET_HOST" "$@" <<<"$input" 2>"$errf" || rc=$?
        cat "$errf" >&2
        [ "$rc" -eq 255 ] || return "$rc"
        if grep -qiE 'permission denied|identification has changed|host key verification failed' "$errf" \
            || ! grep -qiE 'connection refused|timed out|connection reset|closed by|kex_exchange_identification|no route to host|host is down|broken pipe|connection lost' "$errf"; then
            return "$rc"
        fi
        [ "$attempt" -lt 8 ] && { echo "SSH to $TARGET_HOST failed (attempt $attempt/8), retrying in 10s" >&2; sleep 10; }
    done
    return "$rc"
}

# remote_fn <timeout> <function> [args...] - run one of the r_* functions below as
# root on the target. The function travels as source on stdin and the arguments
# as quoted words, so nothing is expanded by the remote login shell.
remote_fn() {
    local t="$1" fn="$2"; shift 2
    local argv=""
    [ $# -eq 0 ] || argv="$(printf '%q ' "$@")"
    printf '%s\n%s "$@"\n' "$(declare -f "$fn")" "$fn" | ssh_target "$t" "sudo -n bash -s -- $argv"
}

# remote_cmd <timeout> <argv...> - one plain command as root on the target.
remote_cmd() {
    local t="$1"; shift
    ssh_target "$t" "sudo -n $(printf '%q ' "$@")" </dev/null
}

# =============================================================================
# Functions run ON THE TARGET (self-contained: they travel by `declare -f`). The
# same ones run locally where the source needs the same action.
# =============================================================================

# Facts preflight needs, as key=value lines.
r_probe() {
    local data_root="$1" d entries
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    echo "os=${ID:-unknown}"
    echo "os_version=${VERSION_ID:-}"
    echo "arch=$(uname -m)"
    if command -v rsync >/dev/null 2>&1; then echo "rsync=yes"; else echo "rsync=no"; fi
    entries="$(ls -A "$data_root/AppData" 2>/dev/null | head -5 | tr '\n' ' ')"
    echo "appdata=$entries"
    d="$data_root"
    while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
    echo "avail=$(df -B1 --output=avail "$d" | tail -n1 | tr -d ' ')"
    echo "epoch=$(date +%s)"
}

# Install Docker from the copied template, then pull every project's images
# while the source still serves. Pull failures are reported, not fatal: the app
# is retried at start and reported there.
r_prepare() {
    local scripts="$1" data_root="$2" f name
    bash "$scripts/self-check/ensure-docker-installed.sh" || return 1
    for f in "$data_root"/AppData/*/docker-compose.yml; do
        [ -f "$f" ] || continue
        name="$(basename "$(dirname "$f")")"
        echo "Pulling $name"
        (cd "$(dirname "$f")" && timeout 900 docker compose pull -q) || echo "WARN: pull failed for $name"
    done
}

# Set the routing hold and take agent + tunnel off the domain.
r_hold() {
    local scripts="$1" env_file="$2" app_dir="$3" value="$4"
    bash "$scripts/tools/env-file-manager.sh" set MESH_ROUTING_HOLD "$value" "$env_file" >/dev/null || return 1
    (cd "$app_dir" && docker compose rm -sf mesh-router-agent mesh-router-tunnel)
}

# Lift the routing hold and bring agent + tunnel back.
r_release() {
    local scripts="$1" env_file="$2"
    bash "$scripts/tools/env-file-manager.sh" delete MESH_ROUTING_HOLD "$env_file" >/dev/null || return 1
    bash "$scripts/self-check/ensure-stack-up.sh"
}

# Bring the target up with the routing hold set: the mesh self-check (Docker,
# public IP, every platform stack), then the operator's own self-check if any.
r_target_up() {
    local scripts="$1" env_file="$2" hold="$3" box_check="$4" log_file="$5" rc=0
    bash "$scripts/tools/env-file-manager.sh" set MESH_ROUTING_HOLD "$hold" "$env_file" >/dev/null || return 1
    bash "$scripts/self-check.sh" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$box_check" ]; then
        bash "$box_check" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "--- last lines of $log_file on the target ---"
        tail -n 60 "$log_file" 2>/dev/null || true
    fi
    return "$rc"
}

# Start every user app; one FAILED_APP line per app that did not come up.
r_start_apps() {
    local data_root="$1" platform="$2" f name out
    for f in "$data_root"/AppData/*/docker-compose.yml; do
        [ -f "$f" ] || continue
        name="$(basename "$(dirname "$f")")"
        [[ ",$platform," == *",$name,"* ]] && continue
        if ! out="$(cd "$(dirname "$f")" && docker compose up -d 2>&1)"; then
            echo "FAILED_APP: $name: $(echo "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-200)"
        fi
    done
    return 0
}

r_env_get() { bash "$1/tools/env-file-manager.sh" get "$3" "$2"; }

r_create_volume() {
    local name="$1" project="$2" short="$3"
    docker volume inspect "$name" >/dev/null 2>&1 \
        || docker volume create --label "com.docker.compose.project=$project" \
                                --label "com.docker.compose.volume=$short" "$name" >/dev/null
    docker volume inspect -f '{{.Mountpoint}}' "$name"
}

# =============================================================================
# Preflight
# =============================================================================

CHECK_NAMES=() CHECK_STATES=() CHECK_MSGS=()
check() { CHECK_NAMES+=("$1"); CHECK_STATES+=("$2"); CHECK_MSGS+=("$3"); }

run_preflight() {
    CHECK_NAMES=() CHECK_STATES=() CHECK_MSGS=()
    local os="" ver="" out key val used need
    local -A T=()

    # shellcheck disable=SC1091
    os="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
    ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
    if [ "$os" = "ubuntu" ]; then check source_os ok "Ubuntu $ver"
    else check source_os fail "This box runs '$os'; only Ubuntu is supported"; fi

    # common.sh keeps the .env at /DATA/AppData/mesh whatever DATA_ROOT says; a
    # box whose data root is elsewhere would not carry its identity in the copy.
    if [ "$APP_DIR" = "$MESH_ROOT" ]; then check source_layout ok "Data root ${DATA_ROOT:-/DATA}"
    else check source_layout fail "The mesh .env ($APP_DIR) is outside the data root ($MESH_ROOT); not supported"; fi

    local missing=""
    for key in rsync yq curl systemd-run ssh; do command -v "$key" >/dev/null 2>&1 || missing+=" $key"; done
    if [ -z "$missing" ]; then check source_tools ok "rsync, yq, curl, systemd-run, ssh"
    else check source_tools fail "Missing on this box:$missing"; fi

    case "$(get_env_value MESH_ROUTING_HOLD)" in
        retired:*) check source_state fail "This box is retired ($(get_env_value MESH_ROUTING_HOLD)); remove MESH_ROUTING_HOLD first to migrate it again" ;;
        "")        check source_state ok "Serving" ;;
        *)         check source_state warn "Routing is held ($(get_env_value MESH_ROUTING_HOLD))" ;;
    esac

    if [ ! -s "$KEY" ]; then
        check key fail "No migration key yet: run 'migrate.sh key' and authorize it on the target"
        return
    fi
    check key ok "$(cut -d' ' -f1,3 "$KEY.pub")"

    # Target IPs are recycled by cloud providers: pin the host key per run.
    rm -f "$KNOWN_HOSTS"
    if ! out="$(ssh_target 30 true 2>&1 </dev/null)"; then
        if [[ "$out" == *"Permission denied"* ]]; then
            check target_ssh fail "$TARGET_USER@$TARGET_HOST does not accept this box's migration key"
        else
            check target_ssh fail "Cannot reach $TARGET_USER@$TARGET_HOST over SSH: $(echo "$out" | tail -n1)"
        fi
        return
    fi
    check target_ssh ok "Key accepted by $TARGET_USER@$TARGET_HOST"

    if ! ssh_target 30 sudo -n true </dev/null >/dev/null 2>&1; then
        check target_sudo fail "$TARGET_USER has no passwordless sudo on the target"
        return
    fi
    check target_sudo ok "Passwordless sudo"

    if ! out="$(remote_fn 60 r_probe "${DATA_ROOT:-/DATA}" 2>/dev/null)"; then
        check target_probe fail "Could not inspect the target"
        return
    fi
    while IFS='=' read -r key val; do [ -n "$key" ] && T[$key]="$val"; done <<<"$out"

    if [ "${T[os]:-}" = "ubuntu" ]; then
        if [ "${T[os_version]:-}" = "$ver" ]; then check target_os ok "Ubuntu ${T[os_version]}"
        else check target_os warn "Ubuntu ${T[os_version]:-?} (this box: $ver)"; fi
    else
        check target_os fail "The target runs '${T[os]:-unknown}'; only Ubuntu is supported"
    fi

    if [ "${T[arch]:-}" = "$(uname -m)" ]; then check target_arch ok "${T[arch]}"
    else check target_arch warn "${T[arch]:-?} (this box: $(uname -m)): images are re-pulled, apps without one for that architecture will not start"; fi

    if [ "${T[rsync]:-}" = "yes" ]; then check target_rsync ok "rsync installed"
    else check target_rsync fail "rsync is not installed on the target (apt-get install rsync)"; fi

    if [ -z "${T[appdata]// /}" ]; then check target_empty ok "No box on the target"
    else check target_empty fail "${DATA_ROOT:-/DATA}/AppData on the target is not empty (${T[appdata]}); a migration never overwrites a box"; fi

    # df used, never du: du on a large tree takes longer than any timeout. It
    # counts the OS and Docker images too, which the target needs as well.
    used="$(df -B1 --output=used "${DATA_ROOT:-/DATA}" | tail -n1 | tr -d ' ')"
    need=$(( used + 5 * 1024 * 1024 * 1024 ))
    if [ "${T[avail]:-0}" -ge "$need" ]; then
        check target_disk ok "$(( T[avail] / 1073741824 )) GiB free, about $(( need / 1073741824 )) GiB needed"
    else
        check target_disk fail "$(( ${T[avail]:-0} / 1073741824 )) GiB free on the target, about $(( need / 1073741824 )) GiB needed"
    fi

    local skew=$(( ${T[epoch]:-0} - $(date +%s) )); skew=${skew#-}
    if [ "$skew" -lt 60 ]; then check target_clock ok "Clocks agree (${skew}s)"
    else check target_clock fail "Clocks differ by ${skew}s; fix NTP on one of the boxes"; fi
}

preflight_failed() {
    local s
    for s in "${CHECK_STATES[@]}"; do [ "$s" = "fail" ] && return 0; done
    return 1
}

print_preflight() {
    local i
    if [ "$JSON" -eq 1 ]; then
        printf '{"ok":%s,"target":%s,"checks":[' "$(preflight_failed && echo false || echo true)" "$(json_str "$TARGET")"
        for i in "${!CHECK_NAMES[@]}"; do
            [ "$i" -gt 0 ] && printf ','
            printf '{"name":%s,"status":%s,"message":%s}' \
                "$(json_str "${CHECK_NAMES[$i]}")" "$(json_str "${CHECK_STATES[$i]}")" "$(json_str "${CHECK_MSGS[$i]}")"
        done
        printf ']}\n'
    else
        for i in "${!CHECK_NAMES[@]}"; do
            printf '%-5s %-14s %s\n' "$(echo "${CHECK_STATES[$i]}" | tr a-z A-Z)" "${CHECK_NAMES[$i]}" "${CHECK_MSGS[$i]}"
        done
    fi
}

# =============================================================================
# Status (status.json - the one state format: terminal, mesh-console, push)
# =============================================================================

STEPS=(preflight online_copy prepare_target stop_apps offline_copy target_up start_apps verify_target cutover verify_domain retire)
declare -A STEP_LABEL=(
    [preflight]="Check this box and the target"
    [online_copy]="Copy data (apps online)"
    [prepare_target]="Install Docker and pull images on the target"
    [stop_apps]="Stop apps on this box"
    [offline_copy]="Copy changes and volumes (apps stopped)"
    [target_up]="Bring the target up, off the domain"
    [start_apps]="Start apps on the target"
    [verify_target]="Check the target answers"
    [cutover]="Move the domain to the target"
    [verify_domain]="Check the domain reaches the target"
    [retire]="Retire this box"
)
# Who serves the apps while the step runs: this box, nobody, or the target.
declare -A STEP_GROUP=(
    [preflight]=source [online_copy]=source [prepare_target]=source
    [stop_apps]=down [offline_copy]=down [target_up]=down [start_apps]=down
    [verify_target]=down [cutover]=down
    [verify_domain]=target [retire]=target
)
declare -A STEP_STATUS=() STEP_START=() STEP_END=() STEP_MSG=()
for s in "${STEPS[@]}"; do STEP_STATUS[$s]=pending; done
PHASE="starting" ERROR="" STARTED_AT="" FINISHED_AT="" SOURCE_IP="${PUBLIC_IP:-}"
COPY_BYTES=0 COPY_PERCENT=0 COPY_RATE="" COPY_ETA=""

write_status() {
    local tmp="$STATUS_FILE.tmp.$$" s first=1
    {
        printf '{"version":1,"id":%s,"phase":%s,"startedAt":%s,"finishedAt":%s,' \
            "$(json_str "$RUN_ID")" "$(json_str "$PHASE")" "$(json_or_null "$STARTED_AT")" "$(json_or_null "$FINISHED_AT")"
        printf '"source":{"ip":%s,"domain":%s},"target":{"host":%s,"user":%s},' \
            "$(json_or_null "$SOURCE_IP")" "$(json_or_null "${DOMAIN:-}")" "$(json_str "$TARGET_HOST")" "$(json_str "$TARGET_USER")"
        printf '"steps":['
        for s in "${STEPS[@]}"; do
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"key":%s,"label":%s,"group":%s,"status":%s,"startedAt":%s,"finishedAt":%s,"message":%s}' \
                "$(json_str "$s")" "$(json_str "${STEP_LABEL[$s]}")" "$(json_str "${STEP_GROUP[$s]}")" \
                "$(json_str "${STEP_STATUS[$s]}")" "$(json_or_null "${STEP_START[$s]:-}")" \
                "$(json_or_null "${STEP_END[$s]:-}")" "$(json_or_null "${STEP_MSG[$s]:-}")"
        done
        printf '],"copy":{"bytes":%s,"percent":%s,"rate":%s,"eta":%s},' \
            "$COPY_BYTES" "$COPY_PERCENT" "$(json_or_null "$COPY_RATE")" "$(json_or_null "$COPY_ETA")"
        printf '"error":%s,"updatedAt":%s}\n' "$(json_or_null "$ERROR")" "$(json_str "$(now_iso)")"
    } >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

# =============================================================================
# Pipeline (`run`, inside the mesh-migrate unit)
# =============================================================================

STEP_ERROR="" CANCELLED=0 APPS_STOPPED=0 CUTOVER_STARTED=0
TARGET_IP="" TARGET_IP_DASH="" PUSH_PID=""

fail() { STEP_ERROR="$1"; log_error "$1"; return 1; }

check_cancel() {
    if [ -f "$CANCEL_FILE" ]; then
        CANCELLED=1
        fail "Cancelled"
        return 1
    fi
}

# rsync_copy <extra rsync args...> - DATA_ROOT to the same path on the target.
#   -x            never cross into another filesystem (FUSE, NFS, bind mounts)
#   --numeric-ids ownership by number: the target has no matching user names yet
#   exit 24       files vanished while copying - normal with apps still running
# Progress (--info=progress2) feeds status.json every 2s; a cancel kills rsync.
rsync_copy() {
    local step="$1"; shift
    local out="$MIG_DIR/rsync.out" err="$MIG_DIR/rsync.err" pid rc line
    remote_cmd 60 mkdir -p "${DATA_ROOT:-/DATA}" >/dev/null 2>&1 || true
    : >"$out"
    (
        exec rsync -aHAXS -x --numeric-ids --partial --info=progress2,stats2 \
            --rsync-path='sudo -n rsync' -e "ssh ${SSH_OPTS[*]}" \
            --exclude='/AppData/mesh/data/migrate/' "$@" \
            "${DATA_ROOT:-/DATA}/" "$TARGET_USER@$(rsync_host):${DATA_ROOT:-/DATA}/"
    ) >"$out" 2>"$err" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ -f "$CANCEL_FILE" ]; then kill "$pid" 2>/dev/null || true; fi
        line="$(tail -c 2048 "$out" | tr '\r' '\n' | grep -E '^ *[0-9,]+ +[0-9]+% ' | tail -n1 || true)"
        if [[ "$line" =~ ^\ *([0-9,]+)\ +([0-9]+)%\ +([^ ]+)\ +([0-9]+:[0-9]{2}:[0-9]{2}) ]]; then
            COPY_BYTES="${BASH_REMATCH[1]//,/}" COPY_PERCENT="${BASH_REMATCH[2]}"
            COPY_RATE="${BASH_REMATCH[3]}" COPY_ETA="${BASH_REMATCH[4]}"
            STEP_MSG[$step]="$(( COPY_BYTES / 1048576 )) MiB copied, ${COPY_PERCENT}%"
            write_status
        fi
        sleep 2
    done
    rc=0; wait "$pid" || rc=$?
    tr '\r' '\n' <"$out" | grep -vE '^ *[0-9,]+ +[0-9]+% ' | while IFS= read -r line; do
        [ -n "$line" ] && log_to_file_only "OUTPUT" "$line"
    done
    check_cancel || return 1
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
        fail "rsync failed (exit $rc): $(tail -c 600 "$err" | tr '\n' ' ')"
        return 1
    fi
    line="$(grep -E '^Total transferred file size' "$out" | grep -oE '[0-9][0-9,]*' | head -n1 | tr -d ',' || true)"
    STEP_MSG[$step]="$(( ${line:-0} / 1048576 )) MiB transferred"
}

step_preflight() {
    run_preflight
    local i warn=""
    for i in "${!CHECK_NAMES[@]}"; do
        log_to_file_only "OUTPUT" "${CHECK_STATES[$i]} ${CHECK_NAMES[$i]}: ${CHECK_MSGS[$i]}"
        case "${CHECK_STATES[$i]}" in
            fail) fail "${CHECK_NAMES[$i]}: ${CHECK_MSGS[$i]}"; return 1 ;;
            warn) warn+="${CHECK_MSGS[$i]}; " ;;
        esac
    done
    STEP_MSG[preflight]="${warn:-All checks passed}"
}

step_online_copy() { rsync_copy online_copy; }

step_prepare_target() {
    run_logged remote_fn 1800 r_prepare "$SCRIPTS_DIR" "${DATA_ROOT:-/DATA}" \
        || fail "Could not install Docker on the target" || return
}

step_stop_apps() {
    local app
    APPS_STOPPED=1
    for app in $(user_apps); do
        run_logged bash -c 'cd "$1" && docker compose stop' _ "${DATA_ROOT:-/DATA}/AppData/$app" \
            || fail "Could not stop $app" || return
    done
}

# Named volumes of the user apps (compose-labelled, local driver, no driver
# options - an NFS or bind-backed volume is the app's own business). Streamed by
# host tar between the two Mountpoints: works whatever Docker's data-root, and
# needs no image pull.
step_offline_copy() {
    rsync_copy offline_copy --delete || return 1
    local name driver project short opts src dst n=0
    while IFS='|' read -r name driver project short opts; do
        [ -n "$name" ] || continue
        [ "$driver" = "local" ] || continue
        [ "$opts" = "null" ] || [ "$opts" = "{}" ] || continue
        is_platform "$project" && continue
        check_cancel || return 1
        src="$(docker volume inspect -f '{{.Mountpoint}}' "$name")"
        dst="$(remote_fn 60 r_create_volume "$name" "$project" "$short" </dev/null)" \
            || fail "Could not create volume $name on the target" || return
        log_info "Copying volume $name"
        tar -C "$src" --numeric-owner --xattrs --acls -cpf - . \
            | ssh "${SSH_OPTS[@]}" "$TARGET_USER@$TARGET_HOST" \
                "sudo -n tar -C $(printf '%q' "$dst") --numeric-owner --xattrs --acls -xpf -" \
            || fail "Could not copy volume $name" || return
        n=$((n + 1))
    done < <(docker volume ls -q --filter label=com.docker.compose.project \
             | xargs -r docker volume inspect -f '{{.Name}}|{{.Driver}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.volume"}}|{{json .Options}}')
    STEP_MSG[offline_copy]="Data and $n volume(s) copied"
}

step_target_up() {
    run_logged remote_fn 2400 r_target_up "$SCRIPTS_DIR" "$ENV_FILE" "migrating:$RUN_ID" \
        "${MIGRATE_TARGET_SELF_CHECK:-}" "$MESH_ROOT/log/mesh.log" \
        || fail "The target's self-check failed (see the log)" || return
    TARGET_IP="$(remote_fn 60 r_env_get "$SCRIPTS_DIR" "$ENV_FILE" PUBLIC_IP </dev/null)"
    TARGET_IP_DASH="$(remote_fn 60 r_env_get "$SCRIPTS_DIR" "$ENV_FILE" PUBLIC_IP_DASH </dev/null)"
    [ -n "$TARGET_IP" ] && [ -n "$TARGET_IP_DASH" ] \
        || fail "The target has no PUBLIC_IP after its self-check" || return
    STEP_MSG[target_up]="Target up at $TARGET_IP"
}

step_start_apps() {
    local out failed
    out="$(remote_fn 1800 r_start_apps "${DATA_ROOT:-/DATA}" "$PLATFORM" </dev/null 2>&1)" \
        || fail "Could not start the apps on the target" || return
    while IFS= read -r line; do log_to_file_only "OUTPUT" "$line"; done <<<"$out"
    failed="$(grep '^FAILED_APP: ' <<<"$out" | cut -d' ' -f2 | tr -d ':' | xargs || true)"
    STEP_MSG[start_apps]="${failed:+Did not start: $failed}"
    [ -n "$failed" ] && log_warn "Apps that did not start on the target: $failed"
    return 0
}

# The target's own name, before any cutover: mesh-console's public health
# endpoint through Caddy on <ip-dash>.nip.io (the mesh CA's certificate, hence -k).
step_verify_target() {
    local host="mesh-console-$TARGET_IP_DASH.nip.io" i
    for i in $(seq 1 30); do
        if curl -fsSk --max-time 10 --resolve "$host:443:$(curl_host "$TARGET_IP")" \
            "https://$host/api/health" >/dev/null 2>&1; then
            STEP_MSG[verify_target]="mesh-console answers on the target"
            return 0
        fi
        check_cancel || return 1
        sleep 10
    done
    fail "The target does not answer on https://$host/api/health"
}

# The source goes silent first, its routes are dropped from the backend (signed
# with its own PROVIDER_STR - the same identity the target is about to use), then
# the target lifts its hold and publishes.
step_cutover() {
    local backend user_id sig
    CUTOVER_STARTED=1
    run_logged r_hold "$SCRIPTS_DIR" "$ENV_FILE" "$APP_DIR" "migrating:$RUN_ID" \
        || fail "Could not take this box off the domain" || return
    IFS=',' read -r backend user_id sig <<<"$PROVIDER_STR"
    curl -fsS --max-time 15 -X DELETE "${backend%/}/router/api/routes/$user_id/$sig" >/dev/null 2>&1 \
        || log_warn "Could not drop this box's routes from the backend; they expire on their own"
    run_logged remote_fn 900 r_release "$SCRIPTS_DIR" "$ENV_FILE" </dev/null \
        || fail "The target could not bring its routing up" || return
}

step_verify_domain() {
    local backend user_id sig routes agent other i
    IFS=',' read -r backend user_id sig <<<"$PROVIDER_STR"
    for i in $(seq 1 30); do
        check_cancel || return 1
        routes="$(curl -fsS --max-time 10 "${backend%/}/router/api/routes/$user_id" 2>/dev/null || true)"
        agent="$(yq -p=json -o=tsv '.routes[] | select(.source == "agent") | [(.ip // ""), (.domain // "")]' <<<"$routes" 2>/dev/null || true)"
        other="$(grep -vF -e "$TARGET_IP" -e "$TARGET_IP_DASH" <<<"$agent" | grep -v '^\s*$' || true)"
        if [ -n "$agent" ] && [ -z "$other" ] \
            && curl -fsS --max-time 10 "https://mesh-console-$DOMAIN/api/health" >/dev/null 2>&1; then
            STEP_MSG[verify_domain]="$DOMAIN is served by $TARGET_IP"
            return 0
        fi
        sleep 10
    done
    fail "$DOMAIN does not reach the target after 5 minutes"
}

step_retire() {
    run_logged bash "$ENV_MGR" set MESH_ROUTING_HOLD "retired:$TARGET_IP" "$ENV_FILE" \
        || fail "Could not mark this box retired" || return
    STEP_MSG[retire]="Retired: $DOMAIN is now served by $TARGET_IP"
}

rollback() {
    log_warn "Rolling back"
    PHASE="rolling_back"; write_status
    local ok=1
    if [ "$CUTOVER_STARTED" -eq 1 ]; then
        run_logged remote_fn 300 r_hold "$SCRIPTS_DIR" "$ENV_FILE" "$APP_DIR" "migrating:$RUN_ID" </dev/null \
            || { ok=0; log_error "Could not take the target off the domain - it may still publish"; }
        run_logged r_release "$SCRIPTS_DIR" "$ENV_FILE" \
            || { ok=0; log_error "Could not bring this box's routing back up"; }
    fi
    if [ "$APPS_STOPPED" -eq 1 ]; then
        run_logged r_start_apps "${DATA_ROOT:-/DATA}" "$PLATFORM" || ok=0
    fi
    [ "$ok" -eq 1 ]
}

push_loop() {
    local last="" cur n=0
    while :; do
        cur="$(stat -c '%Y.%s' "$STATUS_FILE" 2>/dev/null || true)"
        if [ "$cur" != "$last" ] || [ "$n" -ge 5 ]; then
            curl -fsS --max-time 8 --proto '=https' -H 'Content-Type: application/json' \
                --data-binary @"$STATUS_FILE" "$STATUS_URL" >/dev/null 2>&1 || true
            last="$cur"; n=0
        fi
        n=$((n + 1))
        sleep 3
    done
}

finish() {
    FINISHED_AT="$(now_iso)"
    write_status
    if [ -n "$PUSH_PID" ]; then
        kill "$PUSH_PID" 2>/dev/null || true
        curl -fsS --max-time 8 --proto '=https' -H 'Content-Type: application/json' \
            --data-binary @"$STATUS_FILE" "$STATUS_URL" >/dev/null 2>&1 || true
    fi
    if [ "$PHASE" = "done" ]; then
        # The target keeps the record of how it arrived.
        remote_cmd 60 mkdir -p "$MIG_DIR/arrived" >/dev/null 2>&1 \
            && tar -C "$MIG_DIR" -cf - migrate.log status.json \
               | ssh "${SSH_OPTS[@]}" "$TARGET_USER@$TARGET_HOST" "sudo -n tar -C $(printf '%q' "$MIG_DIR/arrived") -xf -" \
            || log_warn "Could not copy the migration record to the target"
        log_success "=== Migration completed successfully ==="
    else
        log_error "=== Migration completed with failures ==="
    fi
}

cmd_run() {
    parse_target
    [ -n "$RUN_ID" ] || { echo "run needs --id" >&2; exit 2; }
    set +e
    STARTED_AT="$(now_iso)"
    PHASE="running"
    log_info "=== Migration starting ($RUN_ID: ${DOMAIN:-this box} to $TARGET_USER@$TARGET_HOST) ==="
    write_status

    # The self-check would restart what this run stops: hold its lock (and the
    # operator's) for the whole run. A self-check already running is waited for.
    local lock fd
    exec 200>"/var/run/mesh-self-check.lock"
    if ! flock -w 1800 200; then
        ERROR="A self-check has held the lock for 30 minutes" PHASE="failed"
        finish; exit 1
    fi
    IFS=',' read -ra extra_locks <<<"${MIGRATE_HOLD_LOCKS:-}"
    for lock in "${extra_locks[@]}"; do
        [ -n "$lock" ] || continue
        exec {fd}>"$lock"
        if ! flock -w 1800 "$fd"; then
            ERROR="$lock has been held for 30 minutes" PHASE="failed"
            finish; exit 1
        fi
    done

    [ -z "$STATUS_URL" ] || { push_loop & PUSH_PID=$!; }
    # `systemctl stop mesh-migrate` is a cancel: stop at the next safe point and
    # roll back (systemd waits 90s before it kills).
    trap 'touch "$CANCEL_FILE"' TERM INT

    local s t0 dt
    for s in "${STEPS[@]}"; do
        if ! check_cancel; then break; fi
        STEP_STATUS[$s]=running; STEP_START[$s]="$(now_iso)"; t0=$(date +%s)
        log_info "=== [$(date '+%Y-%m-%d %H:%M:%S')] $s : starting ==="
        write_status
        STEP_ERROR=""
        if "step_$s"; then
            dt=$(( $(date +%s) - t0 ))
            STEP_STATUS[$s]=success; STEP_END[$s]="$(now_iso)"
            log_success "=== [$(date '+%Y-%m-%d %H:%M:%S')] $s : success (${dt}s) ==="
            write_status
        else
            dt=$(( $(date +%s) - t0 ))
            STEP_STATUS[$s]=failed; STEP_END[$s]="$(now_iso)"; STEP_MSG[$s]="$STEP_ERROR"
            log_error "=== [$(date '+%Y-%m-%d %H:%M:%S')] $s : failed (exit code: 1, ${dt}s) ==="
            ERROR="${STEP_ERROR:-$s failed}"
            break
        fi
    done

    if [ -z "$ERROR" ] && [ "$CANCELLED" -eq 0 ]; then
        PHASE="done"
    elif [ "$APPS_STOPPED" -eq 1 ] || [ "$CUTOVER_STARTED" -eq 1 ]; then
        if rollback; then
            if [ "$CANCELLED" -eq 1 ]; then PHASE="cancelled"; else PHASE="rolled_back"; fi
        else
            PHASE="failed"; ERROR="$ERROR (rollback incomplete - see the log)"
        fi
    elif [ "$CANCELLED" -eq 1 ]; then
        PHASE="cancelled"
    else
        PHASE="failed"
    fi
    rm -f "$CANCEL_FILE"
    finish
    [ "$PHASE" = "done" ]
}

# =============================================================================
# Commands
# =============================================================================

case "$CMD" in
    key)
        ensure_key
        cat "$KEY.pub"
        ;;
    preflight)
        parse_target
        run_preflight
        print_preflight
        ! preflight_failed
        ;;
    start)
        parse_target
        if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
            echo "A migration is already running (migrate.sh status)" >&2
            exit 75
        fi
        command -v systemd-run >/dev/null 2>&1 || { echo "systemd is required to run a migration" >&2; exit 1; }
        ensure_key
        RUN_ID="$(date -u '+%Y%m%d-%H%M%S')"
        rm -f "$CANCEL_FILE"
        STARTED_AT="$(now_iso)"
        write_status
        systemd-run --quiet --collect --unit="$UNIT" /bin/bash "$SELF" run --id "$RUN_ID" --to "$TARGET" \
            ${STATUS_URL:+--status-url "$STATUS_URL"}
        echo "Migration $RUN_ID started: follow it with 'migrate.sh log -f' or in mesh-console"
        ;;
    run)
        cmd_run
        ;;
    status)
        if [ -f "$STATUS_FILE" ]; then cat "$STATUS_FILE"; else echo "No migration has run on this box" >&2; exit 1; fi
        ;;
    log)
        [ -f "$LOG_FILE" ] || { echo "No migration has run on this box" >&2; exit 1; }
        if [ "$FOLLOW" -eq 1 ]; then tail -n 100 -F "$LOG_FILE"; else tail -n 200 "$LOG_FILE"; fi
        ;;
    cancel)
        if ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
            echo "No migration is running" >&2
            exit 1
        fi
        touch "$CANCEL_FILE"
        echo "Cancel requested: the migration stops at the next safe point and rolls back"
        ;;
    *)
        usage
        ;;
esac
