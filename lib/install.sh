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
#   install -w firefox
#   install --dry-run firefox
#   install -- pacman
#
# Source selectors apply to the following application only.
#
# Source integrations are adapters. They may provide functions such as:
#
#   act_source_pacman_resolve
#   act_source_aur_resolve
#   act_source_flatpak_resolve
#   act_source_web_resolve
#
# Those adapters invoke the actual external commands, such as pacman,
# an AUR helper, or flatpak. Those external programs are not libraries
# loaded by act.
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
# Runtime state
# ---------------------------------------------------------------------------

ACT_INSTALL_APPS=()
ACT_INSTALL_APP_SOURCES=()

ACT_INSTALL_CURRENT_SOURCES=()
ACT_INSTALL_RESOLVED_SOURCES=()

ACT_INSTALL_PLAN_REQUESTED=()
ACT_INSTALL_PLAN_SOURCE=()
ACT_INSTALL_PLAN_IDENTIFIER=()

ACT_INSTALL_FZF_RESULTS=()
ACT_INSTALL_FZF_SOURCE=""
ACT_INSTALL_FZF_IDENTIFIER=""

# Action-local option.
#
# This is deliberately reset by act_install() on every invocation so that
# calling act_install more than once in the same shell cannot leak state.
ACT_DRY_RUN=0


# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------

act_install_is_source()
{
    local token="${1:-}"

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

    return 0
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
# A source selector applies to the NEXT application.
#
# Example:
#
#   install -p -a firefox -f spotify
#
# produces:
#
#   firefox -> pacman aur
#   spotify -> flatpak
#
# Once an application is encountered, its source set is finalized.
#
# Action options:
#
#   -n
#   --dry-run
#
# are global to this invocation and may appear anywhere before `--`.
#
# `--` ends option/source parsing. Everything after it is an application
# name, including strings such as `-p` or `--dry-run`.
#

act_install_parse_args()
{
    local token
    local source
    local end_of_options=0

    ACT_INSTALL_APPS=()
    ACT_INSTALL_APP_SOURCES=()
    ACT_INSTALL_CURRENT_SOURCES=()

    for token in "$@"; do

        # ---------------------------------------------------------------
        # Everything after `--` is an application.
        # ---------------------------------------------------------------

        if [[ "$end_of_options" -eq 1 ]]; then
            ACT_INSTALL_APPS+=("$token")

            ACT_INSTALL_APP_SOURCES+=(
                "$(printf '%s\n' "${ACT_INSTALL_CURRENT_SOURCES[*]:-}")"
            )

            ACT_INSTALL_CURRENT_SOURCES=()
            continue
        fi

        # ---------------------------------------------------------------
        # End of options.
        # ---------------------------------------------------------------

        if [[ "$token" == "--" ]]; then
            end_of_options=1

            # A pending source selection belongs to the next application.
            # If none was selected, that application uses the defaults.
            continue
        fi

        # ---------------------------------------------------------------
        # Action options.
        # ---------------------------------------------------------------

        case "$token" in
            -n|--dry-run)
                ACT_DRY_RUN=1
                continue
                ;;
        esac

        # ---------------------------------------------------------------
        # Source selector.
        # ---------------------------------------------------------------

        if act_install_is_source "$token"; then
            source="$(act_install_normalize_source "$token")"

            act_install_add_source "$source"
            continue
        fi

        # ---------------------------------------------------------------
        # Application.
        # ---------------------------------------------------------------

        ACT_INSTALL_APPS+=("$token")

        if [[ "${#ACT_INSTALL_CURRENT_SOURCES[@]}" -eq 0 ]]; then
            act_install_default_sources
        fi

        ACT_INSTALL_APP_SOURCES+=(
            "$(printf '%s\n' "${ACT_INSTALL_CURRENT_SOURCES[*]}")"
        )

        # Source selectors do not carry over to the next application.
        ACT_INSTALL_CURRENT_SOURCES=()
    done

    return 0
}


# ---------------------------------------------------------------------------
# Source list reconstruction
# ---------------------------------------------------------------------------
#
# Each application's source list is stored as a space-separated string.
#
# This avoids nested arrays while keeping the public runtime state simple.
#

act_install_get_app_sources()
{
    local index="${1:-}"
    local source_string

    ACT_INSTALL_RESOLVED_SOURCES=()

    source_string="${ACT_INSTALL_APP_SOURCES[$index]:-}"

    if [[ -z "$source_string" ]]; then
        ACT_INSTALL_RESOLVED_SOURCES=(
            "${ACT_INSTALL_SOURCES[@]}"
        )
        return 0
    fi

    # shellcheck disable=SC2206
    ACT_INSTALL_RESOLVED_SOURCES=($source_string)

    return 0
}


# ---------------------------------------------------------------------------
# Plan representation
# ---------------------------------------------------------------------------
#
# Every plan entry consists of:
#
#   requested name
#   source
#   actual installation identifier
#
# Examples:
#
#   firefox|pacman|firefox
#   spotify|aur|spotify
#   spotify|flatpak|com.spotify.Client
#

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

    [[ -n "$requested" ]] || return 1
    [[ -n "$source" ]] || return 1
    [[ -n "$identifier" ]] || return 1

    ACT_INSTALL_PLAN_REQUESTED+=("$requested")
    ACT_INSTALL_PLAN_SOURCE+=("$source")
    ACT_INSTALL_PLAN_IDENTIFIER+=("$identifier")

    return 0
}


# ---------------------------------------------------------------------------
# Source resolver interface
# ---------------------------------------------------------------------------
#
# Integrations may provide:
#
#   act_source_pacman_resolve APP
#   act_source_aur_resolve APP
#   act_source_flatpak_resolve APP
#   act_source_web_resolve APP
#
# Return values:
#
#   0 = found, identifier printed to stdout
#   1 = not found / integration unavailable
#   other = actual integration error
#
# Missing integrations are not fatal during automatic resolution. This is
# important because the default resolver should be able to continue from
# pacman -> AUR -> Flatpak -> fzf -> web.
#

act_install_source_resolve()
{
    local source="${1:-}"
    local app="${2:-}"

    [[ -n "$source" ]] || return 2
    [[ -n "$app" ]] || return 2

    case "$source" in
        pacman)
            if declare -F act_source_pacman_resolve >/dev/null 2>&1; then
                act_source_pacman_resolve "$app"
            else
                act_debug "pacman integration is unavailable."
                return 1
            fi
            ;;

        aur)
            if declare -F act_source_aur_resolve >/dev/null 2>&1; then
                act_source_aur_resolve "$app"
            else
                act_debug "AUR integration is unavailable."
                return 1
            fi
            ;;

        flatpak)
            if declare -F act_source_flatpak_resolve >/dev/null 2>&1; then
                act_source_flatpak_resolve "$app"
            else
                act_debug "Flatpak integration is unavailable."
                return 1
            fi
            ;;

        web)
            if declare -F act_source_web_resolve >/dev/null 2>&1; then
                act_source_web_resolve "$app"
            else
                act_debug "web integration is unavailable."
                return 1
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
# Web is deliberately excluded here.
#
# If a source integration is unavailable, resolution continues with the next
# source.
#

act_install_resolve_automatic()
{
    local app="${1:-}"
    local source
    local identifier
    local status

    [[ -n "$app" ]] || return 1

    for source in "${ACT_INSTALL_RESOLVED_SOURCES[@]}"; do

        [[ "$source" == "web" ]] && continue

        identifier="$(
            act_install_source_resolve "$source" "$app"
        )"
        status=$?

        case "$status" in
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

                act_debug \
                    "source '$source' returned no identifier for '$app'."
                ;;

            1)
                act_debug \
                    "no '$app' match through $source."
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
# Search adapters may provide:
#
#   act_source_pacman_search APP
#   act_source_aur_search APP
#   act_source_flatpak_search APP
#
# Each prints:
#
#   source<TAB>identifier<TAB>display-name
#
# All candidates for the current application are combined into one fzf menu.
#

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
                # Web does not participate in package fzf.
                ;;

            *)
                act_debug "Skipping unknown fzf source '$source'."
                ;;
        esac
    done

    return 0
}


act_install_fzf_select()
{
    local selection

    [[ "${#ACT_INSTALL_FZF_RESULTS[@]}" -gt 0 ]] || return 1

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

    [[ -n "$selection" ]] || return 1

    printf '%s\n' "$selection"
}


# ---------------------------------------------------------------------------
# Fzf result parsing
# ---------------------------------------------------------------------------

act_install_parse_fzf_result()
{
    local result="${1:-}"
    local source
    local identifier
    local display_name

    ACT_INSTALL_FZF_SOURCE=""
    ACT_INSTALL_FZF_IDENTIFIER=""

    [[ -n "$result" ]] || return 1

    IFS=$'\t' read -r source identifier display_name <<< "$result"

    [[ -n "$source" ]] || return 1
    [[ -n "$identifier" ]] || return 1

    case "$source" in
        pacman|aur|flatpak)
            ;;
        *)
            act_debug "Invalid fzf source '$source'."
            return 1
            ;;
    esac

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

    [[ -n "$app" ]] || return 1

    act_install_collect_fzf_results "$app"

    if [[ "${#ACT_INSTALL_FZF_RESULTS[@]}" -eq 0 ]]; then
        act_debug "No fzf candidates found for '$app'."
        return 1
    fi

    selection="$(act_install_fzf_select)"

    [[ -n "$selection" ]] || return 1

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
# Web resolution
# ---------------------------------------------------------------------------

act_install_resolve_web()
{
    local app="${1:-}"
    local identifier
    local status

    [[ -n "$app" ]] || return 1

    if ! declare -F act_source_web_resolve >/dev/null 2>&1; then
        act_debug "web integration is unavailable."
        return 1
    fi

    identifier="$(
        act_source_web_resolve "$app"
    )"
    status=$?

    case "$status" in
        0)
            if [[ -z "$identifier" ]]; then
                act_debug "web integration returned no identifier for '$app'."
                return 1
            fi

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
    local web_only=0

    app="${ACT_INSTALL_APPS[$index]:-}"

    [[ -n "$app" ]] || return 1

    act_install_get_app_sources "$index"

    act_debug \
        "resolving '$app' using: ${ACT_INSTALL_RESOLVED_SOURCES[*]}"

    # ---------------------------------------------------------------
    # Explicit web-only mode
    # ---------------------------------------------------------------

    if [[ "${#ACT_INSTALL_RESOLVED_SOURCES[@]}" -eq 1 ]] &&
       [[ "${ACT_INSTALL_RESOLVED_SOURCES[0]}" == "web" ]]; then

        web_only=1

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
    # Only the package sources selected for THIS application participate.
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

    if [[ "$web_only" -eq 0 ]]; then
        act_debug "Web fallback was unavailable or found no result for '$app'."
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

    if [[ "${#ACT_INSTALL_PLAN_REQUESTED[@]}" -eq 0 ]]; then
        act_info "Install plan is empty."
        return 1
    fi

    act_info "Install plan:"

    for ((index = 0; index < ${#ACT_INSTALL_PLAN_REQUESTED[@]}; index++)); do
        printf '  %s -> %s:%s\n' \
            "${ACT_INSTALL_PLAN_REQUESTED[$index]}" \
            "${ACT_INSTALL_PLAN_SOURCE[$index]}" \
            "${ACT_INSTALL_PLAN_IDENTIFIER[$index]}"
    done

    return 0
}


# ---------------------------------------------------------------------------
# Source installer interface
# ---------------------------------------------------------------------------
#
# Integrations may provide:
#
#   act_source_pacman_install ID...
#   act_source_aur_install ID...
#   act_source_flatpak_install ID...
#   act_source_web_install ID...
#
# These adapters invoke the real external package managers/tools.
#

act_install_execute_source()
{
    local source="${1:-}"

    shift || true

    case "$source" in
        pacman)
            if declare -F act_source_pacman_install >/dev/null 2>&1; then
                act_source_pacman_install "$@"
            else
                act_error "pacman integration is unavailable."
                return 2
            fi
            ;;

        aur)
            if declare -F act_source_aur_install >/dev/null 2>&1; then
                act_source_aur_install "$@"
            else
                act_error "AUR integration is unavailable."
                return 2
            fi
            ;;

        flatpak)
            if declare -F act_source_flatpak_install >/dev/null 2>&1; then
                act_source_flatpak_install "$@"
            else
                act_error "Flatpak integration is unavailable."
                return 2
            fi
            ;;

        web)
            if declare -F act_source_web_install >/dev/null 2>&1; then
                act_source_web_install "$@"
            else
                act_error "web integration is unavailable."
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
                act_error "Invalid install plan source: $source"
                return 2
                ;;
        esac
    done

    # ---------------------------------------------------------------
    # Always show the complete plan before doing anything.
    # ---------------------------------------------------------------

    act_install_show_plan

    # ---------------------------------------------------------------
    # Dry run.
    #
    # Resolution still happens so the displayed plan is meaningful.
    # Nothing is passed to an installer.
    # ---------------------------------------------------------------

    if [[ "${ACT_DRY_RUN:-0}" -eq 1 ]]; then
        act_info "Dry run enabled. Nothing will be installed."
        return 0
    fi

    # ---------------------------------------------------------------
    # Execute grouped package-manager operations.
    # ---------------------------------------------------------------

    if [[ "${#pacman_packages[@]}" -gt 0 ]]; then
        act_info \
            "Installing ${#pacman_packages[@]} package(s) with pacman..."

        if ! act_install_execute_source \
            pacman \
            "${pacman_packages[@]}"; then

            act_error "pacman installation failed."
            return 1
        fi
    fi

    if [[ "${#aur_packages[@]}" -gt 0 ]]; then
        act_info \
            "Installing ${#aur_packages[@]} AUR package(s)..."

        if ! act_install_execute_source \
            aur \
            "${aur_packages[@]}"; then

            act_error "AUR installation failed."
            return 1
        fi
    fi

    if [[ "${#flatpak_packages[@]}" -gt 0 ]]; then
        act_info \
            "Installing ${#flatpak_packages[@]} Flatpak package(s)..."

        if ! act_install_execute_source \
            flatpak \
            "${flatpak_packages[@]}"; then

            act_error "Flatpak installation failed."
            return 1
        fi
    fi

    if [[ "${#web_packages[@]}" -gt 0 ]]; then
        act_info \
            "Installing ${#web_packages[@]} web result(s)..."

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
  install [options] [sources] APP...
  install [options] APP... [sources] APP...

Options:
  -n, --dry-run    Resolve and show the install plan without installing
  -h, --help       Show this help

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

  install --dry-run firefox
  install -n -p firefox

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

The `--` marker ends source and option parsing.

For example:
  install -- pacman

installs the application named "pacman".
EOF
}


# ---------------------------------------------------------------------------
# Main action
# ---------------------------------------------------------------------------

act_install()
{
    # ---------------------------------------------------------------
    # Reset invocation-local state.
    # ---------------------------------------------------------------

    ACT_DRY_RUN=0

    ACT_INSTALL_APPS=()
    ACT_INSTALL_APP_SOURCES=()
    ACT_INSTALL_CURRENT_SOURCES=()
    ACT_INSTALL_RESOLVED_SOURCES=()

    ACT_INSTALL_FZF_RESULTS=()
    ACT_INSTALL_FZF_SOURCE=""
    ACT_INSTALL_FZF_IDENTIFIER=""

    act_install_clear_plan

    # ---------------------------------------------------------------
    # Help.
    #
    # Only treat -h/--help as action help when it is the first argument.
    # After `--`, it is allowed to be an application name.
    # ---------------------------------------------------------------

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        act_install_usage
        return 0
    fi

    # ---------------------------------------------------------------
    # Parse.
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

    if [[ "${ACT_DRY_RUN:-0}" -eq 1 ]]; then
        act_success "Dry run complete."
    else
        act_success "Installation complete."
    fi

    return 0
}
