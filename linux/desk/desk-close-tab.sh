#!/usr/bin/env bash
# The Linux counterpart of hammerspoon/desk-close-tab.sh, with the same
# arguments and exit codes. Ghostty on Linux exposes no way to name the
# window a session runs in or to close one from outside, so `find` never
# names one and claude/close-session.sh leaves the window open, saying why.
# A session closed that way leaves its window showing the shell or the
# exit prompt it was opened with.
#
# Usage: desk-close-tab.sh find <tty> <pid> | close <terminal-id>
# Exit 1 for either (the reason on stderr); 2 on usage.
set -u

usage='usage: desk-close-tab.sh find <tty> <pid> | close <terminal-id>'
case "${1:-}" in
    find) [ $# -eq 3 ] && [ -n "$2" ] && [[ "$3" =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; } ;;
    close) [ $# -eq 2 ] && [ -n "$2" ] || { echo "$usage" >&2; exit 2; } ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
echo "Ghostty on Linux cannot name or close a window from outside" >&2
exit 1
