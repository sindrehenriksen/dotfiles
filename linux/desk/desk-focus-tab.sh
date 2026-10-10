#!/usr/bin/env bash
# The Linux counterpart of hammerspoon/desk-focus-tab.sh, with the same
# arguments. Ghostty on Linux exposes no way to find the window running a
# tty or to bring one forward from outside, so this never focuses anything:
# it says the session is running and exits 1, the "could not focus" result
# on which the notes hotkey reports and never resumes a second process.
#
# Usage: desk-focus-tab.sh <tty>
set -u

tty=${1:?usage: desk-focus-tab.sh <tty>}
printf 'the session is running on %s; Ghostty on Linux cannot bring its window forward\n' "$tty" >&2
exit 1
