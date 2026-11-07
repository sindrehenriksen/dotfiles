#!/usr/bin/env bash
# The Linux counterpart of hammerspoon/desk-close-tab.sh, with the same
# arguments and exit codes. Ghostty on Linux exposes no way to name the
# window a session runs in or to close one from outside, so `find` never
# names one: claude/close-session.sh leaves the window open, saying why. A
# session closed that way leaves its window at the shell prompt it was opened
# with. claude/restart-session.sh does not use this on Linux: its shell
# resumes the session itself (restart-session.sh, "marker").
#
# Usage: desk-close-tab.sh find <tty> <pid> | close <terminal-id>
#                          | pid <terminal-id> | type <terminal-id> <pid> <text>
# Exit 1 for any of them (the reason on stderr); 2 on usage.
set -u

usage='usage: desk-close-tab.sh find <tty> <pid> | close <terminal-id> | pid <terminal-id> | type <terminal-id> <pid> <text>'
case "${1:-}" in
    find) [ $# -eq 3 ] && [ -n "$2" ] && [[ "$3" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; } ;;
    close | pid) [ $# -eq 2 ] && [ -n "$2" ] || { echo "$usage" >&2; exit 2; } ;;
    type) [ $# -eq 4 ] && [ -n "$2" ] && [[ "$3" =~ ^[0-9]+$ ]] && [ -n "$4" ] || { echo "$usage" >&2; exit 2; } ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
echo "Ghostty on Linux cannot name, close or type into a window from outside" >&2
exit 1
