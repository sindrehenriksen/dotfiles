#!/usr/bin/env bash
# Opens a command in a Ghostty tab by calling the DeskOpenTab Hammerspoon
# function (init.lua) via `hs -c` — the one shell-level entry point, so
# anything that wants a tab opened (the notes hotkey, a scheduled pass) does
# not have to hand-quote a Lua expression itself.
#
# Usage: desk-open-tab.sh <command> [session-id] [cwd] [flags]
# `session-id` and `cwd` are optional; pass "" to skip session-id and still
# give a cwd. `flags` is a comma-separated list:
#   background  open without taking focus from wherever the user is typing
#               (what a scheduled pass passes); without it the new tab is
#               focused, as the notes hotkey wants;
#   close       close the tab when its command exits (a check or one-shot
#               tab); without it the tab is left at a shell prompt in its
#               directory, so a finished session can still be read, and
#               restart-session.sh can resume it there.
set -u

# Sourced from beside this script's own file, through the link
# install_symlinks.sh puts on PATH.
__src="${BASH_SOURCE[0]}"
while [ -h "$__src" ]; do
    __dir="$(cd -P "$(dirname "$__src")" && pwd)"
    __src="$(readlink "$__src")"
    [[ "$__src" != /* ]] && __src="$__dir/$__src"
done
# shellcheck source=hs-call.sh
source "$(cd -P "$(dirname "$__src")" && pwd)/hs-call.sh"

usage='usage: desk-open-tab.sh <command> [session-id] [cwd] [background,close]'
cmd=${1:?$usage}
session_id=${2:-}
cwd=${3:-}
fields=()
IFS=, read -r -a flags <<< "${4:-}"
for flag in ${flags[@]+"${flags[@]}"}; do
    case $flag in
        background) fields+=("background = true") ;;
        close) fields+=("close_on_exit = true") ;;
        *) printf '%s\n' "$usage" >&2; exit 2 ;;
    esac
done
if [ "${#fields[@]}" -eq 0 ]; then
    opts=nil
else
    opts="{ $(IFS=,; printf '%s' "${fields[*]}") }"
fi

lua_arg() {
    if [ -z "$1" ]; then printf 'nil'; else lua_string "$1"; fi
}


expr="DeskOpenTab($(lua_string "$cmd"), $(lua_arg "$session_id"), $(lua_arg "$cwd"), $opts)"

# DeskOpenTab's own true/false is the last line hs prints; hs's exit status
# only says whether the IPC call went through. The runner stamps a tab as
# opened on exit 0, so a false must not exit 0.
out=$(run_hs "$expr")
hs_status=$?
if [ "$hs_status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    exit "$hs_status"
fi
if [ "$(printf '%s\n' "$out" | tail -n1)" = "true" ]; then
    exit 0
fi
printf '%s\n' "$out" >&2
exit 1
