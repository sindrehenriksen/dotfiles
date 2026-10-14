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
# noise in mail-noise.json, and beside them the close step's close/ and the
# retention step's retention/. Then it
# marks the run `brief.pending` and delivers.
#
# Delivery is the follow pass's: the address check (desk_follow_address) and
# the one restricted, pinned SendMessage call (desk_follow_send). A brief
# that cannot go (the central session not running, its name not addressing
# it alone, or the send failing) stays pending, and every later run of any
# pass with a brief tries again, a later slot the same day included, so a
# pass that runs once a week does not hold a missed brief a week. Each
# pass's pending runs go as one message of their own, oldest first. A send
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
	rm -f "$run/brief.pending" "$run/brief.sent" "$run/brief-message.txt" "$run/judgement.json" "$run/judgement.draft.json" "$run/notes-diff.md"
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
	local head
	head="$(git -C "$repo" rev-parse -q --verify HEAD 2> /dev/null)"
	desk_status_read | jq --arg p "$pass" --arg d "$scheduled_date" --arg head "$head" \
		--argjson instructions "$(printf '%s\n' "${rendered[@]}" | jq -R . | jq -cs .)" '
		(.passes[$p] // {}) as $s
		| {pass: $p, scheduled_date: $d, result: ($s.result // "unknown"),
		   stopped_at: ($s.stopped_at // null), failed: ($s.failed_sources // []),
		   instructions: $instructions, notes_head: $head}' > "$run/run.json"

	# What the pass staged itself (a capture step's lines), and what it
	# held back over the caps, so the brief can say so.
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

	desk_brief_notes_changes "$pass" "$run" "$repo" "$head" "${files[@]}"
	desk_brief_gone_edits "$run" "$repo" "${files[@]}"
	# The user's own notes changes since a weekday and time, as an open_tab
	# step writes them (desk_write_notes_diff), for a brief whose
	# instructions want them.
	local since_kind
	since_kind="$(jq -c '.notes_diff_since // empty' <<< "$brief" | sed -E 's/^"(.*)"$/\1/')"
	[ -z "$since_kind" ] || desk_write_notes_diff "$repo" "$run/notes-diff.md" "$since_kind" "${files[@]}"

	printf '%s\n' '{"unconfirmed_sends": 0}' > "$run/brief.pending"
	printf '%s' "$run"
}

_desk_brief_mtime() { # file: its mtime, 0 when it is missing
	local m
	if [ -r /proc/stat ]; then m="$(stat -c %Y "$1" 2> /dev/null)"; else m="$(stat -f %m "$1" 2> /dev/null)"; fi
	printf '%s' "${m:-0}"
}

# desk_brief_notes_changes <pass> <run dir> <repo> <head> <file>...
# notes-changes.txt: the notes repo's own commits to the configured files
# since the last judged brief, `git log -p` from the HEAD that run recorded
# to <head>, so the central session can update its picture and check that
# nothing broke or got lost. The last judged brief is the latest run of any
# pass, by its date, whose directory holds judgement.json; a judgement of
# one pass covers the notes for all of them. When no kept run was judged,
# the oldest kept run stands in, and the file says what that misses. When
# that commit is no longer an ancestor of <head> (the history was
# rewritten), the file says so and holds the whole diff from it instead, so
# a lost line shows. With no run kept, a run that recorded no commit, or
# its commit gone, the file says which.
# _desk_brief_base_run <run dir>: what this run's brief compares against,
# as "<judged: true|false><tab><dir>": the latest judged run of any pass by
# date (a later judgement breaking a tie within a date), else the oldest
# kept run; nothing when no other run is kept.
_desk_brief_base_run() {
	local run="$1" date r i
	date="$(basename "$run")"
	date="${date: -10}"
	# Each run directory as "<date> <judgement mtime> <dir>", so a later
	# judgement breaks a tie between two passes of one date.
	local -a kept=()
	mapfile -t kept < <(for r in "$DESK_RUNS_ROOT"/*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
		[ -d "$r" ] && [ "$r" != "$run" ] && [ -f "$r/run.json" ] || continue
		[[ "${r: -10}" > "$date" ]] && continue
		printf '%s %s %s\n' "${r: -10}" "$(_desk_brief_mtime "$r/judgement.json")" "$r"
	done | sort -k1,1 -k2,2n)
	for ((i = ${#kept[@]} - 1; i >= 0; i--)); do
		r="${kept[$i]#* * }"
		[ -f "$r/judgement.json" ] || continue
		printf 'true\t%s\n' "$r"
		return 0
	done
	[ "${#kept[@]}" -eq 0 ] || printf 'false\t%s\n' "${kept[0]#* * }"
}

desk_brief_notes_changes() {
	local pass="$1" run="$2" repo="$3" head="$4"
	shift 4
	local out="$run/notes-changes.txt" base="" from="" judged=true found
	found="$(_desk_brief_base_run "$run")"
	if [ -n "$found" ]; then
		judged="${found%%$'\t'*}"
		from="${found#*$'\t'}"
	fi
	[ -z "$from" ] || base="$(jq -r '.notes_head // empty' "$from/run.json" 2> /dev/null)"
	local name="${from##*/}"
	if [ -z "$from" ]; then
		printf 'No earlier brief run is kept, so there is nothing to compare the notes against.\n' > "$out"
		return 0
	fi
	if [ -z "$base" ]; then
		if [ "$judged" = true ]; then
			printf 'The last judged brief, %s, recorded no notes commit, so there is nothing to compare against.\n' "$name" > "$out"
		else
			printf 'No kept brief run was judged, and the oldest kept, %s, recorded no notes commit, so there is nothing to compare against.\n' "$name" > "$out"
		fi
		return 0
	fi
	if ! git -C "$repo" cat-file -e "$base^{commit}" 2> /dev/null; then
		printf 'The notes commit %s recorded, %s, is no longer in the repo, so there is nothing to compare against.\n' "$name" "${base:0:12}" > "$out"
		return 0
	fi
	: > "$out"
	[ "$judged" = true ] || printf 'No kept brief run was judged, so this goes back only to the oldest kept, %s (%s); changes before it are not here.\n\n' \
		"$name" "${base:0:12}" >> "$out"
	if [ "$base" = "$head" ]; then
		printf 'The notes have no new commits since %s (%s).\n' "$name" "${base:0:12}" >> "$out"
	elif ! git -C "$repo" merge-base --is-ancestor "$base" "$head" 2> /dev/null; then
		printf 'The notes history was rewritten since %s: its commit %s is no longer an ancestor of HEAD. The whole difference from it follows, so a lost line shows as removed.\n\n' \
			"$name" "${base:0:12}" >> "$out"
		git -C "$repo" diff --no-color "$base" "$head" -- "$@" >> "$out" 2> /dev/null \
			|| printf 'The diff from %s could not be read.\n' "${base:0:12}" >> "$out"
	else
		git -C "$repo" log -p --no-color --format='commit %H%nDate: %ad%n%n    %s%n' --date=iso "$base..$head" -- "$@" >> "$out" 2> /dev/null \
			|| printf 'The notes log since %s could not be read.\n' "${base:0:12}" >> "$out"
	fi
}

# desk_brief_gone_edits <run dir> <repo> <file>...
# gone-edits.json: the edits the notes review settled as declined because
# the lines they change were gone from the notes (nvim/lua/desk/proposal.lua),
# since this brief's base run was judged (or, with no judged run kept, since
# the oldest kept run), each with its proposed text from the ledger, for the
# central session to offer again. Still declined only: one restored since is
# left out. Not written when there are none.
desk_brief_gone_edits() {
	local run="$1" repo="$2"
	shift 2
	local found since=0 files_json ledger
	rm -f "$run/gone-edits.json"
	found="$(_desk_brief_base_run "$run")"
	if [ -n "$found" ]; then
		if [ "${found%%$'\t'*}" = true ]; then
			since="$(_desk_brief_mtime "${found#*$'\t'}/judgement.json")"
		else
			since="$(_desk_brief_mtime "${found#*$'\t'}/run.json")"
		fi
	fi
	ledger="$(git -C "$repo" cat-file -p refs/desk/ledger 2> /dev/null)" || return 0
	files_json="$(printf '%s\n' "$@" | jq -R . | jq -cs .)"
	jq -Rn --argjson since "$since" --argjson files "$files_json" '
		[inputs | (try fromjson catch null) | objects
		 | select(.id and (.type == "decline" or .type == "restore" or .type == "restore_applied"))]
		| group_by(.id) | map(last)
		| [.[] | select(.type == "decline" and .settled == true
		               and .reason == "the lines it changes are no longer in your notes"
		               and (.at // 0) >= $since and (.item | type) == "object"
		               and (.item.file as $f | $files | index($f)))
		   | .item | {id, file, kind, headline, source, before, after}
		   | with_entries(select(.value != null))]
		| sort_by(.id)' <<< "$ledger" > "$run/gone-edits.json" 2> /dev/null || rm -f "$run/gone-edits.json"
	jq -e 'length > 0' > /dev/null 2>&1 "$run/gone-edits.json" || rm -f "$run/gone-edits.json"
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
	local instr inputs close_line retention_line
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
		retention_line=""
		if [ -f "$r/retention/candidates.json" ] && [ "$(jq 'length' "$r/retention/candidates.json" 2> /dev/null)" != "0" ]; then
			retention_line="$(jq -r '"- retention/: \(length) session\(if length == 1 then "" else "s" end) the notes name whose transcripts Claude Code deletes soon, each in retention/<session id>/ with session.json and transcript.txt: "
				+ ([.[] | "\(.name) (deleted \(.deletion_date))"] | join(", ")) + "."' "$r/retention/candidates.json" 2> /dev/null)"
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
		[ -z "$retention_line" ] || printf '%s\n' "$retention_line"
		# staged.json only when the pass staged or held back anything itself.
		printf -- '- Also there: notes-changes.txt (the notes'"'"' own commits since the last judged brief), allowed-urls.txt%s%s.\n' \
			"$(jq -e '((.staged // []) + (.held_back // [])) | length > 0' "$r/staged.json" > /dev/null 2>&1 && printf ', staged.json')" \
			"$([ -f "$r/mail-noise.json" ] && printf ', mail-noise.json')$([ -f "$r/notes-diff.md" ] && printf ', notes-diff.md')$([ -f "$r/gone-edits.json" ] && printf ', gone-edits.json')"
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
			desk_log "$pass" "brief: the central session is not running — $dates waits for the next run of a pass with a brief"
		elif [ "$name" = "unnamed" ]; then
			desk_log "$pass" "brief: the central session is running but has no name to send to — $dates waits for the first run of a pass with a brief after it is named, a later slot or a run by hand"
		else
			desk_log "$pass" "brief: the name '${name#ambiguous }' does not address the central session alone — $dates waits for the next run of a pass with a brief"
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
		desk_log "$pass" "brief: the send of $dates to $name ran but was not confirmed — the next run of a pass with a brief tries once more (result: $detail)"
	else
		desk_log "$pass" "brief: the send of $dates to $name failed — it waits for the next run of a pass with a brief (result: $detail)"
	fi
	return 0
}

# desk_brief_deliver_all <pass> <brief json> <config>: the pass's own
# pending runs, then every other pass's with a brief, each its own message.
desk_brief_deliver_all() {
	local pass="$1" brief="$2" config="$3" p
	desk_brief_deliver "$pass" "$brief" "$config"
	local -a others=()
	mapfile -t others < <(desk_brief_passes "$config" | grep -vxF -- "$pass")
	for p in "${others[@]}"; do
		desk_brief_deliver "$p" "$(jq -c --arg p "$p" '.passes[$p].brief' <<< "$config")" "$config"
	done
}

# desk_brief_passes <config>: the name of every pass with a brief.
desk_brief_passes() {
	jq -r '(.passes // {}) | to_entries[] | select((.value.brief | type) == "object") | .key' <<< "$1"
}

# desk_brief_after_pass <pass> <pass_config> <config> <repo> <scheduled_date>
#   <pass_ctx json> <placeholders json> <file>...
# What desk-run does once the pass is done, whatever its result: prepares
# this run's brief, except for a weekend slot of a weekdays-only pass,
# whose model steps did not run, and delivers what is pending, its own and
# every other pass's.
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
	desk_brief_deliver_all "$pass" "$brief" "$config"
}

# desk_brief_retry <pass> <pass_config> <config>: what a later run of a
# date that already ran does: delivers what is pending, its own and every
# other pass's, with a deny hook of its own, since such a run sets up no
# pass scratch.
desk_brief_retry() {
	local pass="$1" pass_config="$2" config="$3" brief work p pending=""
	brief="$(desk_brief_config "$pass_config")"
	[ -n "$brief" ] || return 0
	while IFS= read -r p; do
		[ -n "$(desk_brief_pending_runs "$p")" ] && pending=1
	done < <(desk_brief_passes "$config")
	[ -n "$pending" ] || return 0
	work="$(desk_scratch_dir "$pass-brief-retry")"
	if ! cp "$DESK_LIB_DIR/deny-unlisted-tool.sh" "$work/deny-unlisted-tool.sh" 2> /dev/null; then
		desk_log "$pass" "brief: couldn't copy the deny hook — not sending"
		rm -rf "$work"
		return 0
	fi
	DESK_DENY_HOOK_SCRIPT="$work/deny-unlisted-tool.sh" desk_brief_deliver_all "$pass" "$brief" "$config"
	rm -rf "$work"
}
