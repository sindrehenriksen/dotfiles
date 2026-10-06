#!/usr/bin/env bash
# Focuses the Ghostty tab running a given tty, via the DeskFocusTab
# Hammerspoon function (init.lua) — the shell-level entry point for the
# notes hotkey's live-session case, alongside desk-open-tab.sh for
# resuming a non-live one.
#
# Unlike desk-open-tab.sh (fire-and-forget: opening a tab has nothing
# useful to fall back to), this script's exit code is load-bearing: the
# hotkey must never resume a session its own focus attempt just failed on,
# so it reads DeskFocusTab's true/false return off `hs -c`'s own output
# rather than just trusting `hs -c`'s process exit code, which reflects
# whether the IPC connection worked, not whether the Lua call it ran
# returned true.
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

out=$(hs -c "DeskFocusTab($(lua_string "$tty"))")
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
