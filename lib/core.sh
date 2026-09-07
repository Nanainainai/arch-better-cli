#!/usr/bin/env bash

# act/lib/core.sh
#
# Shared runtime for the act CLI library.
#
# Supported shells:
#   Bash
#   Zsh
#
# This file intentionally contains NO action-specific logic.
#
# It provides:
#   - runtime state
#   - logging
#   - command detection
#   - command execution
#   - privilege handling
#   - shell/platform detection
#   - filesystem helpers
#   - PATH helpers
#   - temporary-file handling
#   - cleanup
#
# Action-specific behavior belongs in the corresponding action libraries.
#
# ---------------------------------------------------------------------------


# ===========================================================================
# Loading guard
# ===========================================================================

if [ "${ACT_CORE_LOADED:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

ACT_CORE_LOADED=1


# ===========================================================================
# Identity
# ===========================================================================

ACT_NAME="${ACT_NAME:-act}"
ACT_VERSION="${ACT_VERSION:-0.1.0}"


# ===========================================================================
# Runtime state
# ===========================================================================

# Logging controls.
ACT_QUIET="${ACT_QUIET:-0}"
ACT_VERBOSE="${ACT_VERBOSE:-0}"
ACT_DEBUG="${ACT_DEBUG:-0}"

# Execution controls.
#
# ACT_DRY_RUN:
#   Resolve and display commands without executing them.
#
# ACT_ASSUME_YES:
#   Allows actions to skip confirmation prompts where supported.
#
ACT_DRY_RUN="${ACT_DRY_RUN:-0}"
ACT_ASSUME_YES="${ACT_ASSUME_YES:-0}"

# Last command status.
ACT_STATUS=0


# ===========================================================================
# Color handling
# ===========================================================================

# Explicitly disable with:
#
#   ACT_COLOR=0
#
# Explicitly enable with:
#
#   ACT_COLOR=1
#
# Otherwise colors are enabled only when output is a terminal.

if [ -z "${ACT_COLOR+x}" ]; then
    if [ -t 1 ] || [ -t 2 ]; then
        ACT_COLOR=1
    else
        ACT_COLOR=0
    fi
fi

if [ "$ACT_COLOR" = "1" ]; then
    ACT_RESET="$(printf '\033[0m')"
    ACT_BOLD="$(printf '\033[1m')"
    ACT_DIM="$(printf '\033[2m')"

    ACT_RED="$(printf '\033[31m')"
    ACT_GREEN="$(printf '\033[32m')"
    ACT_YELLOW="$(printf '\033[33m')"
    ACT_BLUE="$(printf '\033[34m')"
    ACT_CYAN="$(printf '\033[36m')"
else
    ACT_RESET=""
    ACT_BOLD=""
    ACT_DIM=""

    ACT_RED=""
    ACT_GREEN=""
    ACT_YELLOW=""
    ACT_BLUE=""
    ACT_CYAN=""
fi


# ===========================================================================
# Logging
# ===========================================================================

act_log() {
    if [ "$ACT_QUIET" != "1" ]; then
        printf '%s\n' "$*"
    fi
}


act_info() {
    if [ "$ACT_QUIET" != "1" ]; then
        printf '%s%s:%s %s\n' \
            "$ACT_CYAN" \
            "$ACT_NAME" \
            "$ACT_RESET" \
            "$*"
    fi
}


act_success() {
    if [ "$ACT_QUIET" != "1" ]; then
        printf '%s%s:%s %s%s%s\n' \
            "$ACT_CYAN" \
            "$ACT_NAME" \
            "$ACT_RESET" \
            "$ACT_GREEN" \
            "$*" \
            "$ACT_RESET"
    fi
}


act_warn() {
    printf '%s%s: warning:%s %s\n' \
        "$ACT_YELLOW" \
        "$ACT_NAME" \
        "$ACT_RESET" \
        "$*" >&2
}


act_error() {
    printf '%s%s: error:%s %s\n' \
        "$ACT_RED" \
        "$ACT_NAME" \
        "$ACT_RESET" \
        "$*" >&2
}


act_debug() {
    if [ "$ACT_DEBUG" = "1" ] || [ "$ACT_VERBOSE" = "1" ]; then
        printf '%s%s: debug:%s %s\n' \
            "$ACT_DIM" \
            "$ACT_NAME" \
            "$ACT_RESET" \
            "$*" >&2
    fi
}


# ===========================================================================
# Status / failure helpers
# ===========================================================================

act_die() {
    act_error "$@"
    return 1
}


act_status() {
    printf '%s\n' "$ACT_STATUS"
}


act_set_status() {
    ACT_STATUS="$1"
}


act_successful() {
    [ "${1:-$ACT_STATUS}" -eq 0 ]
}


# ===========================================================================
# Command detection
# ===========================================================================

act_has_command() {
    [ "$#" -eq 1 ] || return 2

    command -v "$1" >/dev/null 2>&1
}


act_require_command() {
    local command_name

    for command_name in "$@"; do
        if ! act_has_command "$command_name"; then
            act_error "required command not found: $command_name"
            return 1
        fi
    done

    return 0
}


act_command_path() {
    [ "$#" -eq 1 ] || return 2

    command -v "$1" 2>/dev/null
}


# ===========================================================================
# Shell detection
# ===========================================================================

act_detect_shell() {
    # Explicit override.
    case "${ACT_SHELL:-}" in
        bash|zsh)
            printf '%s\n' "$ACT_SHELL"
            return 0
            ;;
    esac

    # Detect the shell in which the library is actually executing.
    if [ -n "${ZSH_VERSION:-}" ]; then
        printf '%s\n' "zsh"
        return 0
    fi

    if [ -n "${BASH_VERSION:-}" ]; then
        printf '%s\n' "bash"
        return 0
    fi

    # Fall back to SHELL.
    case "${SHELL:-}" in
        */zsh)
            printf '%s\n' "zsh"
            ;;

        */bash)
            printf '%s\n' "bash"
            ;;

        *)
            printf '%s\n' "unknown"
            ;;
    esac
}


# ===========================================================================
# Operating-system detection
# ===========================================================================

act_detect_os() {
    case "$(uname -s 2>/dev/null)" in
        Linux)
            printf '%s\n' "linux"
            ;;

        Darwin)
            printf '%s\n' "macos"
            ;;

        FreeBSD)
            printf '%s\n' "freebsd"
            ;;

        OpenBSD)
            printf '%s\n' "openbsd"
            ;;

        NetBSD)
            printf '%s\n' "netbsd"
            ;;

        *)
            printf '%s\n' "unknown"
            ;;
    esac
}


act_detect_arch() {
    uname -m 2>/dev/null || printf '%s\n' "unknown"
}


# ===========================================================================
# Privilege detection
# ===========================================================================

act_is_root() {
    [ "$(id -u 2>/dev/null)" = "0" ]
}


act_has_sudo() {
    act_has_command sudo
}


# ===========================================================================
# Command quoting
# ===========================================================================
#
# These functions are for human-readable output only.
#
# They must never be used to reconstruct a command for execution.
#

act_quote_arg() {
    printf '%q' "$1"
}


act_quote_command() {
    local output=""
    local argument

    for argument in "$@"; do
        if [ -n "$output" ]; then
            output="${output} "
        fi

        output="${output}$(act_quote_arg "$argument")"
    done

    printf '%s' "$output"
}


# ===========================================================================
# Command execution
# ===========================================================================
#
# All action libraries should use act_exec() rather than invoking external
# commands through eval.
#
# This preserves argument boundaries and gives us:
#
#   - debugging
#   - dry-run support
#   - consistent status tracking
#

act_exec() {
    if [ "$#" -eq 0 ]; then
        act_error "cannot execute an empty command"
        ACT_STATUS=2
        return 2
    fi

    act_debug "exec: $(act_quote_command "$@")"

    if [ "$ACT_DRY_RUN" = "1" ]; then
        act_info "[dry-run] $(act_quote_command "$@")"
        ACT_STATUS=0
        return 0
    fi

    "$@"
    ACT_STATUS=$?

    return "$ACT_STATUS"
}


# ===========================================================================
# Privileged command execution
# ===========================================================================
#
# Privilege escalation is explicit.
#
# The library should NOT silently add sudo to arbitrary commands.
#
# Example:
#
#   act_exec_privileged pacman -S firefox
#
# If already root:
#
#   pacman -S firefox
#
# Otherwise:
#
#   sudo pacman -S firefox
#

act_exec_privileged() {
    if [ "$#" -eq 0 ]; then
        act_error "cannot execute an empty privileged command"
        ACT_STATUS=2
        return 2
    fi

    if act_is_root; then
        act_exec "$@"
        return $?
    fi

    if ! act_has_sudo; then
        act_error "sudo is required for: $(act_quote_command "$@")"
        ACT_STATUS=1
        return 1
    fi

    act_exec sudo "$@"
}


# ===========================================================================
# Array helpers
# ===========================================================================
#
# Bash and Zsh both support indexed arrays.
#
# We deliberately avoid:
#
#   associative arrays
#   namerefs
#   Bash-only indirect expansion
#   Zsh-specific array operators
#
# Action libraries can therefore use these helpers without caring which
# supported shell loaded them.
#

act_array_contains() {
    local needle="$1"
    shift

    local item

    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}


act_array_length() {
    printf '%s\n' "$#"
}


# ===========================================================================
# String helpers
# ===========================================================================

act_is_empty() {
    [ -z "${1:-}" ]
}


act_is_nonempty() {
    [ -n "${1:-}" ]
}


act_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}


act_upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}


# ===========================================================================
# Environment helpers
# ===========================================================================
#
# Kept deliberately simple and portable.
#
# Do not use Bash's `${!name}` indirection here.
#

act_env_is_set() {
    local variable_name="$1"

    [ "$#" -eq 1 ] || return 2

    case "$variable_name" in
        ACT_*|HOME|PATH|SHELL|USER|LOGNAME|TMPDIR|XDG_*)
            ;;
        *)
            # Generic environment probing is intentionally conservative.
            # Callers can directly test their own variables instead.
            return 1
            ;;
    esac

    eval '[ "${'"$variable_name"'+x}" = x ]'
}


# ===========================================================================
# PATH helpers
# ===========================================================================

act_path_contains() {
    local wanted="$1"
    local path_value="${PATH:-}"
    local old_ifs="$IFS"
    local path_entry

    IFS=':'

    for path_entry in $path_value; do
        if [ "$path_entry" = "$wanted" ]; then
            IFS="$old_ifs"
            return 0
        fi
    done

    IFS="$old_ifs"

    return 1
}


act_path_prepend() {
    local directory="$1"

    [ -d "$directory" ] || return 1

    if act_path_contains "$directory"; then
        return 0
    fi

    if [ -n "${PATH:-}" ]; then
        PATH="${directory}:${PATH}"
    else
        PATH="$directory"
    fi

    export PATH
}


act_path_append() {
    local directory="$1"

    [ -d "$directory" ] || return 1

    if act_path_contains "$directory"; then
        return 0
    fi

    if [ -n "${PATH:-}" ]; then
        PATH="${PATH}:${directory}"
    else
        PATH="$directory"
    fi

    export PATH
}


# ===========================================================================
# Filesystem helpers
# ===========================================================================

act_file_exists() {
    [ -f "$1" ]
}


act_directory_exists() {
    [ -d "$1" ]
}


act_make_directory() {
    [ "$#" -gt 0 ] || return 2

    mkdir -p -- "$@"
}


# ===========================================================================
# XDG paths
# ===========================================================================
#
# These are useful across ALL future actions:
#
#   install
#   create
#   download
#   remove
#   uninstall
#   etc.
#

act_config_dir() {
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s\n' "${XDG_CONFIG_HOME}/${ACT_NAME}"
    else
        printf '%s\n' "${HOME}/.config/${ACT_NAME}"
    fi
}


act_data_dir() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s\n' "${XDG_DATA_HOME}/${ACT_NAME}"
    else
        printf '%s\n' "${HOME}/.local/share/${ACT_NAME}"
    fi
}


act_cache_dir() {
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s\n' "${XDG_CACHE_HOME}/${ACT_NAME}"
    else
        printf '%s\n' "${HOME}/.cache/${ACT_NAME}"
    fi
}


act_state_dir() {
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        printf '%s\n' "${XDG_STATE_HOME}/${ACT_NAME}"
    else
        printf '%s\n' "${HOME}/.local/state/${ACT_NAME}"
    fi
}


# ===========================================================================
# Temporary files
# ===========================================================================

act_mktemp() {
    if ! act_has_command mktemp; then
        act_error "mktemp is required"
        return 1
    fi

    mktemp "${TMPDIR:-/tmp}/act.XXXXXX"
}


# ===========================================================================
# Cleanup
# ===========================================================================

ACT_CLEANUP_FILES=()


act_cleanup_file() {
    [ "$#" -eq 1 ] || return 2

    local file="$1"

    [ -n "$file" ] || return 0

    ACT_CLEANUP_FILES+=("$file")
}


act_cleanup() {
    local file

    for file in "${ACT_CLEANUP_FILES[@]}"; do
        if [ -e "$file" ]; then
            rm -f -- "$file"
        fi
    done

    ACT_CLEANUP_FILES=()
}


act_setup_traps() {
    trap 'act_cleanup' EXIT
}


# ===========================================================================
# Runtime information
# ===========================================================================

act_runtime_info() {
    printf 'name=%s\n' "$ACT_NAME"
    printf 'version=%s\n' "$ACT_VERSION"
    printf 'shell=%s\n' "$(act_detect_shell)"
    printf 'os=%s\n' "$(act_detect_os)"
    printf 'arch=%s\n' "$(act_detect_arch)"
}


# ===========================================================================
# Initialization
# ===========================================================================

act_init() {
    act_debug "initialized ${ACT_NAME} ${ACT_VERSION}"
    act_debug "shell: $(act_detect_shell)"
    act_debug "os: $(act_detect_os)"
    act_debug "arch: $(act_detect_arch)"
}
