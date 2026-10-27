#!/usr/bin/env bash
# The once-a-day guard, which reads the status file for whether this
# scheduled date already had a run, and the lock, which keeps two runs from
# overlapping.
set -u

# True (exit 0) if /proc/stat is readable — the same Linux/macOS branch
# point session-status.sh's own `is_linux` uses, duplicated here rather than
# shared: this file is sourced standalone by tests that never load that
# script.
desk_is_linux() { [ -r /proc/stat ]; }

# The epoch for "$1 (YYYY-MM-DD) at $2:$3:00 local time", or empty on a
# parse failure. The one date-arithmetic primitive desk_scheduled_date_for
# builds on, so the GNU/BSD `date` split lives in exactly one place.
desk_epoch_at() {
	local day="$1" hour="$2" minute="$3"
	hour="$(printf '%02d' "$((10#$hour))" 2> /dev/null)" || return 1
	minute="$(printf '%02d' "$((10#$minute))" 2> /dev/null)" || return 1
	if desk_is_linux; then
		date -d "$day $hour:$minute:00" +%s 2> /dev/null
	else
		date -j -f "%Y-%m-%d %H:%M:%S" "$day $hour:$minute:00" +%s 2> /dev/null
	fi
}

# "YYYY-MM-DD" and its %u weekday (1=Mon..7=Sun) for $2 days before $1
# (epoch), one tab-separated line.
desk_day_before() {
	local now="$1" off="$2"
	if desk_is_linux; then
		# GNU date takes no offset after an @epoch, so it goes on the local
		# date, at noon so a DST change never moves the day, and as "N days
		# ago", since a "-N" after a time reads as a zone.
		date -d "$(date -d "@$now" +%F) 12:00 $off days ago" '+%F	%u' 2> /dev/null
	else
		date -j -r "$now" -v-"${off}"d '+%F	%u' 2> /dev/null
	fi
}

# The calendar date (local, YYYY-MM-DD) of the most recent configured slot
# at-or-before $2 (epoch, default now) — the slot's
# scheduled date, not the date desk-run actually happened to be invoked on.
# $1 is a JSON array of {hour, minute} (daily) or {hour, minute, weekday}
# (weekly, 1=Mon..7=Sun per `date +%u`) slot objects — a pass's own
# `.trigger.start_calendar_interval`. This is what makes an evening slot that
# only actually runs on the next morning's wake still read as *yesterday's*
# (its most recent past slot is still last night's, since today's own
# evening slot hasn't happened yet) rather than a fresh one for today —
# and, symmetrically, why today's real evening firing later that same day
# lands on a different scheduled date and is never treated as a repeat.
# An empty/missing slot list falls back to $2's own calendar date, so a step
# or test with no trigger configured keeps the simple "today" behavior this
# replaces.
desk_scheduled_date_for() {
	local slots_json="${1:-[]}" now="${2:-$(desk_now)}"
	local n
	n="$(jq 'length' <<< "$slots_json" 2> /dev/null || echo 0)"
	if [ "$n" -eq 0 ]; then
		if desk_is_linux; then date -d "@$now" +%F; else date -j -r "$now" +%F; fi
		return
	fi

	local best=""
	local i
	for ((i = 0; i < n; i++)); do
		local slot hour minute weekday
		slot="$(jq -c ".[$i]" <<< "$slots_json")"
		hour="$(jq -r '.hour' <<< "$slot")"
		minute="$(jq -r '.minute' <<< "$slot")"
		weekday="$(jq -r '.weekday // empty' <<< "$slot")"
		local off
		for off in 0 1 2 3 4 5 6 7; do
			local day_str day_dow
			IFS=$'\t' read -r day_str day_dow < <(desk_day_before "$now" "$off")
			[ -n "$day_str" ] || continue
			if [ -n "$weekday" ] && [ "$day_dow" != "$weekday" ]; then
				continue
			fi
			local cand
			cand="$(desk_epoch_at "$day_str" "$hour" "$minute")"
			[ -n "$cand" ] || continue
			if [ "$cand" -le "$now" ] && { [ -z "$best" ] || [ "$cand" -gt "$best" ]; }; then
				best="$cand"
			fi
		done
	done

	if [ -z "$best" ]; then
		# No configured slot fell at-or-before $now within the lookback
		# window — shouldn't happen for a real trigger, but fall back to
		# $now's own date rather than error.
		if desk_is_linux; then date -d "@$now" +%F; else date -j -r "$now" +%F; fi
		return
	fi
	if desk_is_linux; then date -d "@$best" +%F; else date -j -r "$best" +%F; fi
}

# The weekday (1=Mon..7=Sun) of the calendar date $1 (YYYY-MM-DD), empty on a
# parse failure.
desk_weekday_of_date() {
	if desk_is_linux; then
		date -d "$1" +%u 2> /dev/null
	else
		date -j -f "%Y-%m-%d" "$1" +%u 2> /dev/null
	fi
}

# The epoch for the most recent past occurrence of weekday $2 (1=Mon..7=Sun,
# per `date +%u`) at $3:$4 local time, strictly before $1 (epoch) — never
# today's own even when today already matches $2 (the weekly pass's own
# notes-diff window wants *last* Wednesday, not this morning's). Built on
# the same desk_day_before/desk_epoch_at primitives desk_scheduled_date_for
# already uses, so a caller never needs its own GNU/BSD date split for this.
# Empty on a parse failure.
desk_last_weekday_epoch() {
	local now="$1" weekday="$2" hour="$3" minute="$4"
	local off
	for off in 1 2 3 4 5 6 7; do
		local day_str day_dow
		IFS=$'\t' read -r day_str day_dow < <(desk_day_before "$now" "$off")
		[ -n "$day_str" ] || continue
		if [ "$day_dow" = "$weekday" ]; then
			desk_epoch_at "$day_str" "$hour" "$minute"
			return
		fi
	done
}

# True (exit 0) if $1 already ran for $2's own scheduled date, whatever
# came of it: ok, partial, or failed (a run that never finished is marked
# failed first, desk_status_mark_stale_running). A pass runs once a
# scheduled date; a later slot is only for a date that never got a run
# (see desk_scheduled_date_for for what "scheduled date" means here
# instead of simply "today").
desk_guard_already_ran_today() {
	local pass="$1" scheduled_date="$2" status result last_scheduled_date
	status="$(desk_status_read)"
	result="$(jq -r --arg p "$pass" '.passes[$p].result // empty' <<< "$status")"
	case "$result" in ok | partial | failed) ;; *) return 1 ;; esac
	last_scheduled_date="$(jq -r --arg p "$pass" '.passes[$p].scheduled_date // empty' <<< "$status")"
	[ -n "$last_scheduled_date" ] || return 1
	[ "$last_scheduled_date" = "$scheduled_date" ]
}

# One lock for every scheduled pass, which share the notes repo, the ledger
# and the status file; the follow pass takes its own (DESK_LOCK_NAME=follow).
# It is flock(2) on an open file, taken through perl since macOS has no
# flock command: the lock lives on the open file description that this
# shell keeps on fd 9, so it outlives the perl that took it and goes with
# this shell however that ends. A run that died leaves nothing to break.
DESK_LOCK_NAME="runner"

# Takes the lock, waiting for its holder up to $DESK_LOCK_MAX_WAIT_SECS.
# Returns 1 when it gave up. Called in this shell, never a subshell, which
# would hold the lock only as long as itself.
desk_lock_acquire() {
	local waited=0
	mkdir -p "$DESK_LOCK_DIR" 2> /dev/null
	exec 9>> "$DESK_LOCK_DIR/$DESK_LOCK_NAME.flock" || return 1
	until perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 2; flock($fh, LOCK_EX | LOCK_NB) or exit 1'; do
		if [ "$waited" -ge "$DESK_LOCK_MAX_WAIT_SECS" ]; then
			exec 9>&-
			return 1
		fi
		sleep "$DESK_LOCK_POLL_SECS"
		waited=$((waited + DESK_LOCK_POLL_SECS))
	done
}

desk_lock_release() {
	exec 9>&-
}

# The exact count of Mon-Fri calendar dates strictly after $1's own date and
# strictly before $2's (default now): the whole working days that have
# passed since, so the day $2 falls on never counts, however far into it.
# The close step's "idle ≥ N working days", as a real day-by-day walk built
# on desk_day_before. 0 when the epochs fall on the same or consecutive dates.
desk_working_days_since() {
	local since_epoch="$1" now="${2:-$(desk_now)}"
	local since_date
	if desk_is_linux; then
		since_date="$(date -d "@$since_epoch" +%F 2> /dev/null)"
	else
		since_date="$(date -j -r "$since_epoch" +%F 2> /dev/null)"
	fi
	[ -n "$since_date" ] || { echo 0; return; }
	local today
	today="$(desk_day_before "$now" 0 | cut -f1)"
	[[ "$since_date" < "$today" ]] || { echo 0; return; }

	local count=0 off=1 day_str day_dow
	while [ "$off" -lt 400 ]; do
		IFS=$'\t' read -r day_str day_dow < <(desk_day_before "$now" "$off")
		[ -n "$day_str" ] || break
		[ "$day_str" = "$since_date" ] && break
		[ "$day_dow" -le 5 ] && count=$((count + 1))
		off=$((off + 1))
	done
	echo "$count"
}
