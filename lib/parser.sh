#!/usr/bin/env bash
#
# act/lib/parser.sh
#
# Generic command-line parser for Bash and Zsh.
#
# Responsibilities:
#   - identify the action
#   - recognize action aliases
#   - recognize configured subcommands
#   - recognize configured flags
#   - preserve positional arguments
#   - handle `--`
#
# It does NOT know what pacman, AUR, Flatpak, etc. mean.
#

if [[ -n "${ACT_PARSER_LOADED:-}" ]]; then
    return 0
fi

ACT_PARSER_LOADED=1


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

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
# Reset parser state
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
# Generic list helper
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


# ---------------------------------------------------------------------------
# Configuration checks
# ---------------------------------------------------------------------------

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
# Alias expansion helpers
# ---------------------------------------------------------------------------
#
# Alias config entries are:
#
#   alias -> canonical command
#
# The canonical command may contain multiple tokens.
#
# Example:
#
#   paci -> "pacman -S"
#
# Input:
#
#   paci firefox
#
# becomes:
#
#   pacman -S firefox
#
# Alias expansion happens once per token and is deliberately non-recursive.
# This prevents accidental alias loops.
#

ACT_PARSER_EXPANDED_ARGS=()


act_parser_split_command()
{
    local command="${1:-}"

    # shellcheck disable=SC2206
    ACT_PARSER_SPLIT_RESULT=($command)
}


act_parser_expand_aliases()
{
    local token
    local canonical
    local expanded=()

    act_parser_load_aliases

    ACT_PARSER_EXPANDED_ARGS=()

    for token in "$@"; do

        if declare -F act_alias_lookup >/dev/null 2>&1 &&
           canonical="$(act_alias_lookup "$token")"; then

            act_parser_split_command "$canonical"

            expanded+=(
                "${ACT_PARSER_SPLIT_RESULT[@]}"
            )
        else
            expanded+=("$token")
        fi
    done

    ACT_PARSER_EXPANDED_ARGS=(
        "${expanded[@]}"
    )
}


# ---------------------------------------------------------------------------
# Handle one token
# ---------------------------------------------------------------------------

act_parser_handle_token()
{
    local token="${1:-}"
    local action_set=0

    # ---------------------------------------------------------------
    # End of options
    # ---------------------------------------------------------------

    if [[ "$ACT_PARSED_END_OF_OPTIONS" -eq 1 ]]; then
        ACT_PARSED_ARGS+=("$token")
        return 0
    fi

    if [[ "$token" == "--" ]]; then
        ACT_PARSED_END_OF_OPTIONS=1
        return 0
    fi

    # ---------------------------------------------------------------
    # Action
    # ---------------------------------------------------------------
    #
    # The action is recognized only before the first positional
    # argument.
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

    if [[ "$token" == -* && "$token" != "-" ]]; then

        # Exact configured flag.
        if act_parser_flag_allowed "$token"; then
            ACT_PARSED_FLAGS+=("$token")
            return 0
        fi

        # Short flag cluster.
        #
        # Example:
        #
        #   -paf
        #
        # becomes:
        #
        #   -p -a -f
        #

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

        # Unknown options are preserved as arguments rather than
        # silently discarded.
        ACT_PARSED_ARGS+=("$token")
        return 0
    fi

    # ---------------------------------------------------------------
    # Subcommand
    # ---------------------------------------------------------------
    #
    # Subcommands are recognized only before the first positional
    # argument.
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

    act_parser_reset

    act_parser_expand_aliases "$@"

    for token in "${ACT_PARSER_EXPANDED_ARGS[@]}"; do
        act_parser_handle_token "$token"
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
        if [[ "$flag" == "$wanted" ]]; then
            return 0
        fi
    done

    return 1
}


act_parser_subcommand_matches()
{
    local wanted="${1:-}"
    shift

    local subcommand

    for subcommand in "$@"; do
        if [[ "$subcommand" == "$wanted" ]]; then
            return 0
        fi
    done

    return 1
}


# ---------------------------------------------------------------------------
# Normalize subcommands
# ---------------------------------------------------------------------------
#
# This function intentionally does nothing by default.
#
# Action-specific normalization belongs to the action module.
#
# For install, lib/install.sh can turn:
#
#   -p -> pacman
#   -a -> aur
#   -f -> flatpak
#   -w -> web
#
# This keeps parser.sh generic.
#

act_parser_normalize_subcommands()
{
    return 0
}


# ---------------------------------------------------------------------------
# Dump parser state
# ---------------------------------------------------------------------------

act_parser_dump()
{
    printf 'action: %s\n' \
        "$ACT_PARSED_ACTION"

    printf 'subcommands:'

    local item

    for item in "${ACT_PARSED_SUBCOMMANDS[@]}"; do
        printf ' %s' "$item"
    done

    printf '\nflags:'

    for item in "${ACT_PARSED_FLAGS[@]}"; do
        printf ' %s' "$item"
    done

    printf '\nargs:'

    for item in "${ACT_PARSED_ARGS[@]}"; do
        printf ' %s' "$item"
    done

    printf '\n'
}
