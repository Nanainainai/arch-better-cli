#!/usr/bin/env bash

# act/lib/parser.sh
#
# Generic argument parser for the act CLI library.
#
# Compatible with:
#   - Bash
#   - Zsh
#
# The parser knows about:
#   - actions
#   - flags
#   - subcommands
#   - positional arguments
#   - `--`
#
# It does NOT know what any particular action means.
#
# An action library registers its valid subcommands and flags before calling
# act_parse.
#
# Example:
#
#   ACT_PARSER_SUBCOMMANDS="pacman aur flatpak web"
#   ACT_PARSER_FLAGS="--dry-run --quiet"
#
#   act_parse "$@"
#
# Results:
#
#   ACT_PARSED_ACTION
#   ACT_PARSED_SUBCOMMANDS[]
#   ACT_PARSED_FLAGS[]
#   ACT_PARSED_ARGS[]
#
# ---------------------------------------------------------------------------
# Loading guard
# ---------------------------------------------------------------------------

if [ "${ACT_PARSER_LOADED:-0}" -eq 1 ]; then
    return 0 2>/dev/null || exit 0
fi

ACT_PARSER_LOADED=1

# ---------------------------------------------------------------------------
# Parser configuration
# ---------------------------------------------------------------------------
#
# The caller changes these before invoking act_parse.
#
# Example:
#
#   ACT_PARSER_SUBCOMMANDS="pacman aur flatpak web"
#   ACT_PARSER_FLAGS="-p -a -f -w"
#
# Long and short forms are both supported.
#
# A token is considered a subcommand only while the parser is still in the
# subcommand portion of the command line.
#
# Once the first positional argument is encountered, subsequent matching
# words are treated as arguments.
#
# Therefore:
#
#   install pacman aur firefox
#
# becomes:
#
#   subcommands = pacman aur
#   args        = firefox
#
# While:
#
#   install -- pacman
#
# becomes:
#
#   args = pacman
#
# This makes it possible to install an application literally named
# "pacman" by using `--`.

ACT_PARSER_SUBCOMMANDS="${ACT_PARSER_SUBCOMMANDS:-}"
ACT_PARSER_FLAGS="${ACT_PARSER_FLAGS:-}"

# Optional action name supplied by the caller.
ACT_PARSER_ACTION="${ACT_PARSER_ACTION:-}"

# ---------------------------------------------------------------------------
# Parsed state
# ---------------------------------------------------------------------------

ACT_PARSED_ACTION=""
ACT_PARSED_SUBCOMMANDS=()
ACT_PARSED_FLAGS=()
ACT_PARSED_ARGS=()

# Whether `--` was encountered.
ACT_PARSED_END_OF_OPTIONS=0

# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------

act_parser_reset() {
    ACT_PARSED_ACTION=""
    ACT_PARSED_SUBCOMMANDS=()
    ACT_PARSED_FLAGS=()
    ACT_PARSED_ARGS=()
    ACT_PARSED_END_OF_OPTIONS=0
}

# ---------------------------------------------------------------------------
# Membership helpers
# ---------------------------------------------------------------------------

act_parser_list_contains() {
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

act_parser_subcommand_allowed() {
    local value="$1"
    local item

    for item in $ACT_PARSER_SUBCOMMANDS; do
        if [ "$item" = "$value" ]; then
            return 0
        fi
    done

    return 1
}

act_parser_flag_allowed() {
    local value="$1"
    local item

    for item in $ACT_PARSER_FLAGS; do
        if [ "$item" = "$value" ]; then
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Parse one token
# ---------------------------------------------------------------------------

act_parser_handle_token() {
    local token="$1"
    local subcommands_started="$2"

    # -----------------------------------------------------------------------
    # End of options / subcommands.
    # -----------------------------------------------------------------------

    if [ "$token" = "--" ]; then
        ACT_PARSED_END_OF_OPTIONS=1
        return 0
    fi

    # -----------------------------------------------------------------------
    # After `--`, everything is an argument.
    # -----------------------------------------------------------------------

    if [ "$ACT_PARSED_END_OF_OPTIONS" -eq 1 ]; then
        ACT_PARSED_ARGS+=("$token")
        return 0
    fi

    # -----------------------------------------------------------------------
    # Explicit flags.
    # -----------------------------------------------------------------------

    if act_parser_flag_allowed "$token"; then
        ACT_PARSED_FLAGS+=("$token")
        return 0
    fi

    # -----------------------------------------------------------------------
    # Short flag clusters.
    #
    # Example:
    #
    #   -paf
    #
    # becomes:
    #
    #   -p
    #   -a
    #   -f
    #
    # This is enabled only when every individual character corresponds to
    # a registered short flag.
    # -----------------------------------------------------------------------

    case "$token" in
        -?*)
            if [ "${#token}" -gt 2 ]; then
                local cluster
                local i
                local short_flag

                cluster="${token#-}"
                i=1

                while [ "$i" -le "${#cluster}" ]; do
                    short_flag="-${cluster:$((i - 1)):1}"

                    if ! act_parser_flag_allowed "$short_flag"; then
                        break
                    fi

                    i=$((i + 1))
                done

                if [ "$i" -gt "${#cluster}" ]; then
                    i=1

                    while [ "$i" -le "${#cluster}" ]; do
                        short_flag="-${cluster:$((i - 1)):1}"
                        ACT_PARSED_FLAGS+=("$short_flag")
                        i=$((i + 1))
                    done

                    return 0
                fi
            fi
            ;;
    esac

    # -----------------------------------------------------------------------
    # Registered subcommands.
    #
    # Subcommands are only recognized before the first application/positional
    # argument.
    # -----------------------------------------------------------------------

    if [ "$subcommands_started" -eq 1 ]; then
        if act_parser_subcommand_allowed "$token"; then
            ACT_PARSED_SUBCOMMANDS+=("$token")
            return 0
        fi
    fi

    # -----------------------------------------------------------------------
    # Everything else is a positional argument.
    # -----------------------------------------------------------------------

    ACT_PARSED_ARGS+=("$token")

    return 0
}

# ---------------------------------------------------------------------------
# Main parser
# ---------------------------------------------------------------------------
#
# Usage:
#
#   ACT_PARSER_SUBCOMMANDS="pacman aur flatpak web"
#   ACT_PARSER_FLAGS="-p -a -f -w --dry-run"
#   act_parse "$@"
#
# The first positional token can optionally be treated as the action when
# ACT_PARSER_ACTION is empty.
#
# Example:
#
#   act_parse install pacman firefox
#
# produces:
#
#   ACTION       = install
#   SUBCOMMANDS  = pacman
#   ARGS         = firefox
#
# If the caller already knows the action:
#
#   ACT_PARSER_ACTION=install
#   act_parse pacman firefox
#
# produces the same result.

act_parse() {
    act_parser_reset

    local token
    local first_token=1
    local subcommands_started=1

    # -----------------------------------------------------------------------
    # Determine action.
    # -----------------------------------------------------------------------

    if [ -n "$ACT_PARSER_ACTION" ]; then
        ACT_PARSED_ACTION="$ACT_PARSER_ACTION"
    elif [ "$#" -gt 0 ]; then
        case "$1" in
            -*)
                ;;
            *)
                ACT_PARSED_ACTION="$1"
                shift
                ;;
        esac
    fi

    # -----------------------------------------------------------------------
    # Parse remaining tokens.
    # -----------------------------------------------------------------------

    for token in "$@"; do
        # Once a positional argument has appeared, we no longer interpret
        # source/subcommand names as subcommands.
        #
        # Flags remain valid after positional arguments.
        #
        # This allows:
        #
        #   install firefox -p
        #
        # while preventing:
        #
        #   install firefox pacman
        #
        # from silently changing `pacman` into a source selector.

        if [ "$subcommands_started" -eq 1 ]; then
            case "$token" in
                -*)
                    act_parser_handle_token "$token" 1
                    ;;

                *)
                    if act_parser_subcommand_allowed "$token"; then
                        act_parser_handle_token "$token" 1
                    else
                        subcommands_started=0
                        act_parser_handle_token "$token" 0
                    fi
                    ;;
            esac
        else
            act_parser_handle_token "$token" 0
        fi

        first_token=0
    done

    return 0
}

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

act_parser_require_action() {
    local expected="$1"

    if [ "$ACT_PARSED_ACTION" != "$expected" ]; then
        return 1
    fi

    return 0
}

act_parser_has_subcommand() {
    local needle="$1"

    act_parser_list_contains \
        "$needle" \
        "${ACT_PARSED_SUBCOMMANDS[@]}"
}

act_parser_has_flag() {
    local needle="$1"

    act_parser_list_contains \
        "$needle" \
        "${ACT_PARSED_FLAGS[@]}"
}

# ---------------------------------------------------------------------------
# Flag aliases
# ---------------------------------------------------------------------------
#
# Useful when an action wants:
#
#   install == -i
#
# without making the parser itself understand that relationship.
#
# Example:
#
#   act_parser_flag_matches install -i "$ACT_PARSED_FLAGS"
#
# returns success if either form is present.

act_parser_flag_matches() {
    local long_form="$1"
    local short_form="$2"
    shift 2

    local flag

    for flag in "$@"; do
        if [ "$flag" = "$long_form" ] ||
           [ "$flag" = "$short_form" ]; then
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Subcommand aliases
# ---------------------------------------------------------------------------
#
# Same idea as flag aliases.
#
# Example:
#
#   act_parser_subcommand_matches pacman -p "$ACT_PARSED_SUBCOMMANDS"
#
# Note that the parser should normally register both forms as valid
# subcommands if both are supposed to be accepted directly.
#
# This helper is useful when the implementation wants to normalize them.

act_parser_subcommand_matches() {
    local long_form="$1"
    local short_form="$2"
    shift 2

    local subcommand

    for subcommand in "$@"; do
        if [ "$subcommand" = "$long_form" ] ||
           [ "$subcommand" = "$short_form" ]; then
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------
#
# Convert aliases into canonical values.
#
# This is intentionally separate from parsing.
#
# Parser:
#
#   preserves what the user typed
#
# Normalizer:
#
#   converts aliases to canonical internal names
#
# This distinction is useful for error messages and future command logging.

act_parser_normalize_subcommands() {
    local -a normalized
    local item

    normalized=()

    for item in "${ACT_PARSED_SUBCOMMANDS[@]}"; do
        case "$item" in
            pacman|-p)
                normalized+=("pacman")
                ;;

            aur|-a)
                normalized+=("aur")
                ;;

            flatpak|-f)
                normalized+=("flatpak")
                ;;

            web|-w)
                normalized+=("web")
                ;;

            *)
                normalized+=("$item")
                ;;
        esac
    done

    ACT_PARSED_SUBCOMMANDS=("${normalized[@]}")
}

# ---------------------------------------------------------------------------
# Debug dump
# ---------------------------------------------------------------------------

act_parser_dump() {
    printf 'action: %s\n' "$ACT_PARSED_ACTION"

    printf 'subcommands:\n'
    local item

    for item in "${ACT_PARSED_SUBCOMMANDS[@]}"; do
        printf '  %s\n' "$item"
    done

    printf 'flags:\n'

    for item in "${ACT_PARSED_FLAGS[@]}"; do
        printf '  %s\n' "$item"
    done

    printf 'args:\n'

    for item in "${ACT_PARSED_ARGS[@]}"; do
        printf '  %s\n' "$item"
    done

    printf 'end_of_options: %s\n' "$ACT_PARSED_END_OF_OPTIONS"
}
