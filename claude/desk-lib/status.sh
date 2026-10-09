#!/usr/bin/env bash
# The status file writer: the one
# producer of $DESK_STATUS_FILE, which nvim/lua/desk/status.lua reads
# read-only. Every write goes through desk_status_update, so the file is
# always replaced atomically and never seen half-written by a concurrent
# reader (an editor repainting its statusline while a pass is running).
#
# Shape (per status.lua's own file-level comment, which is the one place
# this is pinned): per pass under .passes.<name>: last_run (epoch seconds),
# result ("running"/"ok"/"failed"/"partial"), stopped_at (a step id, only
# meaningful for "failed"), failed_sources (array), scheduled_date (the
# guard's own key, set on the most recent "ok" — desk-lib/lock.sh's
# desk_scheduled_date_for, not necessarily last_run's own calendar date).
# Top-level: proposal ({state, partial, overflow, counts, untaken, dropped} —
# untaken is how many suggestions still wait on the user, dropped how many
# this pass threw out for a source URL no fetch returned), closes/refused_closes/
# failed_closes/lockouts (plain counts; closed_names holds the last few
# closed sessions' names), push (a plain status string),
# ticket_cache_age. The runner writes the per-pass fields and the push/lockouts/
# closes counters; the proposal summary is read off the standing proposal
# and the decision ledger once a pass is done.
set -u

desk_status_read() {
	if [ -s "$DESK_STATUS_FILE" ] && jq -e . "$DESK_STATUS_FILE" > /dev/null 2>&1; then
		cat "$DESK_STATUS_FILE"
	else
		echo '{}'
	fi
}

# Applies a jq filter to the current status file and writes the result back
# atomically. Extra args after the filter are passed through to jq
# (--arg/--argjson pairs), so a caller never has to shell-escape values into
# the filter string itself.
desk_status_update() {
	local filter="$1"
	shift
	local current new
	current="$(desk_status_read)"
	new="$(jq "$@" "$filter" <<< "$current")" || {
		desk_log - "status update failed (jq): $filter"
		return 1
	}
	desk_write_atomic "$DESK_STATUS_FILE" "$new"
}

# Marks a previous "running" entry for $1 as failed, and logs it — called
# under the shared runner lock before a fresh run marks itself running, so a
# crash from an earlier invocation is never silently overwritten by the next
# one without ever having been reported. Only a run holding that lock writes
# "running", and a live holder's lock is never broken, so a "running" record
# seen here is a dead run's, whatever its age.
desk_status_mark_stale_running() {
	local pass="$1" started
	started="$(jq -r --arg p "$pass" '.passes[$p] | select(.result == "running") | .last_run // 0' <<< "$(desk_status_read)")"
	[ -n "$started" ] || return 0
	desk_log "$pass" "the run started at $(date -r "$started" '+%F %T' 2> /dev/null || date -d "@$started" '+%F %T') never finished — marked failed"
	desk_status_update '
		.passes[$pass].result = "failed" | .passes[$pass].stopped_at = "stale (previous run never finished)"
	' --arg pass "$pass"
}

desk_status_set_running() {
	local pass="$1" now
	now="$(desk_now)"
	# `last_ok_run` (this pass's own last successful run's own `last_run`)
	# is carried forward explicitly rather
	# than dropped along with the rest of the previous record: a wholesale
	# `.passes[$pass] = {...}` replace here would otherwise wipe it the
	# moment a fresh run starts, which is exactly the bug this field
	# exists to avoid — desk_status_last_ok_run has to keep answering
	# correctly for a caller running *during this same pass* (the close
	# step's away-days valve), not just for the next invocation.
	desk_status_update '
		(.passes[$pass].last_ok_run // null) as $prev_ok
		| (.passes[$pass].last_fetch_ok // null) as $prev_fetch_ok
		| .passes[$pass] = { last_run: $now, result: "running", stopped_at: null, failed_sources: [] }
		| (if $prev_ok != null then .passes[$pass].last_ok_run = $prev_ok else . end)
		| (if $prev_fetch_ok != null then .passes[$pass].last_fetch_ok = $prev_fetch_ok else . end)
	' --arg pass "$pass" --argjson now "$now"
}

# $2 = result ("ok"/"failed"/"partial"), $3 = stopped_at (step id, or ""
# for none), $4 = failed_sources as a JSON array literal (or "[]"), $5 =
# scheduled_date ("" leaves the field untouched — a caller with no trigger
# context, e.g. a test fixture, keeps whatever was there, which is never
# read back unless it's also non-empty).
desk_status_set_result() {
	local pass="$1" result="$2" stopped_at="${3:-}" failed_sources="${4:-[]}" scheduled_date="${5:-}"
	desk_status_update '
		.passes[$pass].result = $result
		| .passes[$pass].stopped_at = (if $stopped_at == "" then null else $stopped_at end)
		| .passes[$pass].failed_sources = $failed_sources
		| (if $scheduled_date == "" then . else .passes[$pass].scheduled_date = $scheduled_date end)
		| (if $result == "ok" then .passes[$pass].last_ok_run = .passes[$pass].last_run else . end)
	' --arg pass "$pass" --arg result "$result" --arg stopped_at "$stopped_at" \
		--argjson failed_sources "$failed_sources" --arg scheduled_date "$scheduled_date"
}

# The epoch of $1's own last successful ("ok") run, or "" if it's never
# had one — the runner's own basis for a fetch step's lookback window
# (steps.sh: "since this pass last actually finished ok", falling back to
# a fixed default when there's no prior run at all). Reads the durable
# `last_ok_run` field directly rather than `select(.result == "ok")`
# against the *current* record: the current record reads "running" (or
# even "failed") for most of a pass's own lifetime, including every call
# made from inside that same pass (the close step's away-days valve) —
# `last_ok_run` is exactly the field desk_status_set_running/
# desk_status_set_result keep alive across that.
desk_status_last_ok_run() {
	local pass="$1"
	jq -r --arg p "$pass" '.passes[$p].last_ok_run // empty' <<< "$(desk_status_read)"
}

# The epoch through which $1's own fetch steps have actually succeeded, or
# "" if they never have — a separate, narrower record than last_ok_run:
# desk-run's own weekend commit-only invocations (the weekday_only_pass
# guard skips every model-calling step, fetch included, but still runs
# commit_push and can still finish the pass "ok") must never advance the
# mail/Slack lookback window, since no fetch actually ran to have covered
# anything since last_fetch_ok. Only desk_status_set_fetch_ok (called by
# desk-run itself, only when at least one fetch step actually ran this
# pass and none failed) ever moves this forward.
desk_status_last_fetch_ok() {
	local pass="$1"
	jq -r --arg p "$pass" '.passes[$p].last_fetch_ok // empty' <<< "$(desk_status_read)"
}

# Records $1's own fetch window as covered through $2 (epoch) — the new
# floor for the NEXT run's own gmail_window_start, so a mail/Slack window
# never silently narrows (weekend runs) or leaves a gap (a slot that
# retried a partial pass, whose successful sources already got the wider
# window they asked for).
desk_status_set_fetch_ok() {
	local pass="$1" epoch="$2"
	desk_status_update '.passes[$pass].last_fetch_ok = $epoch' --arg pass "$pass" --argjson epoch "$epoch"
}

# A run that gave up waiting for the lock does not hold it, so it must not
# rewrite status.json under the holder's feet: it appends a line to this
# file instead, and whoever holds the lock folds the lines into `lockouts`
# (desk_status_fold_lockouts).
DESK_LOCKOUTS_PENDING_FILE="${DESK_LOCKOUTS_PENDING_FILE:-$DESK_STATUS_FILE.lockouts}"

desk_status_note_lockout() {
	printf '%s\n' "$1" >> "$DESK_LOCKOUTS_PENDING_FILE" 2> /dev/null
}

# Under the lock: adds the lockouts noted since the last fold to the count.
desk_status_fold_lockouts() {
	local taken="$DESK_LOCKOUTS_PENDING_FILE.$$" n
	mv -f "$DESK_LOCKOUTS_PENDING_FILE" "$taken" 2> /dev/null || return 0
	n="$(wc -l < "$taken" | tr -d ' ')"
	rm -f "$taken"
	[ "${n:-0}" -gt 0 ] && desk_status_bump lockouts "$n"
	return 0
}

desk_status_bump() {
	local field="$1" by="${2:-1}"
	desk_status_update '.[$field] = ((.[$field] // 0) + $by)' --arg field "$field" --argjson by "$by"
}

# Appends a session's name to .closed_names (the last ten are kept), so the
# status line can say which sessions the real closes were.
desk_status_note_closed() {
	desk_status_update '.closed_names = (((.closed_names // []) + [$name]) | .[-10:])' --arg name "$1"
}

desk_status_set_field() {
	local field="$1" value_json="$2"
	desk_status_update '.[$field] = $value' --arg field "$field" --argjson value "$value_json"
}

desk_status_set_string_field() {
	local field="$1" value="$2"
	desk_status_update '.[$field] = $value' --arg field "$field" --arg value "$value"
}
