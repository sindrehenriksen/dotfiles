#!/usr/bin/env bash
# The Linux counterpart of hammerspoon/desk-open-tab.sh, with the same
# arguments and exit codes, so the notes hotkey, the scheduled passes and
# reopen-sessions.sh call it unchanged. Ghostty on Linux offers no way to
# add a tab to a window from outside, only a new window in the running
# instance (`ghostty +new-window`, over D-Bus), so each open is a window.
#
# Usage: desk-open-tab.sh <command> [session-id] [cwd] [flags]
# `session-id` and `cwd` are optional; pass "" to skip session-id and still
# give a cwd. A session id that is not UUID-shaped opens nothing. `flags` is
# a comma-separated list:
#   background  accepted for the same calls, but the window manager decides
#               focus: nothing here can keep the new window from taking it;
#   close       close the window when its command exits; without it the
#               window waits for a key, so a finished session can still be
#               read.
#
# The command runs through `/bin/zsh -lic`, as on macOS, so it gets the
# login shell's PATH and CLAUDE_CONFIG_DIR rather than the environment of
# the Ghostty instance that spawns it.
#
# Exit 0 when Ghostty took the request; 1 when it did not (its output on
# stderr) or the session id was refused; 2 on usage; 124 when it did not
# return within DESK_TAB_TIMEOUT_SECS (default 6).
set -u

usage='usage: desk-open-tab.sh <command> [session-id] [cwd] [background,close]'
cmd=${1:?$usage}
session_id=${2:-}
cwd=${3:-}
close_on_exit=false
IFS=, read -r -a flags <<< "${4:-}"
for flag in ${flags[@]+"${flags[@]}"}; do
    case $flag in
        background) ;;
        close) close_on_exit=true ;;
        *) printf '%s\n' "$usage" >&2; exit 2 ;;
    esac
done

if [ -n "$session_id" ] && ! [[ "$session_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf 'desk-open-tab: refusing non-UUID session id: %s\n' "$session_id" >&2
    exit 1
fi

# Ghostty closes a window when its command exits, so the wait that keeps a
# finished session readable is the shell's own.
if [ "$close_on_exit" = false ]; then
    cmd="$cmd"'; print -n "\n[exited $?; press any key to close]"; read -sk1'
fi

args=(+new-window)
[ -n "$cwd" ] && args+=("--working-directory=$cwd")
args+=(-e /bin/zsh -lic "$cmd")

limit=${DESK_TAB_TIMEOUT_SECS:-6}
out=$(timeout -k 1 "$limit" "${DESK_GHOSTTY_BIN:-ghostty}" "${args[@]}" < /dev/null 2>&1)
status=$?
if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
    printf 'ghostty did not return within %ss; killed\n' "$limit" >&2
    exit 124
fi
if [ "$status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    exit 1
fi
exit 0
