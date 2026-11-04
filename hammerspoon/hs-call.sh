#!/usr/bin/env bash
# Calling Hammerspoon from the shell: sourced by the desk helpers here
# (desk-open-tab.sh, desk-focus-tab.sh, desk-close-tab.sh, desk-window.sh)
# and by claude/ghostty-update.
set -u

# A string literal for the Lua expression `hs -c` evaluates, never for the
# shell, which already sees these as ordinary argv strings.
lua_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
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
