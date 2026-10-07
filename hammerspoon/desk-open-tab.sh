#!/usr/bin/env bash
# Opens a command in a Ghostty tab by calling the DeskOpenTab Hammerspoon
# function (init.lua) via `hs -c` — the one shell-level entry point, so
# anything that wants a tab opened (the notes hotkey, a scheduled pass) does
# not have to hand-quote a Lua expression itself.
#
# Usage: desk-open-tab.sh <command> [session-id] [cwd] [background]
# `session-id` and `cwd` are optional; pass "" to skip session-id and still
# give a cwd. `background` (what a scheduled pass passes) opens the tab
# without taking focus from wherever the user is typing; without it the new
# tab is focused, as the notes hotkey wants.
set -u

usage='usage: desk-open-tab.sh <command> [session-id] [cwd] [background]'
cmd=${1:?$usage}
session_id=${2:-}
cwd=${3:-}
case ${4:-} in
    "") opts=nil ;;
    background) opts='{ background = true }' ;;
    *) printf '%s\n' "$usage" >&2; exit 2 ;;
esac

# A string literal for the Lua expression `hs -c` evaluates — never for the
# shell, which already sees these as ordinary argv strings.
lua_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

lua_arg() {
    if [ -z "$1" ]; then printf 'nil'; else lua_string "$1"; fi
}

expr="DeskOpenTab($(lua_string "$cmd"), $(lua_arg "$session_id"), $(lua_arg "$cwd"), $opts)"

exec hs -c "$expr"
