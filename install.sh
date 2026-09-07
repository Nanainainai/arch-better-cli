```bash
#!/usr/bin/env bash

# act/install.sh
#
# Bootstrap installer for the act CLI library.
#
# This script installs the act library itself.
# It does NOT implement the runtime `install` action.
#
# Supported shells:
#   - Bash
#   - Zsh
#
# Typical usage:
#
#   ./install.sh
#   ./install.sh --prefix ~/.local
#   ./install.sh --no-shell-config
#
# Uninstallation is handled by:
#
#   ./uninstall.sh
#
# After installation:
#
#   act --help
#   install --help

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ACT_NAME="act"

DEFAULT_PREFIX="${HOME}/.local"
PREFIX="$DEFAULT_PREFIX"

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
    -v, --verbose      Verbose output
    -h, --help         Show this help

Default prefix:
    ~/.local

Installed files:
    ~/.local/share/act/
    ~/.local/bin/act
    ~/.local/bin/install

The installed CLI works from both Bash and Zsh.

Uninstallation:
    ./uninstall.sh
    ./uninstall.sh --prefix ~/.local
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

ACT_MAIN="${ACT_BIN_DIR}/act"
ACT_INSTALL="${ACT_BIN_DIR}/install"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[ -d "$SCRIPT_DIR" ] ||
    error "could not determine project directory"

[ -d "$SCRIPT_DIR/lib" ] ||
    error "missing lib directory"

[ -f "$SCRIPT_DIR/lib/core.sh" ] ||
    error "missing lib/core.sh"

[ -f "$SCRIPT_DIR/lib/parser.sh" ] ||
    error "missing lib/parser.sh"

[ -f "$SCRIPT_DIR/lib/install.sh" ] ||
    error "missing lib/install.sh"

[ -d "$SCRIPT_DIR/tools" ] ||
    error "missing tools directory"

[ -f "$SCRIPT_DIR/tools/alias/alias.sh" ] ||
    error "missing tools/alias/alias.sh"

[ -f "$SCRIPT_DIR/tools/alias/alias.config" ] ||
    error "missing tools/alias/alias.config"

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
            warn "export PATH=\"${ACT_BIN_DIR}:\$PATH\""
            return 0
            ;;
    esac

    [ -n "$config" ] || return 0

    mkdir -p "$(dirname "$config")"
    touch "$config"

    # ---------------------------------------------------------------
    # Update an existing act block if one exists.
    # ---------------------------------------------------------------

    if grep -Fq "$ACT_INIT_MARKER_BEGIN" "$config"; then
        verbose "act shell initialization already exists in $config"
        return 0
    fi

    {
        printf '\n%s\n' "$ACT_INIT_MARKER_BEGIN"
        printf 'export PATH="%s:$PATH"\n' "$ACT_BIN_DIR"
        printf '%s\n' "$ACT_INIT_MARKER_END"
    } >> "$config"

    info "updated $config"
}

# ---------------------------------------------------------------------------
# Generate `act`
# ---------------------------------------------------------------------------
#
# The generated executable is intentionally small.
#
# It:
#   1. loads core
#   2. loads parser
#   3. loads aliases
#   4. loads available actions
#   5. identifies the action
#   6. dispatches the action with the original ordered arguments
#
# IMPORTANT:
#
# The dispatcher must NOT reconstruct the arguments from:
#
#   ACT_PARSED_SUBCOMMANDS
#   ACT_PARSED_FLAGS
#   ACT_PARSED_ARGS
#
# Doing so changes argument ordering and breaks action-specific syntax
# such as:
#
#   install -p -a firefox -f spotify
#
# Instead, the dispatcher identifies the action and then passes the original
# arguments after that action directly to the action implementation.
#

generate_act_command() {
    cat > "$ACT_MAIN" <<EOF
#!/usr/bin/env bash

ACT_LIB_DIR="${ACT_LIB_DIR}"

source "\${ACT_LIB_DIR}/lib/core.sh"
source "\${ACT_LIB_DIR}/tools/alias/alias.sh"
source "\${ACT_LIB_DIR}/lib/parser.sh"

# Load all installed action modules that exist.
for _act_action in "\${ACT_LIB_DIR}/lib/"*.sh; do
    [ -f "\$_act_action" ] || continue

    case "\$_act_action" in
        "\${ACT_LIB_DIR}/lib/core.sh")
            continue
            ;;

        "\${ACT_LIB_DIR}/lib/parser.sh")
            continue
            ;;

        *)
            source "\$_act_action"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Parser configuration
# ---------------------------------------------------------------------------
#
# The generic parser only needs to know about actions here.
#
# Install-specific source selectors such as:
#
#   pacman
#   aur
#   flatpak
#   web
#   -p
#   -a
#   -f
#   -w
#
# are interpreted by lib/install.sh.
#
# Keeping them out of the generic parser prevents install-specific syntax
# from becoming global act syntax.
#

ACT_PARSER_ACTIONS=(
    install
)

# ---------------------------------------------------------------------------
# Preserve the original argv.
# ---------------------------------------------------------------------------
#
# The action parser may inspect the arguments, but action-specific modules
# need the original ordering.
#
# Example:
#
#   act install -p -a firefox -f spotify
#
# must reach act_install as:
#
#   -p -a firefox -f spotify
#
# and NOT as:
#
#   pacman aur flatpak firefox spotify
#
# because install source selectors are scoped by their position.
#

_act_original_args=( "\$@" )

act_parse "\$@"

if ! act_parser_require_action; then
    exit 2
fi

case "\$ACT_PARSED_ACTION" in
    install)
        # Remove the action from the original argv.
        # Everything after it is passed unchanged to act_install.
        if [ "\${#_act_original_args[@]}" -gt 0 ]; then
            _act_original_args=( "\${_act_original_args[@]:1}" )
        fi

        act_install "\${_act_original_args[@]}"
        ;;

    *)
        act_error "Unknown action: \$ACT_PARSED_ACTION"
        exit 2
        ;;
esac
EOF

    chmod +x "$ACT_MAIN"

    verbose "generated $ACT_MAIN"
}

# ---------------------------------------------------------------------------
# Generate `install`
# ---------------------------------------------------------------------------
#
# `install` is a convenience executable for the install action.
#
# It bypasses action selection and invokes the same runtime implementation.
#
# Therefore:
#
#   install firefox
#
# and:
#
#   act install firefox
#
# both reach act_install.
#
# The arguments are passed unchanged.

generate_install_command() {
    cat > "$ACT_INSTALL" <<EOF
#!/usr/bin/env bash

ACT_LIB_DIR="${ACT_LIB_DIR}"

source "\${ACT_LIB_DIR}/lib/core.sh"
source "\${ACT_LIB_DIR}/tools/alias/alias.sh"
source "\${ACT_LIB_DIR}/lib/parser.sh"
source "\${ACT_LIB_DIR}/lib/install.sh"

act_install "\$@"
EOF

    chmod +x "$ACT_INSTALL"

    verbose "generated $ACT_INSTALL"
}

# ---------------------------------------------------------------------------
# Install library
# ---------------------------------------------------------------------------

install_library() {
    info "installing ${ACT_NAME}"

    mkdir -p "$ACT_LIB_DIR"
    mkdir -p "$ACT_BIN_DIR"

    verbose "source: $SCRIPT_DIR"
    verbose "library: $ACT_LIB_DIR"
    verbose "bin: $ACT_BIN_DIR"

    # ---------------------------------------------------------------
    # Library
    # ---------------------------------------------------------------

    rm -rf "$ACT_LIB_DIR/lib"
    cp -R "$SCRIPT_DIR/lib" "$ACT_LIB_DIR/"

    # ---------------------------------------------------------------
    # Tools
    # ---------------------------------------------------------------

    rm -rf "$ACT_LIB_DIR/tools"
    cp -R "$SCRIPT_DIR/tools" "$ACT_LIB_DIR/"

    # ---------------------------------------------------------------
    # Optional share directory
    # ---------------------------------------------------------------

    if [ -d "$SCRIPT_DIR/share" ]; then
        rm -rf "$ACT_LIB_DIR/share"
        cp -R "$SCRIPT_DIR/share" "$ACT_LIB_DIR/"
    fi

    # ---------------------------------------------------------------
    # Generate public commands
    # ---------------------------------------------------------------

    generate_act_command
    generate_install_command

    info "installed library to $ACT_LIB_DIR"
    info "installed act to $ACT_MAIN"
    info "installed install to $ACT_INSTALL"
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

    warn "${ACT_BIN_DIR} is not currently in PATH"

    shell="$(detect_shell)"

    case "$shell" in
        zsh|bash)
            warn "restart your shell or run:"
            warn "source \"$(detect_shell_config "$shell")\""
            ;;

        *)
            warn "add this to your shell configuration:"
            warn "export PATH=\"${ACT_BIN_DIR}:\$PATH\""
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

install_library
add_shell_initialization
check_path

printf '\n'

info "installation complete"

printf '\n'

cat <<EOF
  Library:
    ${ACT_LIB_DIR}

  Commands:
    ${ACT_MAIN}
    ${ACT_INSTALL}

  PATH:
    ${ACT_BIN_DIR}

  Try:
    act --help
    install --help
    act install --help
EOF
```
