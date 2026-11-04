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

tty=${1:?usage: desk-focus-tab.sh <tty>}


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
