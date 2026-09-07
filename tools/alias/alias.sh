#!/usr/bin/env bash
#
# act/tools/alias/alias.sh
#
# Alias configuration for the act parser.
#
# Types:
#
#   i = internal act/action alias
#   e = external command alias
#
# Example:
#
#   i `install` `-i` `ins`
#   e `pacman -S` `paci`
#

if [[ -n "${ACT_ALIAS_LOADED:-}" ]]; then
    return 0
fi

ACT_ALIAS_LOADED=1


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ACT_ALIAS_CONFIG="${ACT_ALIAS_CONFIG:-}"


# ---------------------------------------------------------------------------
# Alias storage
# ---------------------------------------------------------------------------
#
# Internal aliases:
#
#   alias<TAB>canonical
#
# External aliases:
#
#   alias<TAB>canonical
#

ACT_INTERNAL_ALIASES=()
ACT_EXTERNAL_ALIASES=()


# ---------------------------------------------------------------------------
# Locate configuration
# ---------------------------------------------------------------------------

act_alias_default_config()
{
    local library_root

    library_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    printf '%s\n' \
        "$library_root/tools/alias/alias.config"
}


act_alias_config_path()
{
    if [[ -n "${ACT_ALIAS_CONFIG:-}" ]]; then
        printf '%s\n' "$ACT_ALIAS_CONFIG"
    else
        act_alias_default_config
    fi
}


# ---------------------------------------------------------------------------
# Parse one config line
# ---------------------------------------------------------------------------

act_alias_parse_line()
{
    local line="${1:-}"
    local type
    local rest
    local field
    local fields=()
    local canonical
    local alias

    # Ignore blank lines.
    [[ -z "${line//[[:space:]]/}" ]] && return 0

    # Ignore comments.
    [[ "$line" == \#* ]] && return 0

    # First character identifies alias type.
    type="${line:0:1}"

    case "$type" in
        i|e)
            ;;
        *)
            return 0
            ;;
    esac

    rest="${line:1}"

    while [[ "$rest" =~ ^[[:space:]]*\`([^\`]*)\`(.*)$ ]]; do
        field="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"

        # Trim whitespace inside the backticks.
        field="${field#"${field%%[![:space:]]*}"}"
        field="${field%"${field##*[![:space:]]}"}"

        [[ -n "$field" ]] &&
            fields+=("$field")
    done

    # Need:
    #
    #   canonical + at least one alias
    #
    [[ "${#fields[@]}" -lt 2 ]] && return 0

    canonical="${fields[0]}"

    for alias in "${fields[@]:1}"; do
        case "$type" in
            i)
                ACT_INTERNAL_ALIASES+=(
                    "$alias"$'\t'"$canonical"
                )
                ;;

            e)
                ACT_EXTERNAL_ALIASES+=(
                    "$alias"$'\t'"$canonical"
                )
                ;;
        esac
    done
}


# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

act_alias_load()
{
    local config
    local line

    ACT_INTERNAL_ALIASES=()
    ACT_EXTERNAL_ALIASES=()

    config="$(act_alias_config_path)"

    [[ -f "$config" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        act_alias_parse_line "$line"
    done < "$config"

    return 0
}


# ---------------------------------------------------------------------------
# Generic lookup
# ---------------------------------------------------------------------------

act_alias_lookup()
{
    local type="${1:-}"
    local wanted="${2:-}"
    local entry
    local alias
    local canonical

    case "$type" in
        i)
            for entry in "${ACT_INTERNAL_ALIASES[@]}"; do
                alias="${entry%%$'\t'*}"
                canonical="${entry#*$'\t'}"

                if [[ "$alias" == "$wanted" ]]; then
                    printf '%s\n' "$canonical"
                    return 0
                fi
            done
            ;;

        e)
            for entry in "${ACT_EXTERNAL_ALIASES[@]}"; do
                alias="${entry%%$'\t'*}"
                canonical="${entry#*$'\t'}"

                if [[ "$alias" == "$wanted" ]]; then
                    printf '%s\n' "$canonical"
                    return 0
                fi
            done
            ;;
    esac

    return 1
}


# ---------------------------------------------------------------------------
# Internal aliases
# ---------------------------------------------------------------------------

act_alias_internal_lookup()
{
    act_alias_lookup i "$1"
}


act_alias_internal_exists()
{
    act_alias_internal_lookup "$1" >/dev/null 2>&1
}


# ---------------------------------------------------------------------------
# External aliases
# ---------------------------------------------------------------------------

act_alias_external_lookup()
{
    act_alias_lookup e "$1"
}


act_alias_external_exists()
{
    act_alias_external_lookup "$1" >/dev/null 2>&1
}


# ---------------------------------------------------------------------------
# Expand an external alias
# ---------------------------------------------------------------------------
#
# Example:
#
#   paci firefox
#
# becomes:
#
#   pacman -S firefox
#
# The alias itself may contain multiple command tokens.
#

ACT_ALIAS_EXPANDED=()

act_alias_expand_external()
{
    local token
    local canonical
    local command
    local expanded=()

    ACT_ALIAS_EXPANDED=()

    for token in "$@"; do

        if canonical="$(act_alias_external_lookup "$token")"; then
            # shellcheck disable=SC2206
            command=($canonical)

            expanded+=("${command[@]}")
        else
            expanded+=("$token")
        fi
    done

    ACT_ALIAS_EXPANDED=(
        "${expanded[@]}"
    )
}


# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------

act_alias_dump()
{
    local entry
    local alias
    local canonical

    printf '%s\n' "Internal aliases:"

    for entry in "${ACT_INTERNAL_ALIASES[@]}"; do
        alias="${entry%%$'\t'*}"
        canonical="${entry#*$'\t'}"

        printf '  %s -> %s\n' \
            "$alias" \
            "$canonical"
    done

    printf '%s\n' "External aliases:"

    for entry in "${ACT_EXTERNAL_ALIASES[@]}"; do
        alias="${entry%%$'\t'*}"
        canonical="${entry#*$'\t'}"

        printf '  %s -> %s\n' \
            "$alias" \
            "$canonical"
    done
}


# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------

act_alias_load
