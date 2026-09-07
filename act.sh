#!/usr/bin/env bash

ACT_ROOT="${ACT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"

source "$ACT_ROOT/lib/core.sh"
source "$ACT_ROOT/lib/parser.sh"

# Load action implementations.
source "$ACT_ROOT/lib/install.sh"

act_dispatch()
{
    local command="${1:-}"

    case "$command" in
        install|-i)
            shift
            act_install "$@"
            ;;

        create|-c)
            shift
            act_create "$@"
            ;;

        download|-d)
            shift
            act_download "$@"
            ;;

        remove|-r)
            shift
            act_remove "$@"
            ;;

        uninstall|-u)
            shift
            act_uninstall "$@"
            ;;

        -h|--help|"")
            act_help
            ;;

        *)
            act_error "Unknown action: $command"
            return 2
            ;;
    esac
}

act_dispatch "$@"
