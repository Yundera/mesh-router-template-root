#!/bin/bash
# env-file-manager.sh - Unified ENV file management for mesh scripts
#
# Usage:
#   env-file-manager.sh set VAR_NAME "value" /path/to/file.env
#   env-file-manager.sh get VAR_NAME /path/to/file.env
#   env-file-manager.sh delete VAR_NAME /path/to/file.env
#   env-file-manager.sh exists VAR_NAME /path/to/file.env
#   env-file-manager.sh sanitize /path/to/file.env
#
# Every mutation is atomic (temp file + mv) and verified. Use this instead of
# hand-rolled sed/grep over .env — the raw pattern this replaced silently
# dropped the file's mode and owner on every write.
#
# Ported from Yundera/template-root (scripts/tools/env-file-manager.sh); the
# two are kept interface-compatible on purpose so ported ensure-scripts and the
# admin app can call either. See doc/alignment-with-template-root.md.

set -euo pipefail

# Print error message to stderr and exit
error() {
    echo "ERROR: $1" >&2
    exit 1
}

# Ensure parent directory exists, create if needed
ensure_directory() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || error "Failed to create directory: $dir"
    fi
}

# Ensure file exists, create if needed
ensure_file() {
    local file="$1"
    ensure_directory "$file"
    if [ ! -f "$file" ]; then
        touch "$file" || error "Failed to create file: $file"
    fi
}

# Capture mode + ownership of an existing file. mktemp creates files mode
# 0600 owned by the calling user; on same-fs `mv` the destination inherits
# these — silently chmod'ing the env file to 0600 and chowning to whoever
# ran the script (root, when invoked from cron). Capture before mv, restore
# after, so the file's pre-existing mode/owner survive every set/delete/sanitize.
#
# This matters more here than upstream: the mesh .env is deliberately owned by
# PUID:PGID so the dashboard (uid 1000) can read it and group the stack instead
# of showing the containers as individual "External Apps".
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

# SET: Update or add a variable in the env file
cmd_set() {
    local var_name="$1"
    local var_value="$2"
    local env_file="$3"

    ensure_file "$env_file"
    local meta
    meta=$(preserve_meta "$env_file")

    local tmp_file
    tmp_file=$(mktemp) || error "Failed to create temp file"

    # Remove existing variable and write to temp file
    grep -v "^${var_name}=" "$env_file" > "$tmp_file" 2>/dev/null || true

    # Ensure trailing newline before appending
    if [ -s "$tmp_file" ] && [ "$(tail -c1 "$tmp_file" | wc -l)" -eq 0 ]; then
        echo "" >> "$tmp_file"
    fi

    # Append new value
    echo "${var_name}=${var_value}" >> "$tmp_file"

    # Atomic move
    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        error "Failed to write to $env_file"
    }
    restore_meta "$env_file" "$meta"

    # Verify the write
    local written_value
    written_value=$(grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2- || echo "")
    if [ "$written_value" != "$var_value" ]; then
        error "Verification failed: value mismatch after write to $env_file"
    fi
}

# GET: Read a variable value from the env file
# Returns empty string if not found, exits 0 on success
cmd_get() {
    local var_name="$1"
    local env_file="$2"

    if [ ! -f "$env_file" ]; then
        echo ""
        return 0
    fi

    local value
    value=$(grep "^${var_name}=" "$env_file" 2>/dev/null | head -n1 | cut -d'=' -f2- || echo "")

    # Remove surrounding quotes if present
    value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

    echo "$value"
}

# DELETE: Remove a variable from the env file
cmd_delete() {
    local var_name="$1"
    local env_file="$2"

    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local meta
    meta=$(preserve_meta "$env_file")

    local tmp_file
    tmp_file=$(mktemp) || error "Failed to create temp file"

    grep -v "^${var_name}=" "$env_file" > "$tmp_file" 2>/dev/null || true

    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        error "Failed to write to $env_file"
    }
    restore_meta "$env_file" "$meta"
}

# EXISTS: Check if a variable exists in the env file
# Exit code 0 = exists, 1 = not found
cmd_exists() {
    local var_name="$1"
    local env_file="$2"

    if [ ! -f "$env_file" ]; then
        return 1
    fi

    if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# SANITIZE: Squeeze blank lines and ensure a trailing newline
cmd_sanitize() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        return 0
    fi

    local meta
    meta=$(preserve_meta "$env_file")

    local tmp_file
    tmp_file=$(mktemp) || error "Failed to create temp file"

    cat -s "$env_file" > "$tmp_file"

    if [ -s "$tmp_file" ] && [ "$(tail -c1 "$tmp_file" | wc -l)" -eq 0 ]; then
        echo "" >> "$tmp_file"
    fi

    mv "$tmp_file" "$env_file" || {
        rm -f "$tmp_file"
        error "Failed to write to $env_file"
    }
    restore_meta "$env_file" "$meta"
}

main() {
    if [ $# -lt 1 ]; then
        error "Usage: env-file-manager.sh <command> [args...]"
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        set)
            if [ $# -ne 3 ]; then
                error "Usage: env-file-manager.sh set VAR_NAME value /path/to/file.env"
            fi
            cmd_set "$1" "$2" "$3"
            ;;
        get)
            if [ $# -ne 2 ]; then
                error "Usage: env-file-manager.sh get VAR_NAME /path/to/file.env"
            fi
            cmd_get "$1" "$2"
            ;;
        delete)
            if [ $# -ne 2 ]; then
                error "Usage: env-file-manager.sh delete VAR_NAME /path/to/file.env"
            fi
            cmd_delete "$1" "$2"
            ;;
        exists)
            if [ $# -ne 2 ]; then
                error "Usage: env-file-manager.sh exists VAR_NAME /path/to/file.env"
            fi
            cmd_exists "$1" "$2"
            ;;
        sanitize)
            if [ $# -ne 1 ]; then
                error "Usage: env-file-manager.sh sanitize /path/to/file.env"
            fi
            cmd_sanitize "$1"
            ;;
        *)
            error "Unknown command: $cmd. Available: set, get, delete, exists, sanitize"
            ;;
    esac
}

main "$@"
