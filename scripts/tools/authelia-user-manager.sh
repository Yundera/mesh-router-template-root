#!/bin/bash
# authelia-user-manager.sh - CRUD for Authelia's file-backend user store.
#
# Usage:
#   authelia-user-manager.sh list
#   authelia-user-manager.sh claim <username> [displayname]   # password on stdin
#   authelia-user-manager.sh claim --generate <username> [displayname]
#   authelia-user-manager.sh add <username> <displayname> <email> [groups-csv]
#   authelia-user-manager.sh delete <username>
#   authelia-user-manager.sh set-password <username>
#   authelia-user-manager.sh set-email <username> <email>
#
# STDOUT IS A MACHINE INTERFACE. Every subcommand prints JSON and nothing else;
# all diagnostics go to stderr. install.sh parses `claim`'s output at the end of
# an install, and anything else scripting this box can do the same.
#
#   list                    -> [{"username","displayname","email","groups":[],"disabled"}]
#   add / set-password      -> {"username","password"}   <- plaintext, shown ONCE
#   claim                   -> {"username","claimed":true[,"password"]}
#   delete / set-email      -> {"username"}
#
# Passwords are never accepted as argv and never appear in the host's process
# list: `authelia crypto hash generate argon2 --random` mints the password inside
# the container and prints both it and its digest. The CLI refuses piped stdin
# ("you must either use an interactive terminal or use the --password flag"), and
# --password would put the secret in the host's process list, so --random is the
# only way to get a hash without exposing one. It also happens to be exactly the
# behaviour we want for a generated password: shown once, never stored.
#
# Why a host script rather than editing YAML by hand: the file is 0600 and
# root-owned, Authelia rewrites it itself on password change, and the flock below
# is only meaningful on the host where the file lives. Same reasoning that put
# env mutation in env-file-manager.sh.
#
# Ported from Yundera/template-root (root/scripts/tools/authelia-user-manager.sh).
# Differences: one unified .env instead of the three-file split, mesh paths, and
# no admin-app surface — this template ships no dashboard that shells into it.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/library/common.sh"

AUTH_ROOT="$MESH_ROOT/auth"
USERS_DB="$AUTH_ROOT/users_database.yml"
LOCK_FILE="$AUTH_ROOT/.users-db.lock"

# Must stay in sync with AUTHELIA_IMAGE in self-check/ensure-authelia.sh — both
# hash with the same binary, and a version skew there would mean two different
# argon2 parameter sets in one users_database.yml.
AUTHELIA_IMAGE="authelia/authelia:4.39.25"

# The owner account. Deleting it is unrecoverable: the seed branch in
# ensure-authelia.sh is guarded by a FILE-level check (`grep -q "password:"`), so
# with any other user still present it will not re-seed, and the box is left with
# no way back in.
#
# NOT a fixed string: the owner picks their username at claim time and `claim`
# records it in LOCAL_ADMIN_USER. `admin` is the seed placeholder and the
# fallback for any box provisioned before onboarding existed. Kept in sync with
# the identical lookup in ensure-authelia.sh.
PROTECTED_USER="$(get_env_value LOCAL_ADMIN_USER 2>/dev/null || echo "")"
[ -n "$PROTECTED_USER" ] || PROTECTED_USER="admin"
ADMIN_GROUP="admins"

error() {
    echo "ERROR: $1" >&2
    exit 1
}

# --- preconditions -----------------------------------------------------------

command -v yq >/dev/null 2>&1 || error "yq not found (installed by self-check/ensure-yq-installed.sh)"
command -v docker >/dev/null 2>&1 || error "docker not found"
[ -f "$USERS_DB" ] || error "$USERS_DB does not exist; run self-check/ensure-authelia.sh first"
[ -r "$USERS_DB" ] || error "$USERS_DB is not readable (run this as root)"

# Serialise the whole read-modify-write. Authelia writes this file too, on
# password change and on the email reset flow.
mkdir -p "$AUTH_ROOT"
exec 9>"$LOCK_FILE"
flock 9 || error "Failed to acquire lock on $LOCK_FILE"

# --- helpers -----------------------------------------------------------------

# mktemp yields 0600 owned by the caller; on same-fs mv the destination inherits
# that. Capture before, restore after, so the file's mode/owner survive. Same
# idiom as env-file-manager.sh.
preserve_meta() {
    local file="$1"
    [ -e "$file" ] || { echo ""; return 0; }
    stat -c '%a:%U:%G' "$file" 2>/dev/null || echo ""
}

restore_meta() {
    local file="$1" meta="$2"
    [ -z "$meta" ] && return 0
    [ -e "$file" ] || return 0
    local mode rest owner group
    mode="${meta%%:*}"
    rest="${meta#*:}"
    owner="${rest%%:*}"
    group="${rest#*:}"
    chmod "$mode" "$file" 2>/dev/null || true
    chown "$owner:$group" "$file" 2>/dev/null || true
}

# Username becomes a YAML key AND an OIDC preferred_username, so keep it to a
# conservative charset. Leading digit rejected so yq never sees it as a number.
validate_username() {
    local u="$1"
    [ -n "$u" ] || error "username must not be empty"
    [ "${#u}" -le 32 ] || error "username must be 32 characters or fewer"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || error "invalid username '$u' (allowed: lowercase letter or underscore, then lowercase alphanumerics, '-' or '_')"
}

validate_email() {
    local e="$1"
    [ -n "$e" ] || error "email must not be empty"
    [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || error "invalid email '$e'"
}

user_exists() {
    local u="$1"
    U="$u" yq -e '.users | has(strenv(U))' "$USERS_DB" >/dev/null 2>&1
}

require_user() {
    user_exists "$1" || error "no such user: $1"
}

# Count users carrying ADMIN_GROUP, so the last one can never be removed.
admin_count() {
    G="$ADMIN_GROUP" yq '[.users[] | select((.groups // []) | contains([strenv(G)]))] | length' "$USERS_DB"
}

is_admin_user() {
    local u="$1"
    U="$u" G="$ADMIN_GROUP" yq -e '.users[strenv(U)].groups // [] | contains([strenv(G)])' "$USERS_DB" >/dev/null 2>&1
}

# Generate a password + argon2 digest inside the Authelia container. Sets the
# globals GEN_PASSWORD and GEN_DIGEST. See the header note on --random.
generate_password_and_digest() {
    local out
    out="$(docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate argon2 \
        --random --random.length 24 --random.charset alphanumeric 2>/dev/null)" \
        || error "Failed to run $AUTHELIA_IMAGE to generate a password"

    GEN_PASSWORD="$(printf '%s' "$out" | awk '/^Random Password:/{print $3}')"
    GEN_DIGEST="$(printf '%s' "$out" | awk '/^Digest:/{print $2}')"

    [ -n "$GEN_PASSWORD" ] || error "Could not parse generated password from authelia output"
    [ -n "$GEN_DIGEST" ] || error "Could not parse argon2 digest from authelia output"
}

# argon2-hash a CALLER-SUPPLIED password (the owner chooses it at claim time).
# Sets GEN_DIGEST. Reads the plaintext from $1 and never echoes it.
#
# The header explains why the other paths use --random: the Authelia CLI refuses
# piped stdin, and --password would put the secret in the HOST's process list.
# This path needs a specific password, so it hands it over as an ENVIRONMENT
# variable and expands it inside the container:
#
#   docker run -e SECRET ...       <- name only; the value comes from our env,
#                                     so it is absent from the host's argv
#   sh -c 'authelia ... "$SECRET"'  <- expansion happens in the container
#
# The plaintext is therefore never in the host command line, never in this
# script's argv (it arrives on stdin), and never on disk. It is briefly visible
# in the CONTAINER's process table, i.e. to root on this host — who already owns
# the hash file and can reset any credential anyway. That residual is the reason
# the other subcommands prefer --random.
hash_password() {
    local plaintext="$1" out
    [ -n "$plaintext" ] || error "password must not be empty"

    out="$(SECRET="$plaintext" docker run --rm -e SECRET --entrypoint sh "$AUTHELIA_IMAGE" \
        -c 'authelia crypto hash generate argon2 --password "$SECRET"' 2>/dev/null)" \
        || error "Failed to run $AUTHELIA_IMAGE to hash the password"

    GEN_DIGEST="$(printf '%s' "$out" | awk '/^Digest:/{print $2}')"
    [ -n "$GEN_DIGEST" ] || error "Could not parse argon2 digest from authelia output"
}

# Claimed = at least one user that is not disabled.
#
# Deliberately a property of the FILE rather than of a particular username, so it
# survives the rename that `claim` performs and stays correct once there are
# several accounts. ensure-dex.sh evaluates the same predicate to decide whether
# to offer the Local Account connector — keep the two in sync.
is_claimed() {
    local enabled
    enabled="$(yq '[.users[] | select(.disabled != true)] | length' "$USERS_DB" 2>/dev/null || echo 0)"
    [ "${enabled:-0}" -gt 0 ] 2>/dev/null
}

# Apply a yq expression to a temp copy, sanity-check it, then swap it in.
# Never edits USERS_DB in place: a yq failure partway through would otherwise
# leave the only copy of the local account store truncated.
write_users_db() {
    local expr="$1"
    local meta tmp
    meta="$(preserve_meta "$USERS_DB")"
    tmp="$(mktemp)" || error "Failed to create temp file"

    if ! yq "$expr" "$USERS_DB" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "yq failed to apply the change"
    fi

    # Refuse to install a file that lost the users map or came out empty.
    if ! yq -e '.users | type == "!!map"' "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        error "refusing to write: result has no valid .users map"
    fi

    chmod 600 "$tmp"
    mv "$tmp" "$USERS_DB" || { rm -f "$tmp"; error "Failed to write $USERS_DB"; }
    restore_meta "$USERS_DB" "$meta"
}

# --- subcommands -------------------------------------------------------------

# Password hashes are deliberately not included.
cmd_list() {
    yq -o=json -I=0 '
        .users
        | to_entries
        | map({
            "username": .key,
            "displayname": (.value.displayname // ""),
            "email": (.value.email // ""),
            "groups": (.value.groups // []),
            "disabled": (.value.disabled // false)
          })
    ' "$USERS_DB"
}

# Onboarding. Turns the unclaimed seed into the owner's real account:
#   - renames the placeholder key to the username THEY choose,
#   - sets the password THEY choose (stdin) or mints one (--generate),
#   - clears `disabled`, which is what makes the account usable at all,
#   - records the username in LOCAL_ADMIN_USER so ensure-authelia.sh keeps
#     stamping the owner's email onto the right block after the rename,
#   - re-runs ensure-dex.sh so the Local Account connector appears immediately
#     rather than at the next self-check tick.
#
# Why rename rather than create-then-delete: Authelia rejects an empty `users:`
# map (verified — "could not validate the schema: users: non zero value
# required"), so the placeholder cannot be removed first. Carrying the entry
# forward also preserves the email ensure-authelia.sh seeded.
#
# The username is the OIDC `preferred_username`, which every app on the box keys
# its per-user account on. Choosing it HERE is free — nothing has logged in yet.
# Changing it later is not: it would orphan every app-side account. That is why
# there is no rename subcommand, and why claim refuses to run twice without
# --force.
cmd_claim() {
    local generate=0
    if [ "${1:-}" = "--generate" ]; then
        generate=1
        shift
    fi
    local force=0
    if [ "${1:-}" = "--force" ]; then
        force=1
        shift
    fi

    local username="${1:-}" displayname="${2:-}"
    validate_username "$username"
    [ -n "$displayname" ] || displayname="Administrator"
    [ "${#displayname}" -le 64 ] || error "displayname must be 64 characters or fewer"

    if [ "$force" -ne 1 ] && is_claimed; then
        error "this box is already claimed; use 'set-password' to change a password, or pass --force to re-claim"
    fi

    # The entry to convert: the recorded owner if present, else the sole user.
    # A box with several accounts and no recorded owner is ambiguous, so refuse
    # rather than guess which one to rename.
    local placeholder=""
    if user_exists "$PROTECTED_USER"; then
        placeholder="$PROTECTED_USER"
    else
        local count
        count="$(yq '.users | length' "$USERS_DB" 2>/dev/null || echo 0)"
        [ "${count:-0}" = "1" ] \
            || error "cannot determine which account to claim (no '$PROTECTED_USER', and $count users present)"
        placeholder="$(yq -r '.users | keys | .[0]' "$USERS_DB")"
    fi

    if [ "$username" != "$placeholder" ] && user_exists "$username"; then
        error "user already exists: $username"
    fi

    if [ "$generate" -eq 1 ]; then
        generate_password_and_digest
    else
        # Password on stdin so it never reaches this script's argv either.
        local plaintext=""
        if [ -t 0 ]; then
            error "no password on stdin; pipe one (printf '%s' 'pass' | ... claim <username>) or pass --generate"
        fi
        IFS= read -r plaintext || true
        [ -n "$plaintext" ] || error "no password on stdin; pipe one or pass --generate"
        [ "${#plaintext}" -ge 8 ] || error "password must be at least 8 characters"
        hash_password "$plaintext"
        GEN_PASSWORD=""
    fi

    # Drop the placeholder only when the owner actually renamed it. Built as a
    # string here rather than branched inside the expression: yq has no
    # if/then/else (its lexer rejects `if` outright), and doing it in one
    # expression keeps the whole rename to a SINGLE atomic write — a two-call
    # version interrupted midway would leave both entries behind.
    local del_clause=""
    [ "$placeholder" != "$username" ] && del_clause='| del(.users[strenv(P)])'

    # Assigning the whole entry is what clears `disabled`: the replacement object
    # simply has no such key. Groups are deduped in a SEPARATE top-level step —
    # a piped `unique` inside the map literal silently drops the key instead of
    # deduping it.
    P="$placeholder" U="$username" DN="$displayname" PW="$GEN_DIGEST" G="$ADMIN_GROUP" \
        write_users_db '
            .users[strenv(U)] = {
                "displayname": strenv(DN),
                "password": strenv(PW),
                "email": (.users[strenv(P)].email // ""),
                "groups": (.users[strenv(P)].groups // [])
            }
            | .users[strenv(U)].groups = ((.users[strenv(U)].groups // []) + [strenv(G)] | unique)
            | .users[strenv(U)].displayname style="double"
            | .users[strenv(U)].password style="double"
            | .users[strenv(U)].email style="double"
            | .users[strenv(U)].groups[] style="double"
            '"$del_clause"

    user_exists "$username" || error "verification failed: $username missing after claim"
    is_claimed || error "verification failed: account still reads as unclaimed after claim"

    # Record the choice BEFORE re-rendering Dex: ensure-authelia.sh reads it to
    # keep the owner's email stamped on the right block.
    set_env_value LOCAL_ADMIN_USER "$username" >/dev/null 2>&1 \
        || echo "WARNING: could not record LOCAL_ADMIN_USER in $ENV_FILE" >&2

    # Surface the Local Account connector now. Failure is non-fatal — the next
    # self-check tick renders it anyway.
    if [ -x "$SCRIPTS_DIR/self-check/ensure-dex.sh" ]; then
        "$SCRIPTS_DIR/self-check/ensure-dex.sh" >/dev/null 2>&1 \
            || echo "WARNING: ensure-dex.sh failed; the Local Account connector appears at the next self-check" >&2
    fi

    if [ -n "${GEN_PASSWORD:-}" ]; then
        U="$username" P="$GEN_PASSWORD" yq -o=json -I=0 -n \
            '{"username": strenv(U), "claimed": true, "password": strenv(P)}'
    else
        U="$username" yq -o=json -I=0 -n '{"username": strenv(U), "claimed": true}'
    fi
}

cmd_add() {
    local username="${1:-}" displayname="${2:-}" email="${3:-}" groups_csv="${4:-users}"

    validate_username "$username"
    [ -n "$displayname" ] || error "displayname must not be empty"
    validate_email "$email"
    user_exists "$username" && error "user already exists: $username"

    [ -n "$groups_csv" ] || groups_csv="users"

    generate_password_and_digest

    # style="double" on every string field is not cosmetic. displayname is
    # user-supplied, and yq emits new values as plain scalars — a display name of
    # `Yes`, `No` or `123` would then be read back as a boolean or a number
    # rather than a string, by yq and by Authelia alike. Quoting also keeps the
    # file uniform with what ensure-authelia.sh seeds.
    U="$username" DN="$displayname" EM="$email" PW="$GEN_DIGEST" GR="$groups_csv" \
        write_users_db '
            .users[strenv(U)] = {
                "displayname": strenv(DN),
                "password": strenv(PW),
                "email": strenv(EM),
                "groups": (strenv(GR) | split(",") | map(sub("^\s+|\s+$"; "")) | map(select(. != "")))
            }
            | .users[strenv(U)].displayname style="double"
            | .users[strenv(U)].password style="double"
            | .users[strenv(U)].email style="double"
            | .users[strenv(U)].groups[] style="double"
        '

    user_exists "$username" || error "verification failed: $username missing after write"

    U="$username" P="$GEN_PASSWORD" yq -o=json -I=0 -n \
        '{"username": strenv(U), "password": strenv(P)}'
}

cmd_delete() {
    local username="${1:-}"

    validate_username "$username"
    require_user "$username"

    [ "$username" = "$PROTECTED_USER" ] \
        && error "refusing to delete '$PROTECTED_USER': it is the owner account and ensure-authelia.sh will not re-seed it while other users exist"

    if is_admin_user "$username" && [ "$(admin_count)" -le 1 ]; then
        error "refusing to delete the last member of '$ADMIN_GROUP' — nobody would be able to administer this box"
    fi

    U="$username" write_users_db 'del(.users[strenv(U)])'

    user_exists "$username" && error "verification failed: $username still present after delete"

    U="$username" yq -o=json -I=0 -n '{"username": strenv(U)}'
}

cmd_set_password() {
    local username="${1:-}"

    validate_username "$username"
    require_user "$username"

    generate_password_and_digest

    U="$username" PW="$GEN_DIGEST" write_users_db \
        '.users[strenv(U)].password = strenv(PW) | .users[strenv(U)].password style="double"'

    U="$username" P="$GEN_PASSWORD" yq -o=json -I=0 -n \
        '{"username": strenv(U), "password": strenv(P)}'
}

cmd_set_email() {
    local username="${1:-}" email="${2:-}"

    validate_username "$username"
    require_user "$username"
    validate_email "$email"

    # The owner account's address is owned by EMAIL in .env, not by this file:
    # ensure-authelia.sh re-stamps it on every self-check tick (that is what the
    # owner-scoped awk in it exists to do). Accepting a change here would look
    # like it worked and silently revert within the day, so refuse and say where
    # the real setting lives.
    [ "$username" = "$PROTECTED_USER" ] \
        && error "'$PROTECTED_USER' email is managed by EMAIL in $ENV_FILE and is re-applied on every self-check; change it there instead"

    U="$username" EM="$email" write_users_db \
        '.users[strenv(U)].email = strenv(EM) | .users[strenv(U)].email style="double"'

    U="$username" yq -o=json -I=0 -n '{"username": strenv(U)}'
}

# --- dispatch ----------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
Usage:
  authelia-user-manager.sh list
  authelia-user-manager.sh claim [--generate] [--force] <username> [displayname]
      Onboarding: names the owner account, sets its password and enables it.
      Password is read from stdin unless --generate is given.
      e.g.  printf '%s' 'my-password' | authelia-user-manager.sh claim pierre "Pierre H"
  authelia-user-manager.sh add <username> <displayname> <email> [groups-csv]
  authelia-user-manager.sh delete <username>
  authelia-user-manager.sh set-password <username>
  authelia-user-manager.sh set-email <username> <email>
EOF
    exit 1
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift

case "$COMMAND" in
    list)         [ $# -eq 0 ] || usage; cmd_list ;;
    claim)        [ $# -ge 1 ] && [ $# -le 4 ] || usage; cmd_claim "$@" ;;
    add)          [ $# -ge 3 ] && [ $# -le 4 ] || usage; cmd_add "$@" ;;
    delete)       [ $# -eq 1 ] || usage; cmd_delete "$@" ;;
    set-password) [ $# -eq 1 ] || usage; cmd_set_password "$@" ;;
    set-email)    [ $# -eq 2 ] || usage; cmd_set_email "$@" ;;
    *)            usage ;;
esac
