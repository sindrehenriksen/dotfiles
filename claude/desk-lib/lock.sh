#!/usr/bin/env bash
# The once-a-day guard and the mutual-exclusion lock (design.md §5 Failure,
# and the Interfaces brief: "Guard keyed on (pass, the slot's scheduled
# date); mkdir lock recording pid + start time, broken when the owner is
# dead, a locked-out run waits").
#
# The two are deliberately separate: the guard answers "has this pass
# already finished ok today" (so a later retry slot the same day is a
# no-op), reusing the status file as its own record rather than a second
# on-disk marker; the lock answers "is another desk-run for this pass
# running right now" (so two slots firing close together, or a manual run
# overlapping a scheduled one, never race the same pass concurrently).
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
		date -d "@$now -$off days" '+%F	%u' 2> /dev/null
	else
		date -j -r "$now" -v-"${off}"d '+%F	%u' 2> /dev/null
	fi
}

# The calendar date (local, YYYY-MM-DD) of the most recent configured slot
# at-or-before $2 (epoch, default now) — the Interfaces brief's "the slot's
# scheduled date", not the date desk-run actually happened to be invoked on.
# $1 is a JSON array of {hour, minute} (daily) or {hour, minute, weekday}
# (weekly, 1=Mon..7=Sun per `date +%u`) slot objects — a pass's own
# `.trigger.start_calendar_interval`. This is what makes a 16:30 pass that
# only actually runs on the next morning's wake still read as *yesterday's*
# evening slot (its most recent past slot is still last night's, since
# today's own 16:30 hasn't happened yet) rather than a fresh one for today —
# and, symmetrically, why today's real 16:30 firing later that same day
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

# True (exit 0) if $1 already completed "ok" for $2's own scheduled date
# (design's "later slots only retry": a slot whose scheduled date already
# succeeded is a no-op, not a second run — see desk_scheduled_date_for for
# what "scheduled date" means here instead of simply "today").
desk_guard_already_ok_today() {
	local pass="$1" scheduled_date="$2" status result last_scheduled_date
	status="$(desk_status_read)"
	result="$(jq -r --arg p "$pass" '.passes[$p].result // empty' <<< "$status")"
	[ "$result" = "ok" ] || return 1
	last_scheduled_date="$(jq -r --arg p "$pass" '.passes[$p].scheduled_date // empty' <<< "$status")"
	[ -n "$last_scheduled_date" ] || return 1
	[ "$last_scheduled_date" = "$scheduled_date" ]
}

# One lock, shared across every pass ("morning and 16:30 must never run at
# once" — they share the same notes repo, ledger and status.json, so two
# passes racing each other is exactly as unsafe as the same pass running
# twice). $1 (the pass name) is recorded in the lock's own meta.json purely
# for a waiting caller's diagnostics — it never changes which lock is taken.
DESK_LOCK_NAME="runner"

# Acquires the mkdir-based runner lock, waiting out a live holder up to
# $DESK_LOCK_MAX_WAIT_SECS and breaking a dead one immediately. Prints the
# lock directory and returns 0 on success; returns 1 (prints nothing) if it
# gave up waiting.
desk_lock_acquire() {
	local pass="$1" lockdir="$DESK_LOCK_DIR/$DESK_LOCK_NAME.lock" waited=0
	while true; do
		if mkdir "$lockdir" 2>/dev/null; then
			desk_write_atomic "$lockdir/meta.json" \
				"$(jq -n --arg pass "$pass" --argjson pid "$$" --argjson started_at "$(desk_now)" \
					'{pass: $pass, pid: $pid, started_at: $started_at}')"
			echo "$lockdir"
			return 0
		fi
		local owner_pid=""
		if [ -f "$lockdir/meta.json" ]; then
			owner_pid="$(jq -r '.pid // empty' "$lockdir/meta.json" 2>/dev/null)"
		fi
		if [ -z "$owner_pid" ] || ! desk_pid_alive "$owner_pid"; then
			# The owner is dead (or its meta never got written — a crash
			# mid-mkdir): break the lock and retry the mkdir immediately,
			# never counting this iteration against the wait budget.
			rm -rf "$lockdir" 2>/dev/null
			continue
		fi
		if [ "$waited" -ge "$DESK_LOCK_MAX_WAIT_SECS" ]; then
			return 1
		fi
		sleep "$DESK_LOCK_POLL_SECS"
		waited=$((waited + DESK_LOCK_POLL_SECS))
	done
}

desk_lock_release() {
	rm -rf "$DESK_LOCK_DIR/$DESK_LOCK_NAME.lock" 2>/dev/null
}

# The exact count of Mon-Fri calendar dates strictly after $1's own date up
# to and including $2's (default now) — design.md §3 "Closing"'s own "idle
# ≥ 3 working days", replacing the close step's earlier calendar-day
# approximation (steps.sh's own documented placeholder) with a real
# day-by-day walk built on desk_day_before. 0 if both epochs fall on the
# same calendar date.
desk_working_days_since() {
	local since_epoch="$1" now="${2:-$(desk_now)}"
	local since_date
	if desk_is_linux; then
		since_date="$(date -d "@$since_epoch" +%F 2> /dev/null)"
	else
		since_date="$(date -j -r "$since_epoch" +%F 2> /dev/null)"
	fi
	[ -n "$since_date" ] || { echo 0; return; }

	local count=0 off=0 day_str day_dow
	while [ "$off" -lt 400 ]; do
		IFS=$'\t' read -r day_str day_dow < <(desk_day_before "$now" "$off")
		[ -n "$day_str" ] || break
		[ "$day_str" = "$since_date" ] && break
		[ "$day_dow" -le 5 ] && count=$((count + 1))
		off=$((off + 1))
	done
	echo "$count"
}
