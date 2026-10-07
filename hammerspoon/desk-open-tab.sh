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

# Runs `hs -c "$1"` with a hard time limit, printing what hs printed.
# stdin is /dev/null on purpose: hs reads a piped or socket stdin as more
# commands and waits for its EOF, so a caller whose stdin never closes (an
# agent's shell, a job runner) would otherwise hang here forever. `-t` bounds
# the IPC send and receive; the watchdog is the backstop for anything else,
# and a run it has to kill exits 124, the same as timeout(1).
run_hs() {
    local limit=${DESK_HS_TIMEOUT_SECS:-6}
    local flag
    flag=$(mktemp "${TMPDIR:-/tmp}/desk-hs.XXXXXX") || return 1
    hs -t "$limit" -c "$1" < /dev/null &
    local pid=$!
    (
        sleep "$limit"
        if kill -0 "$pid" 2> /dev/null; then
            printf 'killed' > "$flag"
            kill -TERM "$pid" 2> /dev/null
            sleep 1
            kill -KILL "$pid" 2> /dev/null
        fi
    ) > /dev/null 2>&1 &
    local watchdog=$!
    wait "$pid"
    local status=$?
    kill "$watchdog" 2> /dev/null
    if [ -s "$flag" ]; then
        status=124
        printf 'hs did not return within %ss; killed\n' "$limit" >&2
    fi
    rm -f "$flag"
    return "$status"
}

expr="DeskOpenTab($(lua_string "$cmd"), $(lua_arg "$session_id"), $(lua_arg "$cwd"), $opts)"

run_hs "$expr"
