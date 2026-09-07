#!/usr/bin/env bash
#
# act/lib/install.sh
#
# Runtime implementation of the `install` action.
#
# Examples:
#   install firefox
#   install -p firefox
#   install -p -a firefox
#   install -p -a -f firefox
#   install -p -a firefox -f spotify
#   install pacman aur firefox
#   install pacman aur firefox flatpak spotify
#   install -- pacman
#
# Source selectors apply to the following application only.
#

if [[ -n "${ACT_INSTALL_LOADED:-}" ]]; then
    return 0
fi

ACT_INSTALL_LOADED=1


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ACT_INSTALL_SOURCES=(
    pacman
    aur
    flatpak
)

ACT_INSTALL_SOURCE_ALIASES=(
    pacman
    -p
    aur
    -a
    flatpak
    -f
    web
    -w
)


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

ACT_INSTALL_APPS=()
ACT_INSTALL_APP_SOURCES=()
ACT_INSTALL_PLANS=()

ACT_INSTALL_CURRENT_SOURCES=()
ACT_INSTALL_CURRENT_APP=""

ACT_INSTALL_HAS_EXPLICIT_SOURCES=0


# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------

act_install_is_source()
{
    local token="${1:-}"
    local source

    case "$token" in
        pacman|-p)
            return 0
            ;;
        aur|-a)
            return 0
            ;;
        flatpak|-f)
            return 0
            ;;
        web|-w)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


act_install_normalize_source()
{
    case "${1:-}" in
        pacman|-p)
            printf '%s\n' "pacman"
            ;;
        aur|-a)
            printf '%s\n' "aur"
            ;;
        flatpak|-f)
            printf '%s\n' "flatpak"
            ;;
        web|-w)
            printf '%s\n' "web"
            ;;
        *)
            return 1
            ;;
    esac
}


act_install_source_contains()
{
    local wanted="${1:-}"
    local source

    for source in "${ACT_INSTALL_CURRENT_SOURCES[@]}"; do
        [[ "$source" == "$wanted" ]] && return 0
    done

    return 1
}


act_install_add_source()
{
    local source="${1:-}"

    [[ -z "$source" ]] && return 1

    if ! act_install_source_contains "$source"; then
        ACT_INSTALL_CURRENT_SOURCES+=("$source")
    fi
}


act_install_default_sources()
{
    ACT_INSTALL_CURRENT_SOURCES=(
        "${ACT_INSTALL_SOURCES[@]}"
    )
}


# ---------------------------------------------------------------------------
# App/source specification parser
# ---------------------------------------------------------------------------
#
# This parser is deliberately install-specific.
#
# A source selector applies to the NEXT positional application.
#
# Example:
#
#   -p -a firefox -f spotify
#
# produces:
#
#   firefox: pacman aur
#   spotify: flatpak
#
# Once an application has been encountered, its source set is finalized and
# the next source selector starts a new source set.
#
# `--` makes everything following it an application, with no source parsing.
#

act_install_parse_args()
{
    local token
    local source
    local end_of_options=0

    ACT_INSTALL_APPS=()
    ACT_INSTALL_APP_SOURCES=()

    ACT_INSTALL_CURRENT_SOURCES=()
    ACT_INSTALL_HAS_EXPLICIT_SOURCES=0

    for token in "$@"; do

        # ---------------------------------------------------------------
        # End of options
        # ---------------------------------------------------------------

        if [[ "$end_of_options" -eq 1 ]]; then
            ACT_INSTALL_APPS+=("$token")
            ACT_INSTALL_APP_SOURCES+=(
                "$(printf '%s\n' "${ACT_INSTALL_CURRENT_SOURCES[*]:-}")"
            )

            ACT_INSTALL_CURRENT_SOURCES=()
            ACT_INSTALL_HAS_EXPLICIT_SOURCES=0
            continue
        fi

        if [[ "$token" == "--" ]]; then
            end_of_options=1

            # If no source was explicitly selected, use default behavior.
            if [[ "${#ACT_INSTALL_CURRENT_SOURCES[@]}" -eq 0 ]]; then
                act_install_default_sources
            fi

            continue
        fi

        # ---------------------------------------------------------------
        # Source selector
        # ---------------------------------------------------------------

        if act_install_is_source "$token"; then
            source="$(act_install_normalize_source "$token")"

            # A source appearing after an app starts the source selection
            # for the NEXT app.
            #
            # Therefore:
            #
            #   -p firefox -f spotify
            #
            # means:
            #
            #   firefox -> pacman
            #   spotify -> flatpak
            #
            # If sources have already been selected but no app has been
            # seen yet, they accumulate:
            #
            #   -p -a firefox
            #
            # means:
            #
            #   firefox -> pacman + aur
            if [[ "${#ACT_INSTALL_CURRENT_SOURCES[@]}" -eq 0 ]]; then
                act_install_add_source "$source"
                ACT_INSTALL_HAS_EXPLICIT_SOURCES=1
                continue
            fi

            # If we already have sources selected, they still belong to
            # the next app.
            #
            # This gives:
            #
            #   -p -a firefox
            #
            # -> pacman + aur.
            #
            # However, after an app is finalized the source list is empty,
            # so:
            #
            #   firefox -f spotify
            #
            # -> firefox gets defaults, spotify gets flatpak.
            act_install_add_source "$source"
            ACT_INSTALL_HAS_EXPLICIT_SOURCES=1
            continue
        fi

        # ---------------------------------------------------------------
        # Application
        # ---------------------------------------------------------------

        ACT_INSTALL_APPS+=("$token")

        if [[ "${#ACT_INSTALL_CURRENT_SOURCES[@]}" -eq 0 ]]; then
            act_install_default_sources
        fi

        ACT_INSTALL_APP_SOURCES+=(
            "$(printf '%s\n' "${ACT_INSTALL_CURRENT_SOURCES[*]}")"
        )

        # Source selectors do not carry over to the next app.
        ACT_INSTALL_CURRENT_SOURCES=()
        ACT_INSTALL_HAS_EXPLICIT_SOURCES=0
    done

    return 0
}


# ---------------------------------------------------------------------------
# Source list reconstruction
# ---------------------------------------------------------------------------
#
# Bash and Zsh both support arrays, but storing an array inside another array
# is deliberately avoided here. Each app's source list is stored as a
# space-separated string.
#
# `act_install_get_app_sources` expands one of those lists into the global
# ACT_INSTALL_RESOLVED_SOURCES array.
#

ACT_INSTALL_RESOLVED_SOURCES=()

act_install_get_app_sources()
{
    local index="${1:-}"
    local source_string

    ACT_INSTALL_RESOLVED_SOURCES=()

    source_string="${ACT_INSTALL_APP_SOURCES[$index]:-}"

    if [[ -z "$source_string" ]]; then
        act_install_default_sources
        ACT_INSTALL_RESOLVED_SOURCES=(
            "${ACT_INSTALL_SOURCES[@]}"
        )
        return 0
    fi

    # shellcheck disable=SC2206
    ACT_INSTALL_RESOLVED_SOURCES=($source_string)
}


# ---------------------------------------------------------------------------
# Plan representation
# ---------------------------------------------------------------------------
#
# Each plan entry is:
#
#   requested_name|source|actual_identifier
#
# Examples:
#
#   firefox|pacman|firefox
#   spotify|aur|spotify
#   spotify|flatpak|com.spotify.Client
#
# The third field is intentionally separate from the requested name because
# Flatpak and other sources may use a different installation identifier.
#

ACT_INSTALL_PLAN_REQUESTED=()
ACT_INSTALL_PLAN_SOURCE=()
ACT_INSTALL_PLAN_IDENTIFIER=()


act_install_clear_plan()
{
    ACT_INSTALL_PLAN_REQUESTED=()
    ACT_INSTALL_PLAN_SOURCE=()
    ACT_INSTALL_PLAN_IDENTIFIER=()
}


act_install_add_plan()
{
    local requested="${1:-}"
    local source="${2:-}"
    local identifier="${3:-}"

    [[ -z "$requested" ]] && return 1
    [[ -z "$source" ]] && return 1
    [[ -z "$identifier" ]] && return 1

    ACT_INSTALL_PLAN_REQUESTED+=("$requested")
    ACT_INSTALL_PLAN_SOURCE+=("$source")
    ACT_INSTALL_PLAN_IDENTIFIER+=("$identifier")
}


# ---------------------------------------------------------------------------
# Source resolver interface
# ---------------------------------------------------------------------------
#
# Each source module should eventually provide:
#
#   act_source_pacman_resolve APP
#   act_source_aur_resolve APP
#   act_source_flatpak_resolve APP
#   act_source_web_resolve APP
#
# The resolver prints the actual identifier on stdout and returns:
#
#   0 = found
#   1 = not found
#   other = resolver error
#
# This keeps install.sh independent from the implementation of each source.
#


act_install_source_resolve()
{
    local source="${1:-}"
    local app="${2:-}"

    case "$source" in
        pacman)
            if declare -F act_source_pacman_resolve >/dev/null 2>&1; then
                act_source_pacman_resolve "$app"
            else
                act_error "pacman source module is not loaded."
                return 2
            fi
            ;;

        aur)
            if declare -F act_source_aur_resolve >/dev/null 2>&1; then
                act_source_aur_resolve "$app"
            else
                act_error "AUR source module is not loaded."
                return 2
            fi
            ;;

        flatpak)
            if declare -F act_source_flatpak_resolve >/dev/null 2>&1; then
                act_source_flatpak_resolve "$app"
            else
                act_error "Flatpak source module is not loaded."
                return 2
            fi
            ;;

        web)
            if declare -F act_source_web_resolve >/dev/null 2>&1; then
                act_source_web_resolve "$app"
            else
                act_error "web source module is not loaded."
                return 2
            fi
            ;;

        *)
            act_error "Unknown install source: $source"
            return 2
            ;;
    esac
}


# ---------------------------------------------------------------------------
# Automatic package resolution
# ---------------------------------------------------------------------------
#
# Try each permitted package source in order.
#
# Web is deliberately NOT part of automatic package resolution unless the
# user explicitly selected -w/web.
#

act_install_resolve_automatic()
{
    local app="${1:-}"
    local source
    local identifier

    [[ -z "$app" ]] && return 1

    for source in "${ACT_INSTALL_RESOLVED_SOURCES[@]}"; do

        # Explicit web selection is handled separately.
        [[ "$source" == "web" ]] && continue

        identifier="$(
            act_install_source_resolve "$source" "$app"
        )"

        case "$?" in
            0)
                if [[ -n "$identifier" ]]; then
                    act_install_add_plan \
                        "$app" \
                        "$source" \
                        "$identifier"

                    act_debug \
                        "resolved '$app' -> $source:$identifier"

                    return 0
                fi
                ;;

            1)
                # Not found in this source. Continue.
                ;;

            *)
                act_error \
                    "Failed while resolving '$app' through $source."

                return 2
                ;;
        esac
    done

    return 1
}


# ---------------------------------------------------------------------------
# Combined fzf resolution
# ---------------------------------------------------------------------------
#
# The source modules may provide:
#
#   act_source_pacman_search APP
#   act_source_aur_search APP
#   act_source_flatpak_search APP
#
# Each function should print records in the form:
#
#   source<TAB>identifier<TAB>display-name
#
# install.sh combines ALL permitted sources into one fzf invocation.
#

ACT_INSTALL_FZF_RESULTS=()

act_install_collect_fzf_results()
{
    local app="${1:-}"
    local source
    local result

    ACT_INSTALL_FZF_RESULTS=()

    for source in "${ACT_INSTALL_RESOLVED_SOURCES[@]}"; do

        case "$source" in
            pacman)
                if declare -F act_source_pacman_search >/dev/null 2>&1; then
                    while IFS= read -r result; do
                        [[ -n "$result" ]] &&
                            ACT_INSTALL_FZF_RESULTS+=("$result")
                    done < <(
                        act_source_pacman_search "$app"
                    )
                fi
                ;;

            aur)
                if declare -F act_source_aur_search >/dev/null 2>&1; then
                    while IFS= read -r result; do
                        [[ -n "$result" ]] &&
                            ACT_INSTALL_FZF_RESULTS+=("$result")
                    done < <(
                        act_source_aur_search "$app"
                    )
                fi
                ;;

            flatpak)
                if declare -F act_source_flatpak_search >/dev/null 2>&1; then
                    while IFS= read -r result; do
                        [[ -n "$result" ]] &&
                            ACT_INSTALL_FZF_RESULTS+=("$result")
                    done < <(
                        act_source_flatpak_search "$app"
                    )
                fi
                ;;

            web)
                # Web is intentionally excluded from package fzf.
                ;;
        esac
    done
}


act_install_fzf_select()
{
    local selection

    [[ "${#ACT_INSTALL_FZF_RESULTS[@]}" -eq 0 ]] && return 1

    if ! act_has_command fzf; then
        act_debug "fzf is not installed."
        return 1
    fi

    selection="$(
        printf '%s\n' "${ACT_INSTALL_FZF_RESULTS[@]}" |
            fzf \
                --height="${ACT_FZF_HEIGHT:-40%}" \
                --layout=reverse \
                --border \
                --prompt="Install > "
    )"

    [[ -z "$selection" ]] && return 1

    printf '%s\n' "$selection"
}


# ---------------------------------------------------------------------------
# Fzf result parsing
# ---------------------------------------------------------------------------
#
# Expected format:
#
#   source<TAB>identifier<TAB>display-name
#
# Example:
#
#   flatpak<TAB>com.spotify.Client<TAB>Spotify
#

act_install_parse_fzf_result()
{
    local result="${1:-}"
    local source
    local identifier

    IFS=$'\t' read -r source identifier _ <<< "$result"

    [[ -z "$source" ]] && return 1
    [[ -z "$identifier" ]] && return 1

    ACT_INSTALL_FZF_SOURCE="$source"
    ACT_INSTALL_FZF_IDENTIFIER="$identifier"

    return 0
}


# ---------------------------------------------------------------------------
# Interactive resolution
# ---------------------------------------------------------------------------

act_install_resolve_fzf()
{
    local app="${1:-}"
    local selection

    act_install_collect_fzf_results "$app"

    if [[ "${#ACT_INSTALL_FZF_RESULTS[@]}" -eq 0 ]]; then
        act_debug "No fzf candidates found for '$app'."
        return 1
    fi

    selection="$(act_install_fzf_select)"

    [[ -z "$selection" ]] && return 1

    if ! act_install_parse_fzf_result "$selection"; then
        act_error "Invalid fzf selection."
        return 2
    fi

    act_install_add_plan \
        "$app" \
        "$ACT_INSTALL_FZF_SOURCE" \
        "$ACT_INSTALL_FZF_IDENTIFIER"

    act_debug \
        "fzf resolved '$app' -> $ACT_INSTALL_FZF_SOURCE:$ACT_INSTALL_FZF_IDENTIFIER"

    return 0
}


# ---------------------------------------------------------------------------
# Web fallback
# ---------------------------------------------------------------------------

act_install_resolve_web()
{
    local app="${1:-}"
    local identifier

    [[ -z "$app" ]] && return 1

    if ! declare -F act_source_web_resolve >/dev/null 2>&1; then
        act_error "web source module is not loaded."
        return 2
    fi

    identifier="$(
        act_source_web_resolve "$app"
    )"

    case "$?" in
        0)
            [[ -z "$identifier" ]] && return 1

            act_install_add_plan \
                "$app" \
                "web" \
                "$identifier"

            return 0
            ;;

        1)
            return 1
            ;;

        *)
            return 2
            ;;
    esac
}


# ---------------------------------------------------------------------------
# Resolve one application
# ---------------------------------------------------------------------------

act_install_resolve_app()
{
    local index="${1:-}"
    local app
    local source

    app="${ACT_INSTALL_APPS[$index]:-}"

    [[ -z "$app" ]] && return 1

    act_install_get_app_sources "$index"

    act_debug \
        "resolving '$app' using: ${ACT_INSTALL_RESOLVED_SOURCES[*]}"

    # ---------------------------------------------------------------
    # Explicit web-only mode
    # ---------------------------------------------------------------

    if [[ "${#ACT_INSTALL_RESOLVED_SOURCES[@]}" -eq 1 ]] &&
       [[ "${ACT_INSTALL_RESOLVED_SOURCES[0]}" == "web" ]]; then

        act_info "Searching the web for '$app'..."

        if act_install_resolve_web "$app"; then
            return 0
        fi

        act_error "Could not resolve '$app' through web search."
        return 1
    fi

    # ---------------------------------------------------------------
    # Automatic package resolution
    # ---------------------------------------------------------------

    if act_install_resolve_automatic "$app"; then
        return 0
    fi

    # ---------------------------------------------------------------
    # Combined fzf search
    # ---------------------------------------------------------------
    #
    # Only package sources selected for THIS application participate.
    #
    # Example:
    #
    #   -p -a firefox -f spotify
    #
    # firefox's fzf contains pacman + AUR.
    # spotify's fzf contains flatpak only.
    #

    act_info "No direct package match for '$app'."

    if act_install_resolve_fzf "$app"; then
        return 0
    fi

    # ---------------------------------------------------------------
    # Web fallback
    # ---------------------------------------------------------------

    act_info "No package selection made for '$app'. Trying web search..."

    if act_install_resolve_web "$app"; then
        return 0
    fi

    act_error "Could not resolve '$app'."
    return 1
}


# ---------------------------------------------------------------------------
# Resolve all applications before installing anything
# ---------------------------------------------------------------------------

act_install_resolve_all()
{
    local index
    local app
    local failed=0

    act_install_clear_plan

    for ((index = 0; index < ${#ACT_INSTALL_APPS[@]}; index++)); do
        app="${ACT_INSTALL_APPS[$index]}"

        act_info "Resolving '$app'..."

        if ! act_install_resolve_app "$index"; then
            failed=1
        fi
    done

    return "$failed"
}


# ---------------------------------------------------------------------------
# Plan display
# ---------------------------------------------------------------------------

act_install_show_plan()
{
    local index

    [[ "${#ACT_INSTALL_PLAN_REQUESTED[@]}" -eq 0 ]] && return 1

    act_info "Install plan:"

    for ((index = 0; index < ${#ACT_INSTALL_PLAN_REQUESTED[@]}; index++)); do
        printf '  %s -> %s:%s\n' \
            "${ACT_INSTALL_PLAN_REQUESTED[$index]}" \
            "${ACT_INSTALL_PLAN_SOURCE[$index]}" \
            "${ACT_INSTALL_PLAN_IDENTIFIER[$index]}"
    done
}


# ---------------------------------------------------------------------------
# Source installer interface
# ---------------------------------------------------------------------------
#
# Source modules provide:
#
#   act_source_pacman_install ID...
#   act_source_aur_install ID...
#   act_source_flatpak_install ID...
#   act_source_web_install ID...
#
# Multiple packages are grouped by source so that:
#
#   firefox -> pacman
#   vlc     -> pacman
#
# results in one pacman invocation rather than two.
#

act_install_execute_source()
{
    local source="${1:-}"
    shift

    case "$source" in
        pacman)
            if declare -F act_source_pacman_install >/dev/null 2>&1; then
                act_source_pacman_install "$@"
            else
                act_error "pacman installer module is not loaded."
                return 2
            fi
            ;;

        aur)
            if declare -F act_source_aur_install >/dev/null 2>&1; then
                act_source_aur_install "$@"
            else
                act_error "AUR installer module is not loaded."
                return 2
            fi
            ;;

        flatpak)
            if declare -F act_source_flatpak_install >/dev/null 2>&1; then
                act_source_flatpak_install "$@"
            else
                act_error "Flatpak installer module is not loaded."
                return 2
            fi
            ;;

        web)
            if declare -F act_source_web_install >/dev/null 2>&1; then
                act_source_web_install "$@"
            else
                act_error "web installer module is not loaded."
                return 2
            fi
            ;;

        *)
            act_error "Unknown install source: $source"
            return 2
            ;;
    esac
}


# ---------------------------------------------------------------------------
# Execute resolved plan
# ---------------------------------------------------------------------------

act_install_execute_plan()
{
    local source
    local index
    local identifier

    local -a pacman_packages=()
    local -a aur_packages=()
    local -a flatpak_packages=()
    local -a web_packages=()

    # ---------------------------------------------------------------
    # Group everything before executing anything.
    # ---------------------------------------------------------------

    for ((index = 0; index < ${#ACT_INSTALL_PLAN_SOURCE[@]}; index++)); do

        source="${ACT_INSTALL_PLAN_SOURCE[$index]}"
        identifier="${ACT_INSTALL_PLAN_IDENTIFIER[$index]}"

        case "$source" in
            pacman)
                pacman_packages+=("$identifier")
                ;;

            aur)
                aur_packages+=("$identifier")
                ;;

            flatpak)
                flatpak_packages+=("$identifier")
                ;;

            web)
                web_packages+=("$identifier")
                ;;

            *)
                act_error \
                    "Invalid install plan source: $source"
                return 2
                ;;
        esac
    done

    # ---------------------------------------------------------------
    # Show plan
    # ---------------------------------------------------------------

    act_install_show_plan

    # ---------------------------------------------------------------
    # Dry run
    # ---------------------------------------------------------------

    if [[ "${ACT_DRY_RUN:-0}" -eq 1 ]]; then
        act_info "Dry run enabled. Nothing will be installed."
        return 0
    fi

    # ---------------------------------------------------------------
    # Execute grouped package-manager operations
    # ---------------------------------------------------------------

    if [[ "${#pacman_packages[@]}" -gt 0 ]]; then
        act_info "Installing ${#pacman_packages[@]} package(s) with pacman..."

        if ! act_install_execute_source \
            pacman \
            "${pacman_packages[@]}"; then

            act_error "pacman installation failed."
            return 1
        fi
    fi

    if [[ "${#aur_packages[@]}" -gt 0 ]]; then
        act_info "Installing ${#aur_packages[@]} AUR package(s)..."

        if ! act_install_execute_source \
            aur \
            "${aur_packages[@]}"; then

            act_error "AUR installation failed."
            return 1
        fi
    fi

    if [[ "${#flatpak_packages[@]}" -gt 0 ]]; then
        act_info "Installing ${#flatpak_packages[@]} Flatpak package(s)..."

        if ! act_install_execute_source \
            flatpak \
            "${flatpak_packages[@]}"; then

            act_error "Flatpak installation failed."
            return 1
        fi
    fi

    if [[ "${#web_packages[@]}" -gt 0 ]]; then
        act_info "Installing ${#web_packages[@]} web result(s)..."

        if ! act_install_execute_source \
            web \
            "${web_packages[@]}"; then

            act_error "Web installation failed."
            return 1
        fi
    fi

    return 0
}


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

act_install_usage()
{
    cat <<'EOF'
Usage:
  install [sources] APP...
  install APP... [sources] APP...

Sources:
  pacman, -p       Use Arch official repositories
  aur, -a          Use the AUR
  flatpak, -f      Use Flatpak
  web, -w          Use web search only

Examples:
  install firefox
  install -p firefox
  install -p -a firefox
  install -p -a -f firefox

  install -p -a firefox -f spotify
  install pacman aur firefox flatpak spotify

  install -w firefox

  install -- pacman

Default behavior:
  If no source is specified for an app, try:
    pacman -> AUR -> Flatpak -> combined fzf -> web

Source selectors apply to the next application.

Examples:
  install -p -a firefox -f spotify

  Means:
    firefox -> pacman + AUR
    spotify -> Flatpak
EOF
}


# ---------------------------------------------------------------------------
# Main action
# ---------------------------------------------------------------------------

act_install()
{
    local arg="${1:-}"

    # ---------------------------------------------------------------
    # Help
    # ---------------------------------------------------------------

    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        act_install_usage
        return 0
    fi

    # ---------------------------------------------------------------
    # Parse
    # ---------------------------------------------------------------

    act_install_parse_args "$@"

    if [[ "${#ACT_INSTALL_APPS[@]}" -eq 0 ]]; then
        act_error "No application specified."
        act_install_usage
        return 2
    fi

    # ---------------------------------------------------------------
    # Resolve everything before installing anything.
    # ---------------------------------------------------------------

    if ! act_install_resolve_all; then
        act_error "One or more applications could not be resolved."
        return 1
    fi

    # ---------------------------------------------------------------
    # Execute the complete plan.
    # ---------------------------------------------------------------

    if ! act_install_execute_plan; then
        act_error "Installation failed."
        return 1
    fi

    act_success "Installation complete."
    return 0
}
