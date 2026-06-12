#!/bin/bash

# Default log file path
DEFAULT_LOG_FILE="/DATA/AppData/mesh/log/mesh.log"

# Set log file (can be overridden by calling scripts)
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"

# Enhanced logging function with multiple features
log() {
    local level="INFO"
    local message=""
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Parse arguments - support both calling styles
    if [ $# -eq 1 ]; then
        # Single argument - assume it's just the message
        message="$1"
    elif [ $# -eq 2 ]; then
        # Two arguments - level and message
        level="$1"
        message="$2"
    else
        # Multiple arguments - level and message parts
        level="$1"
        shift
        message="$*"
    fi

    local log_entry="[$timestamp] [$level] $message"

    # Output to stdout (always)
    echo "$message"

    # Output to log file
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
}

# Internal logging function that only writes to log file (no stdout)
log_to_file_only() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] $message"

    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
}

# Convenience functions for different log levels
log_info() {
    log "INFO" "$*"
}

log_success() {
    log "SUCCESS" "$*"
}

log_warn() {
    log "WARN" "$*"
}

log_error() {
    log "ERROR" "$*"
}

log_debug() {
    # Only log debug messages if DEBUG environment variable is set
    if [ "${DEBUG:-false}" = "true" ]; then
        log "DEBUG" "$*"
    fi
}

# =================================================================
# SCRIPT EXECUTION FUNCTIONS
# =================================================================

# Execute a script with logging.
# Usage: execute_script_with_logging <script_path>
# Emits parseable result lines:
#   [ts] [SUCCESS] === [datetime] name.sh : success (Ns) ===
#   [ts] [ERROR]   === [datetime] name.sh : failed (exit code: N, Ns) ===
execute_script_with_logging() {
    local script_path="$1"
    local script_name=$(basename "$script_path")
    local start_time=$(date +%s)
    local start_datetime=$(date '+%Y-%m-%d %H:%M:%S')

    if [ -z "$script_path" ]; then
        log_error "No script path provided"
        return 1
    fi

    if [ ! -f "$script_path" ]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    if [ ! -x "$script_path" ]; then
        log_error "Script is not executable: $script_path"
        return 1
    fi

    cd "$(dirname "$script_path")" || {
        log_error "Failed to change directory to $(dirname "$script_path")"
        return 1
    }

    log_info "=== [$start_datetime] $script_name : starting ==="

    # Execute script with real-time output and logging
    {
        if command -v stdbuf >/dev/null 2>&1; then
            stdbuf -oL -eL "$script_path" 2>&1
        else
            "$script_path" 2>&1
        fi
    } | while IFS= read -r line; do
        echo "$line"
        log_to_file_only "OUTPUT" "$line"
    done

    # Capture the exit code from the script (not the while loop)
    local exit_code=${PIPESTATUS[0]}

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local end_datetime=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$exit_code" -eq 0 ]; then
        log_success "=== [$end_datetime] $script_name : success (${duration}s) ==="
    else
        log_error "=== [$end_datetime] $script_name : failed (exit code: $exit_code, ${duration}s) ==="
    fi

    return "$exit_code"
}

# Execute a script as a single-line checklist entry (for install / interactive
# runs). Full output is captured to the log file only; on failure the captured
# output is echoed indented so the operator sees the error inline.
# Usage: execute_script_display <index> <total> <script_path>
execute_script_display() {
    local index="$1" total="$2" script_path="$3"
    local script_name; script_name=$(basename "$script_path")
    local start_time; start_time=$(date +%s)
    local start_datetime; start_datetime=$(date '+%Y-%m-%d %H:%M:%S')

    printf '[%2s/%s] %-30s ' "$index" "$total" "$script_name"

    if [ ! -f "$script_path" ]; then
        printf '✗ MISSING\n'
        log_to_file_only "ERROR" "=== [$start_datetime] $script_name : not found ==="
        return 1
    fi
    [ -x "$script_path" ] || chmod +x "$script_path" 2>/dev/null || true

    log_to_file_only "INFO" "=== [$start_datetime] $script_name : starting ==="

    local out_file; out_file=$(mktemp)
    local exit_code=0
    ( cd "$(dirname "$script_path")" && "$script_path" ) >"$out_file" 2>&1 || exit_code=$?

    # Mirror captured output into the rotating log
    while IFS= read -r line; do
        log_to_file_only "OUTPUT" "$line"
    done < "$out_file"

    local end_time; end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local end_datetime; end_datetime=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$exit_code" -eq 0 ]; then
        printf '✓ (%ss)\n' "$duration"
        log_to_file_only "SUCCESS" "=== [$end_datetime] $script_name : success (${duration}s) ==="
    else
        printf '✗ FAILED (exit %s, %ss)\n' "$exit_code" "$duration"
        log_to_file_only "ERROR" "=== [$end_datetime] $script_name : failed (exit code: $exit_code, ${duration}s) ==="
        sed 's/^/      | /' "$out_file"
    fi

    rm -f "$out_file"
    return "$exit_code"
}
