#!/usr/bin/env bash
#
# act/lib/parser.sh
#
# Generic command-line parser for Bash and Zsh.
#
# Responsibilities:
#   - expand internal act aliases
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
# ACT_PARSER_ACTIONS
#   List of valid actions when the parser is being used as a dispatcher.
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
    local library_root
    local alias_file

    [[ "$ACT_PARSER_ALIASES_LOADED" -eq 1 ]] && return 0

    library_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    alias_file="$library_root/tools/alias/alias.sh"

    if [[ -f "$alias_file" ]]; then
        # shellcheck disable=SC1090
        source "$alias_file"
    fi

    ACT_PARSER_ALIASES_LOADED=1
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
# Internal alias expansion
# ---------------------------------------------------------------------------
#
# Internal aliases have this form in alias.config:
#
#   i `install` `-i` `ins`
#
# Therefore:
#
#   -i -> install
#   ins -> install
#
# Only the alias token itself is replaced.
#
# External aliases are intentionally NOT handled here.
#

act_parser_expand_internal_alias()
{
    local token="${1:-}"
    local canonical

    if declare -F act_alias_internal_lookup >/dev/null 2>&1; then
        if canonical="$(act_alias_internal_lookup "$token")"; then
            printf '%s\n' "$canonical"
            return 0
        fi
    fi

    printf '%s\n' "$token"
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
    # If ACT_PARSER_ACTION is configured, the parser expects that
    # action and does not consume arbitrary tokens as actions.
    #
    # Otherwise, an explicitly allowed action can be consumed.
    #

    if [[ -z "$ACT_PARSED_ACTION" ]]; then

        if [[ -n "$ACT_PARSER_ACTION" &&
              "$token" == "$ACT_PARSER_ACTION" ]]; then

            ACT_PARSED_ACTION="$token"
            return 0
        fi

        if act_parser_action_allowed "$token"; then
            ACT_PARSED_ACTION="$token"
            return 0
        fi
    fi


    # ---------------------------------------------------------------
    # Flags
    # ---------------------------------------------------------------
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
    #   -p -a -f
    #
    # A cluster is accepted only when every character is a configured
    # short flag.
    #

    if [[ "$token" == -* && "$token" != "-" ]]; then

        # Exact configured flag.
        if act_parser_flag_allowed "$token"; then
            ACT_PARSED_FLAGS+=("$token")
            return 0
        fi


        # Short flag cluster.
        if [[ "$token" =~ ^-[^-].+ ]]; then

            local cluster="${token#-}"
            local i
            local flag
            local valid=1

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


        # Unknown flags are preserved rather than silently discarded.
        ACT_PARSED_ARGS+=("$token")
        return 0
    fi


    # ---------------------------------------------------------------
    # Subcommand
    # ---------------------------------------------------------------
    #
    # Subcommands are recognized only while we have not encountered
    # a positional argument.
    #
    # Once an application/positional argument has been encountered:
    #
    #   install firefox pacman
    #
    # "pacman" is an argument, not a subcommand.
    #
    # This allows:
    #
    #   install -- pacman
    #
    # to explicitly install an application named "pacman".
    #

    if [[ "${#ACT_PARSED_ARGS[@]}" -eq 0 ]] &&
       act_parser_subcommand_allowed "$token"; then

        ACT_PARSED_SUBCOMMANDS+=("$token")
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

        # Internal aliases are expanded before normal parsing.
        #
        # Example:
        #
        #   -i firefox
        #
        # becomes:
        #
        #   install firefox
        #
        # External aliases are untouched.
        expanded="$(
            act_parser_expand_internal_alias "$token"
        )"

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
        act_error "No action specified."
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
