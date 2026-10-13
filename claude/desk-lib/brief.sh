#!/usr/bin/env bash
# The central brief (docs/desk.md, "The central brief"): instead of judging
# its own fetches, a pass with a `brief` hands them to the central session,
# the long-lived Claude Code session the user steers from, as one message.
# The central session judges with its own context, by the instruction files
# the message names.
#
# After the pass, desk_brief_after_pass writes the run directory
# ($DESK_RUNS_ROOT/<pass>-<date>/): the judge-style inputs under inputs/,
# the instruction files rendered under instructions/, the URLs a suggestion
# may cite in allowed-urls.txt, how the run went in run-status.txt and
# run.json, what the pass staged itself in staged.json, the mail triage's
# noise in mail-noise.json, and beside them the close step's close/. Then it
# marks the run `brief.pending` and delivers.
#
# Delivery is the follow pass's: the address check (desk_follow_address) and
# the one restricted, pinned SendMessage call (desk_follow_send). A brief
# that cannot go (the central session not running, its name not addressing
# it alone, or the send failing) stays pending, and every later run of the
# pass tries again, a later slot the same day included; a run of a new day
# sends its own brief and every older pending one in one message. A send
# that ran without confirming a delivery is tried once more, then counted
# as sent, as the follow pass counts it.
set -u

declare -F desk_follow_send > /dev/null || source "$DESK_LIB_DIR/follow.sh"

# The first characters of every brief, as `[desk-follow]` is a follow
# update's.
DESK_BRIEF_MARKER="[desk-brief]"

desk_brief_config() { jq -c '.brief // empty | select(type == "object")' <<< "$1"; }

desk_brief_run_dir() { printf '%s/%s-%s' "$DESK_RUNS_ROOT" "$1" "$2"; }

# desk_brief_prepare <pass> <brief json> <config> <pass_config> <repo>
#   <scheduled_date> <pass_ctx json> <placeholders json> <file>...
# Writes the run directory described above and marks it pending. Prints
# the run directory; returns 1 when the brief names no instruction file
# that exists, since a message naming none would ask for judging by nothing.
desk_brief_prepare() {
	local pass="$1" brief="$2" config="$3" pass_config="$4" repo="$5" scheduled_date="$6" pass_ctx="$7" placeholders="$8"
	shift 8
	local files=("$@") run files_json ctx
	run="$(desk_brief_run_dir "$pass" "$scheduled_date")"
	mkdir -p "$run"
	rm -rf "$run/inputs" "$run/instructions"
	rm -f "$run/brief.pending" "$run/brief.sent" "$run/brief-message.txt" "$run/judgement.json" "$run/judgement.draft.json"
	mkdir -p "$run/inputs" "$run/instructions"

	files_json="$(printf '%s\n' "${files[@]}" | jq -R . | jq -cs .)"
	ctx="$(jq -c --argjson files "$files_json" '. + {files: $files}' <<< "$pass_ctx")"
	desk_seed_inputs "$(desk_input_files_json "$brief" "$files_json")" "$run/inputs" "$ctx"
	desk_pass_allowed_urls "$pass_config" "$config" | sed '/^$/d' | sort -u > "$run/allowed-urls.txt"

	local ph rel src
	local -a rendered=()
	ph="$(jq -c --arg run "$run" --arg pass "$pass" --arg date "$scheduled_date" \
		'. + {run_dir: $run, inputs: ($run + "/inputs"), pass: $pass, scheduled_date: $date}' <<< "$placeholders")"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		src="$(desk_prompt_path "$rel")"
		if [ ! -f "$src" ]; then
			desk_log "$pass" "brief: instruction file not found ($src) — left out"
			continue
		fi
		desk_render_prompt "$src" "$ph" > "$run/instructions/$(basename "$src")"
		rendered+=("$run/instructions/$(basename "$src")")
	done < <(jq -r '(.instructions // [])[] | strings' <<< "$brief")
	if [ "${#rendered[@]}" -eq 0 ]; then
		desk_log "$pass" "brief: no instruction file to judge by — nothing prepared"
		return 1
	fi

	desk_follow_up_run_status "$pass" > "$run/run-status.txt"
	desk_status_read | jq --arg p "$pass" --arg d "$scheduled_date" \
		--argjson instructions "$(printf '%s\n' "${rendered[@]}" | jq -R . | jq -cs .)" '
		(.passes[$p] // {}) as $s
		| {pass: $p, scheduled_date: $d, result: ($s.result // "unknown"),
		   stopped_at: ($s.stopped_at // null), failed: ($s.failed_sources // []),
		   instructions: $instructions}' > "$run/run.json"

	# What the pass staged itself (captures, retention warnings), and what
	# it held back over the caps, so the brief can say so.
	local open capped='[]'
	open="$(desk_nvim_cli proposal-open "$repo" 2> /dev/null)"
	jq -e '.items | type == "array"' > /dev/null 2>&1 <<< "$open" || open='{"items":[]}'
	if [ -n "${PASS_SCRATCH:-}" ] && [ -s "$PASS_SCRATCH/capped.json" ]; then
		capped="$(cat "$PASS_SCRATCH/capped.json")"
		jq -e 'type == "array"' > /dev/null 2>&1 <<< "$capped" || capped='[]'
	fi
	jq --arg prefix "$pass-$scheduled_date-" --argjson capped "$capped" '
		{staged: [.items[] | select(.id | startswith($prefix))
		          | {file, kind, headline, tier, source, before, after, capture_kind}
		          | with_entries(select(.value != null and .value != ""))],
		 held_back: $capped}' <<< "$open" > "$run/staged.json"
	if [ -n "${PASS_SCRATCH:-}" ] && [ -s "$PASS_SCRATCH/mail-noise.json" ]; then
		cp -f "$PASS_SCRATCH/mail-noise.json" "$run/mail-noise.json"
	fi

	printf '%s\n' '{"unconfirmed_sends": 0}' > "$run/brief.pending"
	printf '%s' "$run"
}

# desk_brief_message <pass> <run dir>...: the one message for these runs,
# oldest first. It names each run directory, how the run ended, the
# instruction files to judge it by, and what the directory holds; the
# instruction files say what to do with each part.
desk_brief_message() {
	local pass="$1"
	shift
	local -a runs=("$@")
	local dates="" r
	for r in "${runs[@]}"; do
		dates="${dates:+$dates, }$(jq -r '.scheduled_date' "$r/run.json" 2> /dev/null)"
	done
	if [ "${#runs[@]}" -eq 1 ]; then
		printf '%s The %s pass of %s is ready for you to judge. Not from the user.\n' "$DESK_BRIEF_MARKER" "$pass" "$dates"
	else
		printf '%s %s %s passes are ready for you to judge, oldest first: %s. The earlier ones could not be delivered when they ran. Not from the user.\n' \
			"$DESK_BRIEF_MARKER" "${#runs[@]}" "$pass" "$dates"
	fi
	local instr inputs close_line
	for r in "${runs[@]}"; do
		instr="$(jq -r '(.instructions // []) | join(", then ")' "$r/run.json" 2> /dev/null)"
		inputs="$(for f in "$r/inputs"/*; do [ -f "$f" ] && basename "$f"; done | paste -sd ',' - | sed 's/,/, /g')"
		close_line=""
		if [ -f "$r/close/candidates.json" ]; then
			close_line="$(jq -r '
				if length == 0 then "- close/: no idle session to offer for closing."
				else "- close/: \(length) idle session\(if length == 1 then "" else "s" end) to offer for closing, each in close/<session id>/ with session.json and transcript.txt: "
					+ ([.[] | "\(.name) (\(.idle_working_days) working days idle\(if .followed then ", followed" else "" end))"] | join(", ")) + "."
				end' "$r/close/candidates.json" 2> /dev/null)"
		fi
		printf '\nRun directory: %s\n' "$r"
		jq -r '"- How it went: " + (
			if .result == "ok" then "finished ok."
			elif .result == "partial" then "finished partial; these steps failed: \(.failed | join(", "))."
			elif .result == "failed" then "failed at step \(.stopped_at // "unknown"), so the steps after it did not run."
			else "its result was not recorded." end) + " run-status.txt has the whole account."' "$r/run.json" 2> /dev/null
		printf -- '- Judge it by: %s\n' "${instr:-(no instruction file was written)}"
		printf -- '- inputs/: %s\n' "${inputs:-(nothing was seeded)}"
		[ -z "$close_line" ] || printf '%s\n' "$close_line"
		printf -- '- Also there: allowed-urls.txt, staged.json%s.\n' "$([ -f "$r/mail-noise.json" ] && printf ', mail-noise.json')"
	done
}

# desk_brief_pending_runs <pass>: every run directory of the pass still
# waiting to be delivered, oldest first (the names end in the date).
desk_brief_pending_runs() {
	local f
	for f in "$DESK_RUNS_ROOT/$1"-*/brief.pending; do
		[ -f "$f" ] && dirname "$f"
	done | sort
}

# desk_brief_deliver <pass> <brief json> <config>: sends every pending run of
# the pass in one message, as described at the top of this file.
desk_brief_deliver() {
	local pass="$1" brief="$2" config="$3"
	local -a runs=()
	mapfile -t runs < <(desk_brief_pending_runs "$pass")
	[ "${#runs[@]}" -gt 0 ] || return 0
	local newest="${runs[${#runs[@]} - 1]}" msg dates
	msg="$newest/brief-message.txt"
	desk_brief_message "$pass" "${runs[@]}" > "$msg"
	dates="$(for r in "${runs[@]}"; do basename "$r"; done | paste -sd ',' - | sed 's/,/, /g')"

	local central name
	central="$(jq -r '.central_session // empty' <<< "$config")"
	if [ -z "$central" ]; then
		desk_log "$pass" "brief: no central_session in the config — $dates waits, its message in $msg"
		return 0
	fi
	if ! name="$(desk_follow_address "$central")"; then
		if [ "$name" = "not running" ]; then
			desk_log "$pass" "brief: the central session is not running — $dates waits for the next run of this pass"
		elif [ "$name" = "unnamed" ]; then
			desk_log "$pass" "brief: the central session is running but has no name to send to — $dates waits for the first run of this pass after it is named"
		else
			desk_log "$pass" "brief: the name '${name#ambiguous }' does not address the central session alone — $dates waits for the next run of this pass"
		fi
		return 0
	fi

	local work result verdict detail tries
	work="$(desk_scratch_dir "$pass-brief")"
	result="$(DESK_FOLLOW_COSTS="${PASS_SCRATCH:+$PASS_SCRATCH/.costs.log}" \
		desk_follow_send "$pass" "$(jq -c '.send // {}' <<< "$brief")" "$name" "$msg" "$work")"
	rm -rf "$work"
	verdict="${result%%$'\t'*}"
	detail="${result#*$'\t'}"
	tries="$(for r in "${runs[@]}"; do jq -r '.unconfirmed_sends // 0' "$r/brief.pending" 2> /dev/null; done | sort -n | tail -n1)"
	tries="${tries:-0}"
	mark_sent() { # confirmed
		local r
		for r in "${runs[@]}"; do
			jq -cn --argjson at "$(desk_now)" --arg to "$name" --argjson c "$1" '{at: $at, to: $to, confirmed: $c}' > "$r/brief.sent"
			rm -f "$r/brief.pending"
		done
	}
	if [ "$verdict" = "confirmed" ]; then
		mark_sent true
		desk_log "$pass" "brief: sent $dates to $name"
	elif [ "$verdict" = "unconfirmed" ] && [ $((tries + 1)) -ge "$DESK_FOLLOW_MAX_UNCONFIRMED" ]; then
		mark_sent false
		desk_log "$pass" "brief: the send of $dates to $name ran but was not confirmed, $DESK_FOLLOW_MAX_UNCONFIRMED times — treating it as sent, not sending it again (result: $detail)"
	elif [ "$verdict" = "unconfirmed" ]; then
		local r
		for r in "${runs[@]}"; do
			jq -cn --argjson n "$((tries + 1))" '{unconfirmed_sends: $n}' > "$r/brief.pending"
		done
		desk_log "$pass" "brief: the send of $dates to $name ran but was not confirmed — the next run of this pass tries once more (result: $detail)"
	else
		desk_log "$pass" "brief: the send of $dates to $name failed — it waits for the next run of this pass (result: $detail)"
	fi
	return 0
}

# desk_brief_after_pass <pass> <pass_config> <config> <repo> <scheduled_date>
#   <pass_ctx json> <placeholders json> <file>...
# What desk-run does once the pass is done, whatever its result: prepares
# this run's brief, except for a weekend slot of a weekdays-only pass,
# whose model steps did not run, and delivers what is pending.
desk_brief_after_pass() {
	local pass="$1" pass_config="$2" config="$3" repo="$4" scheduled_date="$5" pass_ctx="$6" placeholders="$7"
	shift 7
	local brief
	brief="$(desk_brief_config "$pass_config")"
	[ -n "$brief" ] || return 0
	if [ "${DESK_PASS_WEEKEND_SKIP:-false}" = "true" ]; then
		desk_log "$pass" "brief: weekend slot — no brief of its own"
	else
		desk_brief_prepare "$pass" "$brief" "$config" "$pass_config" "$repo" "$scheduled_date" \
			"$pass_ctx" "$placeholders" "$@" > /dev/null
	fi
	desk_brief_deliver "$pass" "$brief" "$config"
}

# desk_brief_retry <pass> <pass_config> <config>: what a later run of a
# date that already ran does: delivers what is pending, with a deny hook of
# its own, since such a run sets up no pass scratch.
desk_brief_retry() {
	local pass="$1" pass_config="$2" config="$3" brief work
	brief="$(desk_brief_config "$pass_config")"
	[ -n "$brief" ] || return 0
	[ -n "$(desk_brief_pending_runs "$pass")" ] || return 0
	work="$(desk_scratch_dir "$pass-brief-retry")"
	if ! cp "$DESK_LIB_DIR/deny-unlisted-tool.sh" "$work/deny-unlisted-tool.sh" 2> /dev/null; then
		desk_log "$pass" "brief: couldn't copy the deny hook — not sending"
		rm -rf "$work"
		return 0
	fi
	DESK_DENY_HOOK_SCRIPT="$work/deny-unlisted-tool.sh" desk_brief_deliver "$pass" "$brief" "$config"
	rm -rf "$work"
}
