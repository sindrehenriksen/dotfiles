#!/usr/bin/env bash
# The status file writer, the one producer of $DESK_STATUS_FILE, which
# nvim/lua/desk/status.lua reads. Every write replaces the file atomically.
#
# Per pass under .passes.<name>: last_run (epoch), result
# ("running"/"ok"/"partial"/"failed"), stopped_at (a step id, on a failure),
# failed_sources (the steps that failed without stopping it),
# scheduled_date (the once-a-day guard's key), last_ok_run and
# last_done_run, and total_cost_usd. Top level: proposal ({state, partial,
# counts, untaken}), push (a status word) and ticket_cache_age.
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

# Marks a previous "running" entry for $1 as failed, and logs it, so a run
# that died is reported rather than overwritten. Called under the runner
# lock, which only a live run holds, so a "running" record seen here is a
# dead run's.
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
	local pass="$1" scheduled_date="${2:-}" now
	now="$(desk_now)"
	# The last ok and last finished runs are carried over: the close step
	# reads them during this run.
	desk_status_update '
		(.passes[$pass].last_ok_run // null) as $prev_ok
		| (.passes[$pass].last_done_run // null) as $prev_done
		| .passes[$pass] = { last_run: $now, result: "running", stopped_at: null, failed_sources: [] }
		| (if $scheduled_date == "" then . else .passes[$pass].scheduled_date = $scheduled_date end)
		| (if $prev_ok != null then .passes[$pass].last_ok_run = $prev_ok else . end)
		| (if $prev_done != null then .passes[$pass].last_done_run = $prev_done else . end)
	' --arg pass "$pass" --argjson now "$now" --arg scheduled_date "$scheduled_date"
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
		| .passes[$pass].last_done_run = .passes[$pass].last_run
	' --arg pass "$pass" --arg result "$result" --arg stopped_at "$stopped_at" \
		--argjson failed_sources "$failed_sources" --arg scheduled_date "$scheduled_date"
}

# The epoch of $1's last ok run, or "" when it has had none.
desk_status_last_ok_run() {
	jq -r --arg p "$1" '.passes[$p].last_ok_run // empty' <<< "$(desk_status_read)"
}

# The epoch of $1's last run that reached its end, whatever its result, or
# "" if none has: the close step's measure of how long the machine has gone
# without a pass, which a source failing every day must not stretch.
desk_status_last_done_run() {
	jq -r --arg p "$1" '.passes[$p] | .last_done_run // .last_ok_run // empty' <<< "$(desk_status_read)"
}

desk_status_set_field() {
	local field="$1" value_json="$2"
	desk_status_update '.[$field] = $value' --arg field "$field" --argjson value "$value_json"
}

desk_status_set_string_field() {
	local field="$1" value="$2"
	desk_status_update '.[$field] = $value' --arg field "$field" --arg value "$value"
}
