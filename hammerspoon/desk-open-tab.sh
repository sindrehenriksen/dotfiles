#!/usr/bin/env bash
# Opens a command in a Ghostty tab by calling the DeskOpenTab Hammerspoon
# function (init.lua) via `hs -c` — the one shell-level entry point, so
# anything that wants a tab opened (the notes hotkey, a scheduled pass) does
# not have to hand-quote a Lua expression itself.
#
# Usage: desk-open-tab.sh <command> [session-id] [cwd]
# `session-id` and `cwd` are optional; pass "" to skip session-id and still
# give a cwd.
set -u

cmd=${1:?usage: desk-open-tab.sh <command> [session-id] [cwd]}
session_id=${2:-}
cwd=${3:-}

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

expr="DeskOpenTab($(lua_string "$cmd"), $(lua_arg "$session_id"), $(lua_arg "$cwd"))"

exec hs -c "$expr"
