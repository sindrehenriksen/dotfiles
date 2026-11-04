#!/usr/bin/env bash
# Makes the window of the terminal nvim runs in full height and puts it
# back, via DeskWindowTall and DeskWindowRestore in hammerspoon/init.lua: the
# shell-level entry point nvim's desk review overview uses while its list is
# open. The terminal is named by its tty and the pid in its foreground, the
# way desk-close-tab.sh names one.
#
#   desk-window.sh tall <tty> <pid>     prints "tall" when the window is full
#                                       height now, "none" when Hammerspoon
#                                       left it (not that terminal's focused
#                                       window, or at no placement with a
#                                       full-height form)
#   desk-window.sh restore <tty> <pid>  exits 0 when the window went back, 1
#                                       when nothing was stretched for that
#                                       terminal, or the window was moved since
#
# The tty must look like one and the pid be a number, checked before either
# reaches the Lua call. A hang is killed after DESK_HS_TIMEOUT_SECS and exits
# 124, as the tab helpers' does.
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

usage() {
    echo "usage: desk-window.sh tall|restore <tty> <pid>" >&2
    exit 2
}


verb=${1:-}
[ $# -eq 3 ] || usage
tty=${2#/dev/}
pid=$3
[[ "$tty" =~ ^ttys?[0-9]+$ ]] || usage
[[ "$pid" =~ ^[0-9]+$ ]] || usage
case "$verb" in
    tall) call="DeskWindowTall(\"$tty\", $pid)" ;;
    restore) call="DeskWindowRestore(\"$tty\", $pid)" ;;
    *) usage ;;
esac

out=$(run_hs "$call")
hs_status=$?
if [ "$hs_status" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    exit "$hs_status"
fi

last_line=$(printf '%s\n' "$out" | tail -n1)
case "$verb" in
    tall)
        if [ "$last_line" = "tall" ] || [ "$last_line" = "none" ]; then
            printf '%s\n' "$last_line"
            exit 0
        fi
        ;;
    *)
        [ "$last_line" = "true" ] && exit 0
        [ "$last_line" = "false" ] && exit 1
        ;;
esac
printf '%s\n' "$out" >&2
exit 1
