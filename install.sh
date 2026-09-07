#!/usr/bin/env bash

# act/install.sh
#
# Installer for the act CLI library.
#
# This script installs the library and its shell integration.
# It does NOT implement the `install` action itself.
#
# Supported shells:
#   - Bash
#   - Zsh
#
# Typical usage:
#
#   ./install.sh
#   ./install.sh --prefix ~/.local
#   ./install.sh --uninstall
#
# After installation:
#
#   source ~/.local/share/act/act.sh
#
# or let the installer add the appropriate shell initialization.

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ACT_NAME="act"

DEFAULT_PREFIX="${HOME}/.local"
PREFIX="$DEFAULT_PREFIX"

UNINSTALL=0
NO_SHELL_CONFIG=0
VERBOSE=0

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

verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf 'act: %s\n' "$*"
    fi
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage:
    ./install.sh [options]

Options:
    --prefix DIR       Installation prefix
    --no-shell-config  Do not modify shell configuration
    --uninstall        Remove act
    -v, --verbose      Verbose output
    -h, --help         Show this help

Default prefix:
    ~/.local

Installed files:
    ~/.local/share/act/
    ~/.local/bin/install
    ~/.local/bin/act

The installed library can be used from both Bash and Zsh.
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

        --no-shell-config)
            NO_SHELL_CONFIG=1
            shift
            ;;

        --uninstall)
            UNINSTALL=1
            shift
            ;;

        -v|--verbose)
            VERBOSE=1
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

ACT_INIT_FILE="${ACT_LIB_DIR}/act.sh"
ACT_COMMAND="${ACT_BIN_DIR}/act"
INSTALL_COMMAND="${ACT_BIN_DIR}/install"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[ -d "$SCRIPT_DIR" ] ||
    error "could not determine project directory"

[ -f "$SCRIPT_DIR/act.sh" ] ||
    error "missing act.sh"

[ -d "$SCRIPT_DIR/lib" ] ||
    error "missing lib directory"

[ -d "$SCRIPT_DIR/bin" ] ||
    error "missing bin directory"

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

add_shell_initialization() {
    [ "$NO_SHELL_CONFIG" -eq 0 ] || return 0

    shell="$(detect_shell)"
    config="$(detect_shell_config "$shell")"

    case "$shell" in
        bash|zsh)
            ;;
        *)
            warn "could not determine Bash/Zsh configuration file"
            warn "add this manually to your shell configuration:"
            warn "source \"${ACT_INIT_FILE}\""
            return 0
            ;;
    esac

    [ -n "$config" ] || return 0

    mkdir -p "$(dirname "$config")"
    touch "$config"

    if grep -Fq "$ACT_INIT_MARKER_BEGIN" "$config"; then
        verbose "shell initialization already exists in $config"
        return 0
    fi

    {
        printf '\n%s\n' "$ACT_INIT_MARKER_BEGIN"
        printf 'source "%s"\n' "$ACT_INIT_FILE"
        printf '%s\n' "$ACT_INIT_MARKER_END"
    } >> "$config"

    info "updated $config"
}

remove_shell_initialization() {
    shell="$(detect_shell)"
    config="$(detect_shell_config "$shell")"

    [ -n "$config" ] || return 0
    [ -f "$config" ] || return 0

    grep -Fq "$ACT_INIT_MARKER_BEGIN" "$config" ||
        return 0

    awk -v begin="$ACT_INIT_MARKER_BEGIN" \
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

    info "removed act initialization from $config"
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

install_library() {
    info "installing ${ACT_NAME}"

    mkdir -p "$ACT_LIB_DIR"
    mkdir -p "$ACT_BIN_DIR"

    verbose "source: $SCRIPT_DIR"
    verbose "library: $ACT_LIB_DIR"
    verbose "bin: $ACT_BIN_DIR"

    # Copy the library.
    cp -R "$SCRIPT_DIR/lib" "$ACT_LIB_DIR/"
    cp "$SCRIPT_DIR/act.sh" "$ACT_INIT_FILE"

    # Copy auxiliary shell/runtime files if present.
    if [ -d "$SCRIPT_DIR/share" ]; then
        cp -R "$SCRIPT_DIR/share" "$ACT_LIB_DIR/"
    fi

    # -----------------------------------------------------------------------
    # `act`
    #
    # This is the future dispatcher/entry point.
    # -----------------------------------------------------------------------

    if [ -f "$SCRIPT_DIR/bin/act" ]; then
        cp "$SCRIPT_DIR/bin/act" "$ACT_COMMAND"
        chmod +x "$ACT_COMMAND"
    fi

    # -----------------------------------------------------------------------
    # `install`
    #
    # This is the public top-level install action.
    #
    # It is deliberately separate from this installer script.
    # -----------------------------------------------------------------------

    if [ -f "$SCRIPT_DIR/bin/install" ]; then
        cp "$SCRIPT_DIR/bin/install" "$INSTALL_COMMAND"
        chmod +x "$INSTALL_COMMAND"
    fi

    # Make sure the library entry point is readable.
    chmod 644 "$ACT_INIT_FILE"

    info "installed to $ACT_LIB_DIR"
}

# ---------------------------------------------------------------------------
# Uninstallation
# ---------------------------------------------------------------------------

uninstall_library() {
    info "uninstalling ${ACT_NAME}"

    if [ -d "$ACT_LIB_DIR" ]; then
        rm -rf "$ACT_LIB_DIR"
        info "removed $ACT_LIB_DIR"
    fi

    if [ -f "$ACT_COMMAND" ]; then
        rm -f "$ACT_COMMAND"
        info "removed $ACT_COMMAND"
    fi

    if [ -f "$INSTALL_COMMAND" ]; then
        rm -f "$INSTALL_COMMAND"
        info "removed $INSTALL_COMMAND"
    fi

    remove_shell_initialization

    info "uninstallation complete"
}

# ---------------------------------------------------------------------------
# PATH check
# ---------------------------------------------------------------------------

check_path() {
    case ":${PATH:-}:" in
        *":${ACT_BIN_DIR}:"*)
            return 0
            ;;
    esac

    warn "${ACT_BIN_DIR} is not in PATH"

    shell="$(detect_shell)"

    case "$shell" in
        zsh|bash)
            warn "add this to your shell configuration:"
            warn "export PATH=\"${ACT_BIN_DIR}:\$PATH\""
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    uninstall_library
    exit 0
fi

install_library
add_shell_initialization
check_path

printf '\n'
info "installation complete"
printf '\n'

cat <<EOF
  Library:
    ${ACT_LIB_DIR}

  Entry point:
    ${ACT_INIT_FILE}

  Commands:
    ${ACT_COMMAND}
    ${INSTALL_COMMAND}

  Current shell:
    $(detect_shell)

  Try:
    source "${ACT_INIT_FILE}"
    install --help
EOF
