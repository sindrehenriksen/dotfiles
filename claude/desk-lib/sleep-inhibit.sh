#!/usr/bin/env bash
# The sleep inhibitor a pass holds on Linux. A machine woken for a slot
# with its lid shut is put back to sleep by logind or GNOME, mid-pass,
# unless something says not to; launchd's wake has no such problem, so
# macOS takes none.
#
# The inhibitor is held by a background `systemd-inhibit` whose command
# first marks that it is running (so the lock is known to be taken) and
# then waits on the runner's pid, so it goes when the runner does, however
# it ends: desk_sleep_inhibit_release kills it on a normal exit, and
# `tail --pid` ends it within a second of a kill the runner could not trap.
# Not taking one is logged and the pass goes on, as it would have without.
set -u

# Overridable so a test runs a stub instead of taking a real inhibitor.
DESK_INHIBIT_BIN="${DESK_INHIBIT_BIN:-systemd-inhibit}"
# How long to wait for the holder to say the inhibitor is taken.
DESK_INHIBIT_WAIT_SECS="${DESK_INHIBIT_WAIT_SECS:-5}"
DESK_INHIBIT_PID=""

# desk_sleep_inhibit <pass> <dir>: takes the inhibitor for the rest of this
# process, its marker and error output kept in <dir>. Always returns 0.
desk_sleep_inhibit() {
	local pass="$1" dir="$2" ready err why waited=0
	desk_is_linux || return 0
	if ! command -v "$DESK_INHIBIT_BIN" > /dev/null 2>&1; then
		desk_log "$pass" "no sleep inhibitor: $DESK_INHIBIT_BIN is not on PATH, so a machine woken for this pass can sleep again mid-pass"
		return 0
	fi
	ready="$dir/.sleep-inhibited"
	err="$dir/.sleep-inhibit.err"
	rm -f "$ready"
	"$DESK_INHIBIT_BIN" --what=sleep:idle:handle-lid-switch --mode=block \
		--who=desk --why="desk pass $pass" \
		/bin/sh -c ': > "$1" && exec tail --pid="$2" -f /dev/null' sh "$ready" "$$" \
		< /dev/null > /dev/null 2> "$err" &
	DESK_INHIBIT_PID=$!
	while [ ! -e "$ready" ]; do
		if ! kill -0 "$DESK_INHIBIT_PID" 2> /dev/null || [ "$waited" -ge $((DESK_INHIBIT_WAIT_SECS * 10)) ]; then
			desk_sleep_inhibit_release
			why="$(tr '\n' ' ' < "$err" 2> /dev/null | sed 's/ *$//')"
			desk_log "$pass" "no sleep inhibitor: $DESK_INHIBIT_BIN did not take one${why:+ ($why)}, so a machine woken for this pass can sleep again mid-pass"
			return 0
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
	desk_log "$pass" "sleep inhibitor taken (sleep, idle, lid switch) until the pass ends"
}

# Releases the inhibitor, if one is held.
desk_sleep_inhibit_release() {
	[ -n "$DESK_INHIBIT_PID" ] || return 0
	kill "$DESK_INHIBIT_PID" 2> /dev/null
	wait "$DESK_INHIBIT_PID" 2> /dev/null
	DESK_INHIBIT_PID=""
	return 0
}
