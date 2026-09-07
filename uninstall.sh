#!/usr/bin/env bash

# act/uninstall.sh
#
# Removes the act CLI library installed by install.sh.
#
# Typical usage:
#
#   ./uninstall.sh
#   ./uninstall.sh --prefix ~/.local
#
# This script does NOT remove user-created configuration or unrelated files.

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ACT_NAME="act"

DEFAULT_PREFIX="${HOME}/.local"
PREFIX="$DEFAULT_PREFIX"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

info() {
    printf 'act: %s\n' "$*"
}

warn() {
    printf 'act: warning: %s\n' "$*" >&2
}

error() {
    printf 'act: error: %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage:
    ./uninstall.sh [options]

Options:
    --prefix DIR       Installation prefix
    -h, --help         Show this help

Default prefix:
    ~/.local
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] ||
                error "--prefix requires a directory"

            PREFIX="$2"
            shift 2
            ;;

        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            error "unknown option: $1"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

ACT_LIB_DIR="${PREFIX}/share/${ACT_NAME}"
ACT_BIN_DIR="${PREFIX}/bin"

ACT_MAIN="${ACT_BIN_DIR}/act"
ACT_INSTALL="${ACT_BIN_DIR}/install"

# ---------------------------------------------------------------------------
# Shell detection
# ---------------------------------------------------------------------------

detect_shell() {
    if [ -n "${SHELL:-}" ]; then
        case "$SHELL" in
            */zsh)
                printf 'zsh\n'
                return
                ;;

            */bash)
                printf 'bash\n'
                return
                ;;
        esac
    fi

    printf 'unknown\n'
}

detect_shell_config() {
    shell="$1"

    case "$shell" in
        zsh)
            printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
            ;;

        bash)
            if [ -f "$HOME/.bashrc" ]; then
                printf '%s\n' "$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                printf '%s\n' "$HOME/.bash_profile"
            else
                printf '%s\n' "$HOME/.bashrc"
            fi
            ;;

        *)
            printf '%s\n' ""
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Shell initialization
# ---------------------------------------------------------------------------

ACT_INIT_MARKER_BEGIN="# >>> act initialization >>>"
ACT_INIT_MARKER_END="# <<< act initialization <<<"

remove_shell_initialization() {
    shell="$(detect_shell)"
    config="$(detect_shell_config "$shell")"

    [ -n "$config" ] || return 0
    [ -f "$config" ] || return 0

    grep -Fq "$ACT_INIT_MARKER_BEGIN" "$config" ||
        return 0

    awk \
        -v begin="$ACT_INIT_MARKER_BEGIN" \
        -v end="$ACT_INIT_MARKER_END" '
        $0 == begin {
            skip = 1
            next
        }

        $0 == end {
            skip = 0
            next
        }

        !skip {
            print
        }
    ' "$config" > "${config}.act.tmp"

    mv "${config}.act.tmp" "$config"

    info "removed act PATH configuration from $config"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall_library() {
    info "uninstalling ${ACT_NAME}"

    if [ -d "$ACT_LIB_DIR" ]; then
        rm -rf "$ACT_LIB_DIR"
        info "removed $ACT_LIB_DIR"
    else
        info "$ACT_LIB_DIR does not exist"
    fi

    if [ -f "$ACT_MAIN" ]; then
        rm -f "$ACT_MAIN"
        info "removed $ACT_MAIN"
    fi

    if [ -f "$ACT_INSTALL" ]; then
        rm -f "$ACT_INSTALL"
        info "removed $ACT_INSTALL"
    fi

    remove_shell_initialization

    info "uninstallation complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

uninstall_library
