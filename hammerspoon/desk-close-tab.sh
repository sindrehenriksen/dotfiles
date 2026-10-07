#!/usr/bin/env bash
# Closes the Ghostty tab a session ran in, through the DeskTabTerminal and
# DeskCloseTerminalTab Hammerspoon functions (init.lua): the shell-level
# entry point claude/close-session.sh uses, beside desk-open-tab.sh and
# desk-focus-tab.sh.
#
# Usage: desk-close-tab.sh find <tty> <pid>
#            Prints the id of the one Ghostty terminal on <tty> whose
#            foreground process is <pid>. Run while that process still
#            holds the tty: a terminal id is never reused, a tty is.
#        desk-close-tab.sh close <terminal-id>
#            Closes the tab holding that terminal when nothing else is in
#            it, keeping focus where it was.
#
# Exit 0 on success; 1 when Hammerspoon said no (its reason on stderr); 124
# when hs did not return in DESK_HS_TIMEOUT_SECS (default 6); 2 on usage.
set -u

usage='usage: desk-close-tab.sh find <tty> <pid> | close <terminal-id>'

lua_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# Runs `hs -c "$1"` with a hard time limit, printing what hs printed.
# stdin is /dev/null on purpose: hs reads a piped or socket stdin as more
# commands and waits for its EOF. The watchdog is the backstop for anything
# `-t` does not bound; a run it has to kill exits 124, like timeout(1).
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

case "${1:-}" in
    find)
        [ $# -eq 3 ] && [ -n "$2" ] && [[ "$3" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }
        expr="DeskTabTerminal($(lua_string "$2"), $3)"
        ;;
    close)
        [ $# -eq 2 ] && [ -n "$2" ] || { echo "$usage" >&2; exit 2; }
        expr="DeskCloseTerminalTab($(lua_string "$2"))"
        ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

# The Lua call's own result is the last line hs prints; hs's exit status only
# says whether the IPC call went through.
out=$(run_hs "$expr")
hs_status=$?
if [ "$hs_status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    exit "$hs_status"
fi
last=$(printf '%s\n' "$out" | tail -n1)
case "$1:$last" in
    find:"terminal "?*) printf '%s\n' "${last#terminal }"; exit 0 ;;
    close:true) exit 0 ;;
esac
printf '%s\n' "$out" >&2
exit 1
