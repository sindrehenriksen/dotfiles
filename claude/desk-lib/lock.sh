#!/usr/bin/env bash
# The once-a-day guard and the mutual-exclusion lock.
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
# at-or-before $2 (epoch, default now) — the slot's
# scheduled date, not the date desk-run actually happened to be invoked on.
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

# True (exit 0) if $1 already completed "ok" for $2's own scheduled date
# (a slot whose scheduled date already
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

# Seconds-since-epoch $1 (a pid) started, via `ps -o etime=` — arithmetic
# only, no locale-sensitive date parsing (the same technique
# session-status.sh's own parse_etime_secs uses, duplicated here since
# lock.sh is sourced standalone by tests that never load that script).
# Empty (and non-zero exit) if the pid isn't running or etime can't be
# parsed.
desk_pid_start_epoch() {
	local pid="$1" etime
	etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
	[ -n "$etime" ] || return 1
	local dd=0 hh=0 mm='' ss='' rest=$etime a b c
	case "$etime" in
		*-*)
			dd=${etime%%-*}
			rest=${etime#*-}
			;;
	esac
	IFS=: read -r a b c <<< "$rest"
	if [ -n "${c:-}" ]; then
		hh=$a
		mm=$b
		ss=$c
	else
		mm=$a
		ss=$b
	fi
	[ -n "${mm:-}" ] && [ -n "${ss:-}" ] || return 1
	local etime_secs=$((10#$dd * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
	echo $(($(desk_now) - etime_secs))
}

# $1's own mtime (epoch seconds), or empty if it doesn't exist — used to
# time a lock dir's own "no meta yet" grace period off the directory's own
# creation time (mkdir sets it) rather than a second bookkeeping file.
desk_lock_dir_mtime() {
	local d="$1"
	if [ ! -e "$d" ]; then
		return 1
	fi
	if desk_is_linux; then
		stat -c %Y "$d" 2>/dev/null
	else
		stat -f %m "$d" 2>/dev/null
	fi
}

# Called by a waiter that has judged the lock's owner dead, just before it
# acts on that judgement. A no-op; a test overrides it to hold a waiter at
# exactly the point where another waiter may win the race.
desk_lock_pre_break() { :; }

# Breaks the lock at $1, which the caller read as owned by the dead $2 (pid).
# Only one waiter may do it, and never to a lock someone else has since taken:
#   - a waiter first wins `mkdir "$1.break"`; a loser does nothing and
#     re-reads the lock on its next iteration;
#   - the winner re-reads the owner under that guard (the lock it judged dead
#     may meanwhile have been broken and re-taken), and breaks only if it is
#     still $2;
#   - the break is an atomic rename of the lock dir to a unique stale name,
#     then a remove. A failed rename means another waiter already did it.
# A guard left by a waiter that died mid-break is removed once it is older
# than the no-meta grace period.
desk_lock_break_dead() {
	local lockdir="$1" dead_pid="$2" guard="$1.break"
	if ! mkdir "$guard" 2> /dev/null; then
		local gm now
		gm="$(desk_lock_dir_mtime "$guard" 2> /dev/null)" || gm=""
		now="$(desk_now)"
		if [ -n "$gm" ] && [ "$((now - gm))" -ge "$DESK_LOCK_NO_META_GRACE_SECS" ]; then
			rmdir "$guard" 2> /dev/null
		fi
		return 1
	fi
	local current
	current="$(jq -r '.pid // empty' "$lockdir/meta.json" 2> /dev/null)"
	if [ "$current" = "$dead_pid" ]; then
		local stale="$lockdir.stale.$$.$RANDOM"
		if mv "$lockdir" "$stale" 2> /dev/null; then
			rm -rf "$stale" 2> /dev/null
		fi
	fi
	rmdir "$guard" 2> /dev/null
	return 0
}

# Acquires the mkdir-based runner lock, waiting out a live holder up to
# $DESK_LOCK_MAX_WAIT_SECS and breaking a dead one immediately. Prints the
# lock directory and returns 0 on success; returns 1 (prints nothing) if it
# gave up waiting.
#
# meta.json is built in a temp dir under the lock's own parent (never
# inside $lockdir itself) and moved into place with a single same-
# filesystem file rename right after `mkdir "$lockdir"` succeeds — mkdir
# stays the actual mutex (portable, unlike relying on `mv`'s own directory-
# vs-file rename semantics), and this shrinks the window during which the
# lock dir exists with no meta.json to as close to zero as a local rename
# gets. That window can never be fully closed by construction alone, so a
# waiter that sees a meta-less lock dir treats it as held for a short grace
# period
# rather than tearing it down the instant it's seen — which is what made
# the old "dead lock owner" test flaky: two real processes racing meant a
# waiter could observe the winner's lock dir microseconds before its
# meta.json landed, and would previously destroy it out from under the
# winner. Once meta.json exists, the owner's aliveness is checked by pid
# AND by comparing its recorded start time against that same pid's current
# one (desk_pid_start_epoch) — a dead owner's pid reused by an unrelated
# process must never read as "still the lock's owner".
desk_lock_acquire() {
	local pass="$1" lockdir="$DESK_LOCK_DIR/$DESK_LOCK_NAME.lock" waited=0
	while true; do
		if [ ! -e "$lockdir" ]; then
			local tmpdir
			tmpdir="$(mktemp -d "$DESK_LOCK_DIR/.tmp-lock.XXXXXX" 2>/dev/null)"
			if [ -n "$tmpdir" ]; then
				local my_start
				my_start="$(desk_pid_start_epoch "$$" 2>/dev/null)" || my_start=""
				desk_write_atomic "$tmpdir/meta.json" \
					"$(jq -n --arg pass "$pass" --argjson pid "$$" --argjson started_at "$(desk_now)" \
						--argjson owner_start "${my_start:-null}" \
						'{pass: $pass, pid: $pid, started_at: $started_at, owner_start: $owner_start}')"
				if mkdir "$lockdir" 2>/dev/null; then
					mv -f "$tmpdir/meta.json" "$lockdir/meta.json" 2>/dev/null
					rmdir "$tmpdir" 2>/dev/null
					echo "$lockdir"
					return 0
				fi
				rm -rf "$tmpdir" 2>/dev/null
			fi
		fi

		local meta_exists="false" owner_pid="" owner_start=""
		if [ -f "$lockdir/meta.json" ]; then
			meta_exists="true"
			owner_pid="$(jq -r '.pid // empty' "$lockdir/meta.json" 2>/dev/null)"
			owner_start="$(jq -r '.owner_start // empty' "$lockdir/meta.json" 2>/dev/null)"
		fi

		if [ "$meta_exists" != "true" ]; then
			# Either genuinely no lock dir at all (the mkdir above just lost
			# a race to someone else, in the instant between our own mkdir
			# attempt and this check), or one that exists but hasn't had its
			# meta.json rename land yet. Either way: never torn down on
			# sight — only once it's been sitting there with no meta for
			# longer than the grace period does this read as a crash between
			# mkdir and the rename (never a real one so far in this codebase,
			# but the whole reason for the grace period rather than trusting
			# the rename to be instant).
			local now dir_mtime
			now="$(desk_now)"
			dir_mtime="$(desk_lock_dir_mtime "$lockdir" 2>/dev/null)" || dir_mtime=""
			if [ -z "$dir_mtime" ]; then
				: # no lock dir at all right now — just retry the mkdir below
			elif [ "$((now - dir_mtime))" -ge "$DESK_LOCK_NO_META_GRACE_SECS" ]; then
				rm -rf "$lockdir" 2>/dev/null
			fi
		else
			local live="false"
			if [ -n "$owner_pid" ] && desk_pid_alive "$owner_pid"; then
				if [ -z "$owner_start" ]; then
					# No start time recorded (shouldn't happen for a lock
					# this build wrote, but never trust a state this file
					# can't fully explain as automatically dead): pid
					# liveness alone decides.
					live="true"
				else
					local cur_start diff
					cur_start="$(desk_pid_start_epoch "$owner_pid" 2>/dev/null)" || cur_start=""
					if [ -n "$cur_start" ]; then
						diff=$((cur_start > owner_start ? cur_start - owner_start : owner_start - cur_start))
						[ "$diff" -le "$DESK_LOCK_LIVENESS_TOLERANCE_SECS" ] && live="true"
					fi
				fi
			fi
			if [ "$live" != "true" ]; then
				# The owner is dead, or its pid has been reused by a
				# different process since (start-time mismatch): break the
				# lock and retry the mkdir immediately, never counting this
				# iteration against the wait budget.
				desk_lock_pre_break
				desk_lock_break_dead "$lockdir" "$owner_pid" && continue
			fi
		fi

		if [ "$waited" -ge "$DESK_LOCK_MAX_WAIT_SECS" ]; then
			return 1
		fi
		sleep "$DESK_LOCK_POLL_SECS"
		waited=$((waited + DESK_LOCK_POLL_SECS))
	done
}

# Releases the runner lock only if THIS process is the one meta.json
# records as owning it —
# never a bare rm -rf, which would just as happily destroy a lock some
# other process has since (legitimately) acquired, e.g. after this
# process's own lock was broken as dead by a waiter that gave up on it.
desk_lock_release() {
	local lockdir="$DESK_LOCK_DIR/$DESK_LOCK_NAME.lock"
	[ -d "$lockdir" ] || return 0
	local owner_pid
	owner_pid="$(jq -r '.pid // empty' "$lockdir/meta.json" 2>/dev/null)"
	[ "$owner_pid" = "$$" ] || return 0
	rm -rf "$lockdir" 2>/dev/null
}

# The exact count of Mon-Fri calendar dates strictly after $1's own date up
# to and including $2's (default now) — the close step's "idle ≥ N working
# days", as a real day-by-day walk built on desk_day_before. 0 if both epochs fall on the
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
