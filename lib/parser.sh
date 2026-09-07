#!/usr/bin/env bash
#
# act/lib/parser.sh
#
# Generic command-line parser for Bash and Zsh.
#
# Responsibilities:
#   - expand configured internal action aliases
#   - identify the action
#   - recognize configured subcommands
#   - recognize configured flags
#   - preserve positional arguments
#   - handle `--`
#
# This parser does NOT:
#   - execute commands
#   - expand external aliases
#   - know about pacman, AUR, Flatpak, etc.
#   - define action-specific aliases
#   - normalize action-specific subcommands
#
# Internal aliases come from:
#
#   tools/alias/alias.config
#
# Example:
#
#   i `install` `-i` `ins`
#
# Which means:
#
#   -i  -> install
#   ins -> install
#


if [[ -n "${ACT_PARSER_LOADED:-}" ]]; then
    return 0
fi

ACT_PARSER_LOADED=1


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
#
# ACT_PARSER_ACTION
#   Optional fixed action for parsers that are already operating inside
#   one action.
#
#   Example:
#
#       ACT_PARSER_ACTION=install
#
# ACT_PARSER_ACTIONS
#   List of valid actions when the parser is being used as a dispatcher.
#
#   Example:
#
#       ACT_PARSER_ACTIONS=(install)
#
# ACT_PARSER_FLAGS
#   Flags understood by the current action/dispatcher.
#
# ACT_PARSER_SUBCOMMANDS
#   Subcommands understood by the current action/dispatcher.
#

ACT_PARSER_ACTION="${ACT_PARSER_ACTION:-}"

ACT_PARSER_ACTIONS=()
ACT_PARSER_FLAGS=()
ACT_PARSER_SUBCOMMANDS=()


# ---------------------------------------------------------------------------
# Parsed state
# ---------------------------------------------------------------------------

ACT_PARSED_ACTION=""

ACT_PARSED_SUBCOMMANDS=()
ACT_PARSED_FLAGS=()
ACT_PARSED_ARGS=()

ACT_PARSED_END_OF_OPTIONS=0


# ---------------------------------------------------------------------------
# Alias support
# ---------------------------------------------------------------------------

ACT_PARSER_ALIASES_LOADED=0


act_parser_load_aliases()
{
    local parser_dir
    local library_root
    local alias_file

    [[ "$ACT_PARSER_ALIASES_LOADED" -eq 1 ]] && return 0

    parser_dir="$(
        CDPATH= cd -- \
        "$(dirname -- "${BASH_SOURCE[0]}")" \
        && pwd
    )"

    library_root="$(
        CDPATH= cd -- \
        "$parser_dir/.." \
        && pwd
    )"

    alias_file="$library_root/tools/alias/alias.sh"

    if [[ -f "$alias_file" ]]; then
        # shellcheck disable=SC1090
        source "$alias_file"
    fi

    ACT_PARSER_ALIASES_LOADED=1

    return 0
}


# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------

act_parser_reset()
{
    ACT_PARSED_ACTION=""

    ACT_PARSED_SUBCOMMANDS=()
    ACT_PARSED_FLAGS=()
    ACT_PARSED_ARGS=()

    ACT_PARSED_END_OF_OPTIONS=0
}


# ---------------------------------------------------------------------------
# Generic list helpers
# ---------------------------------------------------------------------------

act_parser_list_contains()
{
    local wanted="${1:-}"
    shift

    local item

    for item in "$@"; do
        [[ "$item" == "$wanted" ]] && return 0
    done

    return 1
}


act_parser_subcommand_allowed()
{
    local token="${1:-}"

    act_parser_list_contains \
        "$token" \
        "${ACT_PARSER_SUBCOMMANDS[@]}"
}


act_parser_flag_allowed()
{
    local token="${1:-}"

    act_parser_list_contains \
        "$token" \
        "${ACT_PARSER_FLAGS[@]}"
}


act_parser_action_allowed()
{
    local token="${1:-}"

    act_parser_list_contains \
        "$token" \
        "${ACT_PARSER_ACTIONS[@]}"
}


# ---------------------------------------------------------------------------
# Internal action alias lookup
# ---------------------------------------------------------------------------
#
# Internal aliases are configured externally in alias.config:
#
#   i `install` `-i` `ins`
#
# Therefore:
#
#   -i  -> install
#   ins -> install
#
# The generic parser does not know that "-i" means install.
# It asks alias.sh.
#
# Internal aliases are only relevant while identifying the action.
# They are NOT expanded after an action has already been selected.
#

act_parser_expand_internal_action()
{
    local token="${1:-}"
    local canonical=""

    if declare -F act_alias_internal_lookup >/dev/null 2>&1; then
        if canonical="$(act_alias_internal_lookup "$token")"; then
            printf '%s\n' "$canonical"
            return 0
        fi
    fi

    printf '%s\n' "$token"
}


# ---------------------------------------------------------------------------
# Resolve action token
# ---------------------------------------------------------------------------
#
# Returns the canonical action through stdout.
#
# Examples:
#
#   install -> install
#   -i      -> install
#   ins     -> install
#
# If the token is not an internal alias, it is returned unchanged.
#

act_parser_resolve_action()
{
    local token="${1:-}"
    local canonical

    canonical="$(
        act_parser_expand_internal_action "$token"
    )"

    printf '%s\n' "$canonical"
}


# ---------------------------------------------------------------------------
# Handle action
# ---------------------------------------------------------------------------
#
# The first action-capable token is consumed as the action.
#
# If ACT_PARSER_ACTION is configured, only that exact action is accepted.
#
# Internal aliases are resolved before this function is called.
#

act_parser_handle_action()
{
    local token="${1:-}"

    [[ -n "$ACT_PARSED_ACTION" ]] && return 1

    # Fixed-action parser.
    if [[ -n "$ACT_PARSER_ACTION" ]]; then
        if [[ "$token" == "$ACT_PARSER_ACTION" ]]; then
            ACT_PARSED_ACTION="$ACT_PARSER_ACTION"
            return 0
        fi

        return 1
    fi

    # Dispatcher parser.
    if act_parser_action_allowed "$token"; then
        ACT_PARSED_ACTION="$token"
        return 0
    fi

    return 1
}


# ---------------------------------------------------------------------------
# Handle flags
# ---------------------------------------------------------------------------
#
# Exact flags:
#
#   -p
#   --verbose
#
# Short clusters:
#
#   -paf
#
# become:
#
#   -p
#   -a
#   -f
#
# A cluster is accepted only when every character is a configured
# short flag.
#

act_parser_handle_flag()
{
    local token="${1:-}"

    local cluster
    local i
    local flag
    local valid

    [[ "$token" == -* ]] || return 1
    [[ "$token" != "-" ]] || return 1

    # Exact configured flag.
    if act_parser_flag_allowed "$token"; then
        ACT_PARSED_FLAGS+=("$token")
        return 0
    fi

    # Long unknown flags are not treated as clusters.
    if [[ "$token" == --* ]]; then
        return 1
    fi

    # Short flag cluster.
    #
    # "-paf" -> "-p" "-a" "-f"
    #
    if [[ "$token" =~ ^-[^-].+ ]]; then
        cluster="${token#-}"
        valid=1

        for ((i = 0; i < ${#cluster}; i++)); do
            flag="-${cluster:i:1}"

            if ! act_parser_flag_allowed "$flag"; then
                valid=0
                break
            fi
        done

        if [[ "$valid" -eq 1 ]]; then
            for ((i = 0; i < ${#cluster}; i++)); do
                ACT_PARSED_FLAGS+=(
                    "-${cluster:i:1}"
                )
            done

            return 0
        fi
    fi

    return 1
}


# ---------------------------------------------------------------------------
# Handle subcommands
# ---------------------------------------------------------------------------
#
# Subcommands are recognized only before the first positional argument.
#
# Example:
#
#   tool foo bar
#
# If "foo" is a configured subcommand:
#
#   subcommands = foo
#   args        = bar
#
# Once a positional argument has been encountered, subsequent tokens
# remain positional arguments.
#

act_parser_handle_subcommand()
{
    local token="${1:-}"

    [[ "${#ACT_PARSED_ARGS[@]}" -eq 0 ]] || return 1

    if act_parser_subcommand_allowed "$token"; then
        ACT_PARSED_SUBCOMMANDS+=("$token")
        return 0
    fi

    return 1
}


# ---------------------------------------------------------------------------
# Handle one token
# ---------------------------------------------------------------------------

act_parser_handle_token()
{
    local token="${1:-}"

    # ---------------------------------------------------------------
    # Everything after `--` is positional.
    # ---------------------------------------------------------------

    if [[ "$ACT_PARSED_END_OF_OPTIONS" -eq 1 ]]; then
        ACT_PARSED_ARGS+=("$token")
        return 0
    fi


    # ---------------------------------------------------------------
    # `--`
    # ---------------------------------------------------------------

    if [[ "$token" == "--" ]]; then
        ACT_PARSED_END_OF_OPTIONS=1
        return 0
    fi


    # ---------------------------------------------------------------
    # Action
    # ---------------------------------------------------------------
    #
    # Action aliases have already been resolved by act_parse().
    #
    # Example:
    #
    #   -i firefox
    #
    # becomes:
    #
    #   install firefox
    #
    # Important:
    #
    # Action resolution happens only until an action is selected.
    # Once ACT_PARSED_ACTION is populated, later tokens cannot become
    # actions.
    #

    if [[ -z "$ACT_PARSED_ACTION" ]]; then
        if act_parser_handle_action "$token"; then
            return 0
        fi
    fi


    # ---------------------------------------------------------------
    # Flags
    # ---------------------------------------------------------------

    if [[ "$token" == -* && "$token" != "-" ]]; then
        if act_parser_handle_flag "$token"; then
            return 0
        fi

        # Unknown flags are preserved.
        ACT_PARSED_ARGS+=("$token")
        return 0
    fi


    # ---------------------------------------------------------------
    # Subcommand
    # ---------------------------------------------------------------

    if act_parser_handle_subcommand "$token"; then
        return 0
    fi


    # ---------------------------------------------------------------
    # Positional argument
    # ---------------------------------------------------------------

    ACT_PARSED_ARGS+=("$token")
}


# ---------------------------------------------------------------------------
# Main parser
# ---------------------------------------------------------------------------

act_parse()
{
    local token
    local expanded

    act_parser_reset
    act_parser_load_aliases


    for token in "$@"; do

        # -----------------------------------------------------------
        # Internal aliases are action aliases.
        #
        # Only resolve them while an action has not yet been selected.
        #
        # This prevents:
        #
        #   install -i firefox
        #
        # from becoming:
        #
        #   install install firefox
        #
        # while still allowing:
        #
        #   -i firefox
        #   ins firefox
        #
        # to become:
        #
        #   install firefox
        # -----------------------------------------------------------

        if [[ -z "$ACT_PARSED_ACTION" &&
              "$ACT_PARSED_END_OF_OPTIONS" -eq 0 ]]; then

            expanded="$(
                act_parser_resolve_action "$token"
            )

        else
            expanded="$token"
        fi

        act_parser_handle_token "$expanded"
    done

    return 0
}


# ---------------------------------------------------------------------------
# Require action
# ---------------------------------------------------------------------------

act_parser_require_action()
{
    if [[ -z "$ACT_PARSED_ACTION" ]]; then

        if declare -F act_error >/dev/null 2>&1; then
            act_error "No action specified."
        else
            printf '%s\n' \
                "act: error: No action specified." \
                >&2
        fi

        return 1
    fi

    return 0
}


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

act_parser_has_subcommand()
{
    local wanted="${1:-}"

    act_parser_list_contains \
        "$wanted" \
        "${ACT_PARSED_SUBCOMMANDS[@]}"
}


act_parser_has_flag()
{
    local wanted="${1:-}"

    act_parser_list_contains \
        "$wanted" \
        "${ACT_PARSED_FLAGS[@]}"
}


act_parser_flag_matches()
{
    local wanted="${1:-}"
    shift

    local flag

    for flag in "$@"; do
        [[ "$flag" == "$wanted" ]] && return 0
    done

    return 1
}


act_parser_subcommand_matches()
{
    local wanted="${1:-}"
    shift

    local subcommand

    for subcommand in "$@"; do
        [[ "$subcommand" == "$wanted" ]] && return 0
    done

    return 1
}


# ---------------------------------------------------------------------------
# Action normalization
# ---------------------------------------------------------------------------
#
# Action aliases are already resolved during parsing.
#
# Action-specific normalization does NOT belong here.
#

act_parser_normalize_action()
{
    return 0
}


# ---------------------------------------------------------------------------
# Subcommand normalization
# ---------------------------------------------------------------------------
#
# No normalization belongs in the generic parser.
#
# If an action needs:
#
#   -p -> pacman
#   -a -> aur
#
# that action should normalize its own parsed state.
#

act_parser_normalize_subcommands()
{
    return 0
}


# ---------------------------------------------------------------------------
# Debug output
# ---------------------------------------------------------------------------

act_parser_dump()
{
    local item

    printf 'action: %s\n' \
        "$ACT_PARSED_ACTION"


    printf 'subcommands:'

    for item in "${ACT_PARSED_SUBCOMMANDS[@]}"; do
        printf ' %s' "$item"
    done

    printf '\n'


    printf 'flags:'

    for item in "${ACT_PARSED_FLAGS[@]}"; do
        printf ' %s' "$item"
    done

    printf '\n'


    printf 'args:'

    for item in "${ACT_PARSED_ARGS[@]}"; do
        printf ' %s' "$item"
    done

    printf '\n'


    printf 'end_of_options: %s\n' \
        "$ACT_PARSED_END_OF_OPTIONS"
}
