#!/usr/bin/env bash

# act/lib/core.sh
#
# Core runtime for the act CLI library.
#
# Compatibility:
#   - Bash
#   - Zsh
#
# This file intentionally knows nothing about:
#   - pacman
#   - AUR
#   - Flatpak
#   - browsers
#   - fzf
#   - individual actions
#
# It provides shared primitives for the rest of the library.

# ---------------------------------------------------------------------------
# Guard
# ---------------------------------------------------------------------------
#
# Prevent this file from being initialized more than once when sourced.

if [ "${ACT_CORE_LOADED:-0}" -eq 1 ]; then
    return 0 2>/dev/null || exit 0
fi

ACT_CORE_LOADED=1

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

ACT_VERSION="${ACT_VERSION:-0.1.0}"

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

# Debug mode.
ACT_DEBUG="${ACT_DEBUG:-0}"

# Quiet mode.
ACT_QUIET="${ACT_QUIET:-0}"

# Whether commands should actually be executed.
#
# Useful for:
#
#   install --dry-run
#
# and for testing the resolver.
ACT_DRY_RUN="${ACT_DRY_RUN:-0}"

# Last command's exit status.
ACT_STATUS=0

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
#
# Colors are enabled only when stdout/stderr is a terminal and the user
# hasn't explicitly disabled them.
#
# Disable with:
#
#   ACT_COLOR=0
#
# Enable explicitly with:
#
#   ACT_COLOR=1

if [ -z "${ACT_COLOR+x}" ]; then
    if [ -t 1 ] || [ -t 2 ]; then
        ACT_COLOR=1
    else
        ACT_COLOR=0
    fi
fi

if [ "$ACT_COLOR" -eq 1 ]; then
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

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

act_log() {
    if [ "$ACT_QUIET" -eq 0 ]; then
        printf '%s\n' "$*"
    fi
}

act_info() {
    if [ "$ACT_QUIET" -eq 0 ]; then
        printf '%sact:%s %s\n' \
            "$ACT_CYAN" \
            "$ACT_RESET" \
            "$*"
    fi
}

act_success() {
    if [ "$ACT_QUIET" -eq 0 ]; then
        printf '%sact:%s %s%s%s\n' \
            "$ACT_CYAN" \
            "$ACT_RESET" \
            "$ACT_GREEN" \
            "$*" \
            "$ACT_RESET"
    fi
}

act_warn() {
    printf '%sact: warning:%s %s\n' \
        "$ACT_YELLOW" \
        "$ACT_RESET" \
        "$*" >&2
}

act_error() {
    printf '%sact: error:%s %s\n' \
        "$ACT_RED" \
        "$ACT_RESET" \
        "$*" >&2
}

act_debug() {
    if [ "$ACT_DEBUG" -eq 1 ]; then
        printf '%sact: debug:%s %s\n' \
            "$ACT_DIM" \
            "$ACT_RESET" \
            "$*" >&2
    fi
}

# ---------------------------------------------------------------------------
# Fatal error
# ---------------------------------------------------------------------------

act_die() {
    act_error "$@"
    return 1
}

# ---------------------------------------------------------------------------
# Command detection
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Shell detection
# ---------------------------------------------------------------------------

act_detect_shell() {
    case "${ACT_SHELL:-}" in
        bash|zsh)
            printf '%s\n' "$ACT_SHELL"
            return 0
            ;;
    esac

    case "${ZSH_VERSION:-}" in
        '')
            ;;
        *)
            printf '%s\n' "zsh"
            return 0
            ;;
    esac

    case "${BASH_VERSION:-}" in
        '')
            ;;
        *)
            printf '%s\n' "bash"
            return 0
            ;;
    esac

    case "${SHELL:-}" in
        */zsh)
            printf '%s\n' "zsh"
            return 0
            ;;

        */bash)
            printf '%s\n' "bash"
            return 0
            ;;
    esac

    printf '%s\n' "unknown"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------

act_detect_arch() {
    uname -m 2>/dev/null || printf '%s\n' "unknown"
}

# ---------------------------------------------------------------------------
# Privilege detection
# ---------------------------------------------------------------------------

act_is_root() {
    [ "$(id -u 2>/dev/null)" -eq 0 ]
}

act_has_sudo() {
    act_has_command sudo
}

# ---------------------------------------------------------------------------
# Safe command execution
# ---------------------------------------------------------------------------
#
# All actual command execution should eventually pass through here.
#
# This gives us:
#
#   - debug logging
#   - dry-run support
#   - consistent exit status
#
# Example:
#
#   act_exec pacman -S firefox
#
#   act_exec flatpak install org.mozilla.firefox
#

act_exec() {
    [ "$#" -gt 0 ] || {
        act_error "act_exec called without a command"
        return 2
    }

    act_debug "exec: $(act_quote_command "$@")"

    if [ "$ACT_DRY_RUN" -eq 1 ]; then
        act_info "[dry-run] $(act_quote_command "$@")"
        ACT_STATUS=0
        return 0
    fi

    "$@"
    ACT_STATUS=$?

    return "$ACT_STATUS"
}

# ---------------------------------------------------------------------------
# Privileged command execution
# ---------------------------------------------------------------------------
#
# This does NOT automatically prepend sudo to every command.
#
# The caller explicitly requests privilege:
#
#   act_exec_privileged pacman -S firefox
#
# If already root, sudo is skipped.

act_exec_privileged() {
    [ "$#" -gt 0 ] || {
        act_error "act_exec_privileged called without a command"
        return 2
    }

    if act_is_root; then
        act_exec "$@"
        return $?
    fi

    if ! act_has_sudo; then
        act_error "sudo is required: $(act_quote_command "$@")"
        return 1
    fi

    act_exec sudo "$@"
}

# ---------------------------------------------------------------------------
# Command quoting
# ---------------------------------------------------------------------------
#
# Used for human-readable logging only.
#
# It does NOT execute anything.

act_quote_arg() {
    local argument="$1"

    # printf %q exists in Bash and Zsh.
    printf '%q' "$argument"
}

act_quote_command() {
    local argument
    local output=""

    for argument in "$@"; do
        if [ -n "$output" ]; then
            output="${output} "
        fi

        output="${output}$(act_quote_arg "$argument")"
    done

    printf '%s' "$output"
}

# ---------------------------------------------------------------------------
# String helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Array helpers
# ---------------------------------------------------------------------------
#
# These intentionally use ordinary indexed arrays, which are supported by
# both Bash and Zsh.
#
# Important:
#
#   Never use `array=( $(command) )`
#
# because that destroys whitespace and word boundaries.
#
# Always populate arrays with:
#
#   while IFS= read -r item; do
#       array+=("$item")
#   done
#
# or direct quoted assignments.

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

act_array_append_unique() {
    local item="$1"
    shift

    act_array_contains "$item" "$@" && return 0

    # This helper prints the new item.
    #
    # Callers that need an actual array should append it themselves.
    printf '%s\n' "$item"
}

# ---------------------------------------------------------------------------
# Temporary files
# ---------------------------------------------------------------------------

act_mktemp() {
    if act_has_command mktemp; then
        mktemp "${TMPDIR:-/tmp}/act.XXXXXX"
        return $?
    fi

    act_error "mktemp is required"
    return 1
}

# ---------------------------------------------------------------------------
# Cleanup registration
# ---------------------------------------------------------------------------

typeset -a ACT_CLEANUP_FILES 2>/dev/null || ACT_CLEANUP_FILES=()

act_cleanup_file() {
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

# ---------------------------------------------------------------------------
# Exit/status helpers
# ---------------------------------------------------------------------------

act_status() {
    printf '%s\n' "${ACT_STATUS:-0}"
}

act_set_status() {
    ACT_STATUS="$1"
}

act_ok() {
    [ "${1:-$ACT_STATUS}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Environment helpers
# ---------------------------------------------------------------------------

act_env_is_set() {
    [ -n "${!1+x}" ]
}

# ---------------------------------------------------------------------------
# PATH helpers
# ---------------------------------------------------------------------------

act_path_contains() {
    local wanted="$1"
    local path_entry

    old_ifs="$IFS"
    IFS=':'

    for path_entry in ${PATH:-}; do
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

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------

act_config_dir() {
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s\n' "${XDG_CONFIG_HOME}/act"
    else
        printf '%s\n' "${HOME}/.config/act"
    fi
}

act_data_dir() {
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s\n' "${XDG_DATA_HOME}/act"
    else
        printf '%s\n' "${HOME}/.local/share/act"
    fi
}

act_cache_dir() {
    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s\n' "${XDG_CACHE_HOME}/act"
    else
        printf '%s\n' "${HOME}/.cache/act"
    fi
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------
#
# Basic dotted-version comparison.
#
# Returns:
#
#   0 if equal
#   1 if first > second
#   2 if first < second
#
# Example:
#
#   act_version_compare 1.2.0 1.1.9
#

act_version_compare() {
    local first="$1"
    local second="$2"

    local first_part
    local second_part

    local -a first_parts
    local -a second_parts

    local i
    local max

    IFS='.' read -r -a first_parts <<EOF
$first
EOF

    IFS='.' read -r -a second_parts <<EOF
$second
EOF

    max="${#first_parts[@]}"

    if [ "${#second_parts[@]}" -gt "$max" ]; then
        max="${#second_parts[@]}"
    fi

    i=0

    while [ "$i" -lt "$max" ]; do
        first_part="${first_parts[$i]:-0}"
        second_part="${second_parts[$i]:-0}"

        # Strip non-numeric suffixes for simple semantic versions.
        first_part="${first_part%%[^0-9]*}"
        second_part="${second_part%%[^0-9]*}"

        first_part="${first_part:-0}"
        second_part="${second_part:-0}"

        if [ "$first_part" -gt "$second_part" ]; then
            return 1
        fi

        if [ "$first_part" -lt "$second_part" ]; then
            return 2
        fi

        i=$((i + 1))
    done

    return 0
}

# ---------------------------------------------------------------------------
# Trap handling
# ---------------------------------------------------------------------------

act_setup_traps() {
    trap 'act_cleanup' EXIT
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

act_init() {
    act_debug "version: $ACT_VERSION"
    act_debug "shell: $(act_detect_shell)"
    act_debug "os: $(act_detect_os)"
    act_debug "arch: $(act_detect_arch)"
}

# Initialize immediately when sourced.
act_init
