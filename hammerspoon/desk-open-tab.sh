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
#               tab); without it the tab stays open after the command ends,
#               so a finished session can still be read.
set -u

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
