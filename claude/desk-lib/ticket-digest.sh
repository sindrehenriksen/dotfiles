#!/usr/bin/env bash
# The ticket digest (docs/desk.md, "The ticket digest"): a fetch step with
# a `ticket_digest` key also runs one ticket query the runner builds, and
# the runner, not the model, reads its raw results and the configured
# repos' pull requests, compares them with its own snapshots by the follow
# pass's rules (follow-diff.jq in ticket_digest mode), leaves out whatever
# a followed session already covers, and hands the judge what is left as
# ticket-digest.json, grouped per ticket and per PR and capped.
#
# Files, all in $PASS_SCRATCH and named after the step, so the same-day
# fetch cache carries them to a retry slot:
#   <id>-ticket-digest-window.jsonl   {since, now, jql}, fixed when the call is made
#   <id>-ticket-digest-issues.jsonl   the normalized tickets
#   <id>-ticket-digest-prs.jsonl      the normalized pull requests
# and, once built, ticket-digest.json (the judge's input) and
# ticket-digest-state.json (the new snapshots, installed into
# $DESK_TICKET_DIGEST_STATE_FILE only when the pass's fetch window moves).
#
# The follow list and follow state are only ever read here.
set -u

# shellcheck source=follow.sh
source "$DESK_LIB_DIR/follow.sh"

DESK_TICKET_DIGEST_STATE_FILE="${DESK_TICKET_DIGEST_STATE_FILE:-$DESK_STATE_DIR/ticket-digest-state.json}"

# desk_ticket_digest_config <step_json> <config_json>: the step's
# `ticket_digest` with its defaults filled in, or nothing when it has none.
# The bot rules and repos default to the follow pass's, and the step's own
# bot rules are added to those.
desk_ticket_digest_config() {
	jq -c --argjson c "$2" '
		.ticket_digest // empty
		| ([($c.passes // {})[] | select(.kind == "follow")] | first // {}) as $f
		| { jql: (.jql // null),
		    github_repos: (.github_repos // $f.github_repos // []),
		    skip: { bot_authors: (($f.skip.bot_authors // []) + (.skip.bot_authors // [])),
		            bot_signatures: (($f.skip.bot_signatures // []) + (.skip.bot_signatures // [])) },
		    self: (.self // []),
		    pr_skip_authors: (.pr_skip_authors // []),
		    pr_keep: (.pr_keep // null),
		    max_window_days: (.max_window_days // 4),
		    max_entries: (.max_entries // 25),
		    max_changes: (.max_changes // 6),
		    pr_limit: (.pr_limit // 200) }' <<< "$1" 2> /dev/null
}

# desk_ticket_digest_window <id> <cfg> <window_start epoch> <now epoch>
# Fixes this call's window and query and writes them beside its other
# files; prints the placeholders the prompt gets. The window starts at the
# pass's own, five minutes early, but never more than max_window_days back:
# a search result past the output limit reaches the runner only as a saved
# file, so the call cannot page past its first 100 tickets, and a window
# held open by a long absence must not grow until it never comes back.
desk_ticket_digest_window() {
	local id="$1" cfg="$2" start="$3" now="$4" floor since minutes jql
	floor=$((now - $(jq -r '.max_window_days' <<< "$cfg") * 86400))
	since=$((start - 300))
	[ "$since" -lt "$floor" ] && since="$floor"
	minutes=$(((now - since + 59) / 60))
	jql="($(jq -r '.jql' <<< "$cfg")) AND updated >= -${minutes}m"
	jq -cn --argjson since "$since" --argjson now "$now" --arg jql "$jql" '{since: $since, now: $now, jql: $jql}' \
		> "$PASS_SCRATCH/$id-ticket-digest-window.jsonl"
	jq -cn --arg jql "$jql" --arg f "$(jq -r 'join(", ")' <<< "$DESK_FOLLOW_CHANGE_FIELDS")" \
		'{ticket_digest_jql: $jql, ticket_digest_fields: $f}'
}

# desk_ticket_digest_collect <pass> <id> <cfg> <tool>
# After the call: the tickets from the results of the calls whose jql is
# exactly the one built (a saved oversized result read back from the
# call's spill directory), then the pull requests through gh. Non-zero
# when either did not come back, which fails the step.
desk_ticket_digest_collect() {
	local pass="$1" id="$2" cfg="$3" tool="$4" window jql since issues state
	window="$(cat "$PASS_SCRATCH/$id-ticket-digest-window.jsonl" 2> /dev/null)"
	jql="$(jq -r '.jql // empty' <<< "$window" 2> /dev/null)"
	since="$(jq -r '.since // empty' <<< "$window" 2> /dev/null)"
	[ -n "$jql" ] && [ -n "$since" ] || { desk_log "$pass" "$id: ticket digest: no window recorded"; return 1; }
	_desk_follow_resolve_spills "$PASS_SCRATCH/$id-tool-results.jsonl" "$PASS_SCRATCH/$id-spill" \
		> "$PASS_SCRATCH/$id-ticket-digest-results.json" 2> /dev/null
	issues="$(_desk_follow_issues_for "$PASS_SCRATCH/$id-tool-uses.jsonl" "$PASS_SCRATCH/$id-ticket-digest-results.json" "$jql" "$tool")"
	rm -f "$PASS_SCRATCH/$id-ticket-digest-results.json"
	if [ -z "$issues" ] || [ "$issues" = "null" ]; then
		desk_log "$pass" "$id: ticket digest: the ticket query did not come back whole"
		return 1
	fi
	printf '%s\n' "$issues" > "$PASS_SCRATCH/$id-ticket-digest-issues.jsonl"
	state="$(cat "$DESK_TICKET_DIGEST_STATE_FILE" 2> /dev/null)"
	jq -e 'type == "object"' > /dev/null 2>&1 <<< "$state" || state='{}'
	local limit
	limit="$(jq -r '.pr_limit' <<< "$cfg")"
	if ! desk_follow_fetch_prs "$pass" "$cfg" "$state" null "$since" true "$PASS_SCRATCH/$id-ticket-digest-prs.jsonl" "$limit"; then
		desk_log "$pass" "$id: ticket digest: the pull request listing failed"
		return 1
	fi
	jq -e --argjson l "$limit" 'length >= $l' > /dev/null 2>&1 "$PASS_SCRATCH/$id-ticket-digest-prs.jsonl" \
		&& desk_log "$pass" "$id: ticket digest: $limit pull requests listed, the limit; older ones in the window are not covered"
	return 0
}

# Every ticket key a followed session covers, and the tracked keys whose
# new children it covers too: {keys, parents}.
desk_ticket_digest_followed() {
	local entries fstate
	entries="$(desk_follow_entries)"
	fstate="$(cat "$DESK_FOLLOW_STATE_FILE" 2> /dev/null)"
	jq -e 'type == "object"' > /dev/null 2>&1 <<< "$fstate" || fstate='{}'
	jq -c --argjson s "$fstate" '
		. as $e
		| [$e[] | (.keys // [])[]] as $tracked
		| { keys: ([$e[] | (.keys // []) + (.related // []) | .[]]
		           + [$e | keys[] as $sid | ($s.queues[$sid].scope // [])[]]
		           + [$tracked[] as $k | ($s.scope.children[$k] // [])[]] | unique),
		    parents: ($tracked | unique) }' <<< "$entries"
}

# desk_ticket_digest_build <pass> <id> <cfg> <timezone>
# Writes ticket-digest.json and ticket-digest-state.json into
# $PASS_SCRATCH from this step's files; `{}` for the judge when they are
# missing (the step failed).
desk_ticket_digest_build() {
	local pass="$1" id="$2" cfg="$3" tz="$4" out="$PASS_SCRATCH/ticket-digest.json"
	local window_f="$PASS_SCRATCH/$id-ticket-digest-window.jsonl" issues_f="$PASS_SCRATCH/$id-ticket-digest-issues.jsonl"
	local prs_f="$PASS_SCRATCH/$id-ticket-digest-prs.jsonl"
	echo '{}' > "$out"
	if [ ! -s "$window_f" ] || [ ! -s "$issues_f" ] || [ ! -s "$prs_f" ]; then
		desk_log "$pass" "$id: ticket digest: nothing fetched, the judge gets none"
		return 1
	fi
	local state followed work
	state="$(cat "$DESK_TICKET_DIGEST_STATE_FILE" 2> /dev/null)"
	jq -e 'type == "object"' > /dev/null 2>&1 <<< "$state" || state='{}'
	followed="$(desk_ticket_digest_followed)"
	work="$(desk_scratch_dir "$pass-ticket-digest")"
	jq -n --slurpfile w "$window_f" --slurpfile i "$issues_f" --slurpfile p "$prs_f" \
		--argjson state "$state" --argjson cfg "$cfg" '
		{ ticket_digest: true, entries: {},
		  ticket_digest_rules: {self: $cfg.self, pr_skip_authors: $cfg.pr_skip_authors, pr_keep: $cfg.pr_keep},
		  state: {tickets: ($state.tickets // {}), prs: ($state.prs // {})},
		  scope_issues: null, change_issues: $i[0], prs: $p[0],
		  now: $w[0].now, jira_since: $w[0].since, gh_since: $w[0].since,
		  baseline_jira: false, baseline_gh: false, queue_max: 0,
		  skip: $cfg.skip, lookback: false }' > "$work/input.json"
	if ! jq -c -f "$DESK_FOLLOW_DIFF_JQ" "$work/input.json" > "$work/diff.json" 2> "$work/diff.err"; then
		desk_log "$pass" "$id: ticket digest: the diff failed: $(head -c 400 "$work/diff.err")"
		rm -rf "$work"
		return 1
	fi
	jq -c --slurpfile w "$window_f" '{tickets, prs, updated_at: $w[0].now}' "$work/diff.json" \
		> "$PASS_SCRATCH/ticket-digest-state.json"
	TZ="${tz:-UTC}" jq -c --slurpfile w "$window_f" --slurpfile i "$issues_f" --slurpfile p "$prs_f" \
		--argjson f "$followed" --argjson cfg "$cfg" '
		def when: strflocaltime("%Y-%m-%d %H:%M");
		($i[0] | map({(.key): .}) | add // {}) as $ti
		| ($p[0] | map({(.id): .}) | add // {}) as $pi
		| def covered_ticket($k): ($f.keys | index($k)) != null
			or (($ti[$k].parent // null) as $par | $par != null and ($f.parents | index($par)) != null);
		  def covered_pr($keys): any($keys[]; . as $k | ($f.keys | index($k)) != null);
		  ([.ticket_events[] | . + {ref: .key, covered: covered_ticket(.key)}]
		   + [.pr_events[] | . + {ref: .key, covered: covered_pr(.pr_keys // [])}]) as $ev
		| ([$ev[] | select(.covered) | .ref] | unique | length) as $n_covered
		| [$ev[] | select(.covered | not)] as $open
		| ($open | map(select(.skip != null)) | group_by(.skip) | map({(.[0].skip): length}) | add // {}) as $counted
		| [ $open | map(select(.skip == null)) | group_by(.ref)[]
		    | sort_by(.at) as $c
		    | ($c[0].ref) as $r
		    | (if $ti[$r] then
		         {kind: "ticket", key: $r, summary: $ti[$r].summary, type: $ti[$r].type, status: $ti[$r].status,
		          assignee: $ti[$r].assignee, parent: $ti[$r].parent}
		       else
		         ($pi[$r] // {}) as $pr
		         | {kind: "pr", pr: $r, title: $pr.title, url: $pr.url, state: $pr.state, draft: $pr.draft,
		            author: $pr.author, keys: $pr.keys}
		       end)
		      + {latest: ($c[-1].at // 0), has_post: any($c[]; .author != null),
		         changes: [$c[-($cfg.max_changes):][] | {at: ((.at // 0) | when), what}],
		         earlier_changes: ([($c | length) - $cfg.max_changes, 0] | max)} ]
		| sort_by([(.has_post | not), -(.latest)]) as $entries
		| { window: {since: ($w[0].since | when), until: ($w[0].now | when)},
		    entries: [$entries[:$cfg.max_entries][] | del(.latest, .has_post)
		              | if .earlier_changes == 0 then del(.earlier_changes) else . end],
		    more: [$entries[$cfg.max_entries:][] | .key // .pr],
		    counted: $counted,
		    left_to_follows: $n_covered }' "$work/diff.json" > "$out" 2> "$work/shape.err" || {
		desk_log "$pass" "$id: ticket digest: shaping the judge file failed: $(head -c 400 "$work/shape.err")"
		echo '{}' > "$out"
		rm -f "$PASS_SCRATCH/ticket-digest-state.json"
		rm -rf "$work"
		return 1
	}
	desk_log "$pass" "$id: ticket digest: $(jq -r '"\(.entries | length) for the judge, \(.more | length) over the cap, \([.counted[]] | add // 0) counted, \(.left_to_follows) left to follow sessions"' "$out")"
	rm -rf "$work"
}

# Installs the snapshots this pass built; called only once the pass's fetch
# window moves, so a pass that has to be retried compares against the same
# snapshots again.
desk_ticket_digest_commit() {
	local pending="$PASS_SCRATCH/ticket-digest-state.json"
	[ -s "$pending" ] || return 0
	desk_write_atomic "$DESK_TICKET_DIGEST_STATE_FILE" "$(cat "$pending")
"
}
