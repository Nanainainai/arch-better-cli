#!/usr/bin/env bash
#
# act/tools/alias/alias.sh
#
# Parser-side command alias definitions.
#
# This file does NOT create shell aliases.
# It only loads alias.config and provides alias information to parser.sh.
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
# Each entry is stored as:
#
#   alias<TAB>canonical command
#
# Example:
#
#   -i<TAB>install
#   ins<TAB>install
#   paci<TAB>pacman -S
#
# This keeps the parser independent of the actual config-file syntax.
#

ACT_ALIASES=()


# ---------------------------------------------------------------------------
# Determine config path
# ---------------------------------------------------------------------------

act_alias_default_config()
{
    local library_root

    library_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    printf '%s\n' "$library_root/tools/alias/alias.config"
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
# String helpers
# ---------------------------------------------------------------------------

act_alias_trim()
{
    local value="${1:-}"

    # Remove leading whitespace.
    value="${value#"${value%%[![:space:]]*}"}"

    # Remove trailing whitespace.
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s\n' "$value"
}


# ---------------------------------------------------------------------------
# Parse one backtick-delimited config line
# ---------------------------------------------------------------------------
#
# Input:
#
#   `install` `-i` `ins`
#
# Output:
#
#   install
#   -i
#   ins
#
# The first field is the canonical command.
# Every remaining field is an alias.
#

act_alias_parse_line()
{
    local line="${1:-}"
    local rest
    local field
    local fields=()

    # Ignore comments and empty lines.
    [[ -z "$line" ]] && return 0
    [[ "$line" == \#* ]] && return 0

    rest="$line"

    while [[ "$rest" =~ ^[[:space:]]*\`([^\`]*)\`(.*)$ ]]; do
        field="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"

        field="$(act_alias_trim "$field")"

        [[ -n "$field" ]] &&
            fields+=("$field")
    done

    # A valid alias definition needs a canonical command and at least
    # one alias.
    if [[ "${#fields[@]}" -lt 2 ]]; then
        return 0
    fi

    local canonical="${fields[0]}"
    local alias

    for alias in "${fields[@]:1}"; do
        ACT_ALIASES+=(
            "$alias"$'\t'"$canonical"
        )
    done
}


# ---------------------------------------------------------------------------
# Load aliases
# ---------------------------------------------------------------------------

act_alias_load()
{
    local config
    local line

    ACT_ALIASES=()

    config="$(act_alias_config_path)"

    if [[ ! -f "$config" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        act_alias_parse_line "$line"
    done < "$config"

    return 0
}


# ---------------------------------------------------------------------------
# Find alias
# ---------------------------------------------------------------------------

act_alias_lookup()
{
    local wanted="${1:-}"
    local entry
    local alias
    local command

    for entry in "${ACT_ALIASES[@]}"; do
        alias="${entry%%$'\t'*}"
        command="${entry#*$'\t'}"

        if [[ "$alias" == "$wanted" ]]; then
            printf '%s\n' "$command"
            return 0
        fi
    done

    return 1
}


# ---------------------------------------------------------------------------
# Check alias
# ---------------------------------------------------------------------------

act_alias_exists()
{
    local wanted="${1:-}"

    act_alias_lookup "$wanted" >/dev/null 2>&1
}


# ---------------------------------------------------------------------------
# Debug output
# ---------------------------------------------------------------------------

act_alias_dump()
{
    local entry
    local alias
    local command

    for entry in "${ACT_ALIASES[@]}"; do
        alias="${entry%%$'\t'*}"
        command="${entry#*$'\t'}"

        printf '%s -> %s\n' "$alias" "$command"
    done
}


# ---------------------------------------------------------------------------
# Automatically load configuration
# ---------------------------------------------------------------------------

act_alias_load
