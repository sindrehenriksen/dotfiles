#!/usr/bin/env bash
# Focuses the Ghostty tab running a given tty, via the DeskFocusTab
# Hammerspoon function (init.lua) — the shell-level entry point for the
# notes hotkey's live-session case, alongside desk-open-tab.sh for
# resuming a non-live one.
#
# Its exit code is load-bearing: the hotkey must never resume a session its
# own focus attempt just failed on, so it reads DeskFocusTab's true/false
# return off `hs -c`'s own output rather than just trusting `hs -c`'s
# process exit code, which reflects whether the IPC connection worked, not
# whether the Lua call it ran returned true. desk-open-tab.sh does the same.
#
# A hang or timeout is a failure like any other (exit 124), so the hotkey
# reports it and still never resumes.
#
# Usage: desk-focus-tab.sh <tty>
set -u

tty=${1:?usage: desk-focus-tab.sh <tty>}

lua_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
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

out=$(run_hs "DeskFocusTab($(lua_string "$tty"))")
hs_status=$?
if [ "$hs_status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    exit "$hs_status"
fi

last_line=$(printf '%s\n' "$out" | tail -n1)
if [ "$last_line" = "true" ]; then
    exit 0
fi
printf '%s\n' "$out" >&2
exit 1
