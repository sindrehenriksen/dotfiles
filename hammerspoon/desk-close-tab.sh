#!/usr/bin/env bash
# Acts on the Ghostty tab a session runs in, through the DeskTabTerminal,
# DeskCloseTerminalTab, DeskTerminalPid and DeskTypeInTerminal Hammerspoon
# functions (init.lua): the shell-level entry point claude/close-session.sh
# and claude/restart-session.sh use, beside desk-open-tab.sh and
# desk-focus-tab.sh.
#
# Usage: desk-close-tab.sh find <tty> <pid>
#            Prints the id of the one Ghostty terminal on <tty> whose
#            foreground process is <pid>. Run while that process still
#            holds the tty: a terminal id is never reused, a tty is.
#        desk-close-tab.sh close <terminal-id>
#            Closes the tab holding that terminal when nothing else is in
#            it, keeping focus where it was.
#        desk-close-tab.sh pid <terminal-id>
#            Prints that terminal's foreground pid.
#        desk-close-tab.sh type <terminal-id> <pid> <text>
#            Clears the terminal's line, pastes <text> and presses enter,
#            only while <pid> is its foreground process. Focus stays put.
#
# Exit 0 on success; 1 when Hammerspoon said no (its reason on stderr); 124
# when hs did not return in DESK_HS_TIMEOUT_SECS (default 6); 2 on usage.
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

usage='usage: desk-close-tab.sh find <tty> <pid> | close <terminal-id> | pid <terminal-id> | type <terminal-id> <pid> <text>'


case "${1:-}" in
    find)
        [ $# -eq 3 ] && [ -n "$2" ] && [[ "$3" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }
        expr="DeskTabTerminal($(lua_string "$2"), $3)"
        ;;
    close)
        [ $# -eq 2 ] && [ -n "$2" ] || { echo "$usage" >&2; exit 2; }
        expr="DeskCloseTerminalTab($(lua_string "$2"))"
        ;;
    pid)
        [ $# -eq 2 ] && [ -n "$2" ] || { echo "$usage" >&2; exit 2; }
        expr="DeskTerminalPid($(lua_string "$2"))"
        ;;
    type)
        [ $# -eq 4 ] && [ -n "$2" ] && [[ "$3" =~ ^[0-9]+$ ]] && [ -n "$4" ] || { echo "$usage" >&2; exit 2; }
        expr="DeskTypeInTerminal($(lua_string "$2"), $3, $(lua_string "$4"))"
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
    pid:"pid "?*) printf '%s\n' "${last#pid }"; exit 0 ;;
    close:true | type:true) exit 0 ;;
esac
printf '%s\n' "$out" >&2
exit 1
