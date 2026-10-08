#!/usr/bin/env bash
# The follow pass: forwards movement on the tickets a Claude Code session
# tracks to that session, as a cross-session message. docs/desk.md, "The
# follow pass", has the whole contract; this file is its runner and the
# follow list's CLI (claude/desk-follow).
#
# Two files, both machine-local, because session ids only exist on this
# machine:
#   $DESK_FOLLOW_FILE        the follow list, edited only by the CLI:
#                           {"entries": {<session id>: {label, keys, related, added_at}}}
#   $DESK_FOLLOW_STATE_FILE  the runner's own state: snapshots, scope, the
#                           per-session queues, last runs. Written only by
#                           a non-dry run, under the follow lock.
#
# A run never touches the notes repo, the status file or the shared runner
# lock: it takes its own lock, so a morning pass never holds it up and a
# second follow run (the schedule and a manual one) waits briefly or skips.
set -u

# This pass was called the watch pass, its files watch.json and
# watch-state.json, and its overrides DESK_WATCH_FILE and
# DESK_WATCH_STATE_FILE, which still apply. A file still at its old default
# path moves to the new default the first time it is looked for, so the
# sessions already followed and their snapshots carry over.
desk_follow_default_path() { # override, older override, new default, old default
	if [ -n "$1" ]; then printf '%s\n' "$1"; return; fi
	if [ -n "$2" ]; then printf '%s\n' "$2"; return; fi
	[ -e "$3" ] || [ ! -e "$4" ] || mv -n "$4" "$3" 2> /dev/null || true
	printf '%s\n' "$3"
}
DESK_FOLLOW_FILE="$(desk_follow_default_path "${DESK_FOLLOW_FILE:-}" "${DESK_WATCH_FILE:-}" \
	"$DESK_STATE_DIR/follow.json" "$DESK_STATE_DIR/watch.json")"
DESK_FOLLOW_STATE_FILE="$(desk_follow_default_path "${DESK_FOLLOW_STATE_FILE:-}" "${DESK_WATCH_STATE_FILE:-}" \
	"$DESK_STATE_DIR/follow-state.json" "$DESK_STATE_DIR/watch-state.json")"
DESK_GH_BIN="${DESK_GH_BIN:-gh}"
DESK_FOLLOW_DIFF_JQ="$DESK_LIB_DIR/follow-diff.jq"

# The first characters of every follow message. A follow session's
# preamble names it, and a hook can tell a follow turn by it.
DESK_FOLLOW_MARKER="[desk-follow]"
# The floor on the scheduled interval, in minutes.
DESK_FOLLOW_MIN_INTERVAL=15
# How many sends that ran but went unconfirmed the same queue gets before
# its changes count as sent.
DESK_FOLLOW_MAX_UNCONFIRMED="${DESK_FOLLOW_MAX_UNCONFIRMED:-2}"

_desk_follow_reader() { "${DESK_READER:-session-status.sh}" "$@"; }

# --- the follow list ----------------------------------------------------------

desk_follow_entries() {
	local e
	e="$(jq -c '.entries // {}' "$DESK_FOLLOW_FILE" 2> /dev/null)"
	[ -n "$e" ] || e='{}'
	printf '%s\n' "$e"
}

_desk_follow_write_list() { # entries-json
	desk_write_atomic "$DESK_FOLLOW_FILE" "$(jq -n --argjson e "$1" '{entries: $e}')
"
}

# A session token (a full id, a name, or an 8+ character id prefix) to its
# session id, through the reader. A full id the reader does not know is
# still accepted, since the session may not have been recorded yet.
desk_follow_resolve_session() {
	local token="$1" hit id
	if [[ "$token" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
		printf '%s\n' "$token"
		return 0
	fi
	hit="$(_desk_follow_reader resolve "$token" 2> /dev/null)" || {
		echo "desk-follow: no single session matches '$token'" >&2
		return 1
	}
	id="$(jq -r '.id // empty' <<< "$hit" 2> /dev/null)"
	[ -n "$id" ] || { echo "desk-follow: no single session matches '$token'" >&2; return 1; }
	printf '%s\n' "$id"
}

_desk_follow_valid_key() { [[ "$1" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; }

# desk_follow_cli_add <session id> <label or ""> <keys csv> <related csv>
desk_follow_cli_add() {
	local sid="$1" label="$2" keys="$3" related="$4" k entries
	for k in ${keys//,/ } ${related//,/ }; do
		_desk_follow_valid_key "$k" || { echo "desk-follow: '$k' is not a ticket key (like ABC-123)" >&2; return 2; }
	done
	[ -n "$keys$related" ] || { echo "desk-follow: name at least one ticket key" >&2; return 2; }
	if [ -z "$label" ]; then
		label="$(_desk_follow_reader resolve "$sid" 2> /dev/null | jq -r '.name // empty' 2> /dev/null)"
		[ -n "$label" ] || label="${sid:0:8}"
	fi
	entries="$(desk_follow_entries)"
	entries="$(jq -c --arg sid "$sid" --arg label "$label" --arg keys "$keys" --arg related "$related" \
		--argjson now "$(desk_now)" '
		def csv: split(",") | map(select(. != ""));
		.[$sid] = ((.[$sid] // {added_at: $now, keys: [], related: []})
			| .label = $label
			| .keys = ((.keys + ($keys | csv)) | unique)
			| .related = ((.related + ($related | csv)) - .keys | unique))' <<< "$entries")"
	_desk_follow_write_list "$entries"
	jq -r --arg sid "$sid" '.[$sid] | "following \(.keys + .related | join(", ")) for \(.label)"' <<< "$entries"
}

# desk_follow_cli_remove <session id> [keys csv]: without keys, the whole
# follow goes; with keys, only those.
desk_follow_cli_remove() {
	local sid="$1" keys="${2:-}" entries
	entries="$(desk_follow_entries)"
	if ! jq -e --arg sid "$sid" 'has($sid)' <<< "$entries" > /dev/null; then
		echo "desk-follow: session ${sid:0:8} is not followed" >&2
		return 1
	fi
	entries="$(jq -c --arg sid "$sid" --arg keys "$keys" '
		($keys | split(",") | map(select(. != ""))) as $drop
		| if ($drop | length) == 0 then del(.[$sid])
		  else .[$sid].keys -= $drop | .[$sid].related -= $drop
		  | if ((.[$sid].keys + .[$sid].related) | length) == 0 then del(.[$sid]) else . end
		  end' <<< "$entries")"
	_desk_follow_write_list "$entries"
	if jq -e --arg sid "$sid" 'has($sid)' <<< "$entries" > /dev/null; then
		jq -r --arg sid "$sid" '.[$sid] | "still following \(.keys + .related | join(", ")) for \(.label)"' <<< "$entries"
	else
		echo "stopped following for session ${sid:0:8}"
	fi
}

# desk_follow_cli_list [--json]: every follow, with the session's current
# name and liveness, what waits in its queue, and when it last got an update.
desk_follow_cli_list() {
	local as_json="${1:-}" entries state sessions
	entries="$(desk_follow_entries)"
	state="$(cat "$DESK_FOLLOW_STATE_FILE" 2> /dev/null)"
	jq -e . > /dev/null 2>&1 <<< "$state" || state='{}'
	sessions="$(_desk_follow_reader 2> /dev/null | jq -cs 'map({(.id): {name, live}}) | add // {}' 2> /dev/null)"
	[ -n "$sessions" ] || sessions='{}'
	local listed
	listed="$(jq -c --argjson s "$state" --argjson live "$sessions" '
		[to_entries[] | .key as $sid | .value
		 | . + {session_id: $sid,
		        name: ($live[$sid].name // null), live: ($live[$sid].live // false),
		        queued: (($s.queues[$sid].changes // []) | length),
		        queued_since: ($s.queues[$sid].queued_since // null),
		        last_sent: ($s.last_sent[$sid] // null),
		        all_closed_since: ($s.all_closed[$sid] // null)}]' <<< "$entries")"
	if [ "$as_json" = "--json" ]; then
		printf '%s\n' "$listed"
		return 0
	fi
	jq -r '
		if length == 0 then "nothing is followed"
		else .[] | "\(.label)  (\(.session_id[0:8]), \(if .live then "live" else "not running" end)\(if .name and .name != .label then ", now named " + .name else "" end))\n"
			+ "  tracks: \(.keys | join(", "))\(if (.related | length) > 0 then "; related: " + (.related | join(", ")) else "" end)\n"
			+ "  queued: \(.queued)\(if .queued_since then " since " + (.queued_since | strflocaltime("%a %d %b %H:%M")) else "" end)"
			+ "; last update sent: \(if .last_sent then (.last_sent.at | strflocaltime("%a %d %b %H:%M")) else "never" end)"
			+ (if .all_closed_since then "\n  everything it tracks is closed (since \(.all_closed_since | strflocaltime("%d %b"))): retire it?" else "" end)
		end' <<< "$listed"
}

# --- config ------------------------------------------------------------------

# The scheduled interval in minutes: the pass's `interval_minutes`, default
# and floor 15.
desk_follow_interval_minutes() {
	local pass_config="$1" pass="${2:-follow}" v
	v="$(jq -r '.interval_minutes // empty' <<< "$pass_config")"
	[ -n "$v" ] || v="$DESK_FOLLOW_MIN_INTERVAL"
	if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt "$DESK_FOLLOW_MIN_INTERVAL" ]; then
		desk_log "$pass" "interval_minutes $v is under the ${DESK_FOLLOW_MIN_INTERVAL}-minute floor; using $DESK_FOLLOW_MIN_INTERVAL"
		v="$DESK_FOLLOW_MIN_INTERVAL"
	fi
	printf '%s\n' "$v"
}

# --- fetching ------------------------------------------------------------------

DESK_FOLLOW_SCOPE_FIELDS='["summary","status","issuetype","parent","issuelinks","assignee","labels","resolution","updated","created"]'
DESK_FOLLOW_CHANGE_FIELDS='["summary","status","issuetype","parent","issuelinks","assignee","labels","resolution","updated","created","comment","description"]'

# One Jira search result issue to the shape follow-diff.jq reads.
_DESK_FOLLOW_NORM_ISSUE='
	def str: if . == null then null elif type == "string" then . else tojson end;
	def link_of($l): ($l.outwardIssue // $l.inwardIssue) as $o
		| if $o == null then empty
		  else {key: $o.key, rel: (if $l.outwardIssue then $l.type.outward else $l.type.inward end // "relates to"),
		        summary: ($o.fields.summary // null), status: ($o.fields.status.name // null),
		        done: (($o.fields.status.statusCategory.key // "") == "done")} end;
	(.fields // .) as $f
	| { key: .key,
	    summary: ($f.summary // ""),
	    status: ($f.status.name // $f.status // ""),
	    done: (($f.status.statusCategory.key // "") == "done"),
	    type: ($f.issuetype.name // null),
	    assignee: ($f.assignee.displayName // null),
	    parent: ($f.parent.key // null),
	    resolution: ($f.resolution.name // null),
	    labels: (($f.labels // []) | sort),
	    links: [($f.issuelinks // [])[] as $l | link_of($l)],
	    updated: ($f.updated // null), created: ($f.created // null),
	    has_desc: ($f | has("description")), desc: ($f.description | str),
	    has_comments: ($f.comment != null),
	    comments: [($f.comment.comments // [])[]
	        | {id: (.id | tostring), author: (.author.displayName // "someone"),
	           created, updated, body: (.body | str // "")}] }
	| select(.key != null)'

# Every issue in the results of the calls whose jql is exactly $3, as one
# JSON array, or "null" when no such call returned anything parseable.
_desk_follow_issues_for() { # tool-uses tool-results jql tool
	local pairs
	pairs="$(desk_tool_call_pairs "$1" "$2" "$4")"
	jq -c --arg q "$3" "
		[.[] | select(.input.jql == \$q) | .text | (try fromjson catch null) | select(. != null)
		 | (if (.issues | type) == \"array\" then .issues
		    elif (.issues.nodes | type) == \"array\" then .issues.nodes else null end)] as \$pages
		| ([.[] | select(.input.jql == \$q) | .text | (try fromjson catch null) | select(. != null)] | last) as \$tail
		# A last page that says more follow: the fetch stopped short.
		| ((\$tail.issues | objects | .pageInfo) // {}) as \$info
		| (\$tail != null and ((\$tail.nextPageToken // \$info.endCursor // null) != null
			and (\$tail.isLast != true) and (\$info.hasNextPage // true) != false)) as \$short
		| if (\$pages | length) == 0 or any(\$pages[]; . == null) or \$short then null
		  else [\$pages[][] | $_DESK_FOLLOW_NORM_ISSUE] | unique_by(.key) end" <<< "$pairs" 2> /dev/null
}

_desk_follow_jql_keys() { jq -r 'join(", ")' <<< "$1"; }

# A tool result past Claude Code's output limit arrives as a pointer ("...
# Output has been saved to <path>"); the call's --spill-dir copied the
# file out. Rewrites each such result's content to the saved text (a
# content-block array is joined), leaving every other result as it was.
_desk_follow_resolve_spills() { # results.jsonl spill-dir
	local line text file saved
	while IFS= read -r line; do
		text="$(jq -r "$_DESK_JQ_RESULT_TEXT" <<< "$line" 2> /dev/null)"
		file="$(grep -oE 'saved to [^ ]+' <<< "$text" | head -n1 | sed 's/^saved to //; s/[.,;:)]*$//')"
		if [ -n "$file" ] && [ -f "$2/$(basename "$file")" ]; then
			saved="$(jq -r 'if type == "array" then [.[] | select(.type? == "text") | .text] | join("\n") else tojson end' \
				"$2/$(basename "$file")" 2> /dev/null)" || saved=""
			[ -n "$saved" ] || saved="$(cat "$2/$(basename "$file")")"
			jq -c --arg t "$saved" '.content = $t | .is_error = false' <<< "$line"
		else
			printf '%s\n' "$line"
		fi
	done < "$1"
}

# desk_follow_fetch_jira <pass> <pass_config> <entries> <state> <now> <jira_since or ""> <scope_due true|false> <out_dir>
# One model call, read-only, that runs the scope query (when due) and the
# changes query (unless this is the source's first run). Writes
# <out_dir>/scope.json and changes.json: an issue array, or null for a query
# that did not run or did not come back.
desk_follow_fetch_jira() {
	local pass="$1" pass_config="$2" entries="$3" state="$4" now="$5" since="$6" scope_due="$7" out_dir="$8"
	local jira tool prompt_rel
	jira="$(jq -c '.jira // {}' <<< "$pass_config")"
	tool="$(jq -r '.tool // empty' <<< "$jira")"
	prompt_rel="$(jq -r '.prompt // empty' <<< "$jira")"
	echo null > "$out_dir/scope.json"
	echo null > "$out_dir/changes.json"
	if [ -z "$tool" ] || [ -z "$prompt_rel" ]; then
		desk_log "$pass" "follow: no jira.tool or jira.prompt configured — no ticket fetch"
		return 1
	fi

	local tracked keys_only scope_keys scope_jql="none" changes_jql="none"
	tracked="$(jq -c '[.[] | (.keys // []) + (.related // []) | .[]] | unique' <<< "$entries")"
	keys_only="$(jq -c '[.[] | (.keys // [])[]] | unique' <<< "$entries")"
	if [ "$scope_due" = "true" ]; then
		scope_jql="key in ($(_desk_follow_jql_keys "$tracked"))"
		[ "$(jq 'length' <<< "$keys_only")" -gt 0 ] && scope_jql="$scope_jql OR parent in ($(_desk_follow_jql_keys "$keys_only"))"
	fi
	if [ -n "$since" ]; then
		# Everything already in scope, any new child, and any ticket that
		# mentions a tracked key; relative minutes, so the Jira user's own
		# time zone never shifts the window.
		scope_keys="$(jq -c --argjson t "$tracked" '[(.queues // {})[] | (.scope // [])[]] + $t | unique' <<< "$state")"
		local minutes=$(( (now - since + 59) / 60 + 5 ))
		[ "$minutes" -gt 43200 ] && minutes=43200
		local mentions
		mentions="$(jq -r 'map("text ~ \"\\\"" + . + "\\\"\"") | join(" OR ")' <<< "$tracked")"
		changes_jql="(key in ($(_desk_follow_jql_keys "$scope_keys"))"
		[ "$(jq 'length' <<< "$keys_only")" -gt 0 ] && changes_jql="$changes_jql OR parent in ($(_desk_follow_jql_keys "$keys_only"))"
		changes_jql="$changes_jql OR $mentions) AND updated >= -${minutes}m"
	fi
	if [ "$scope_jql" = "none" ] && [ "$changes_jql" = "none" ]; then
		return 0
	fi

	local scratch prompt_file out placeholders
	scratch="$(desk_scratch_dir "$pass-jira")"
	prompt_file="$scratch/prompt.txt"
	placeholders="$(jq -n --arg a "$scope_jql" --arg b "$changes_jql" --arg today "$(date +%F)" \
		--arg fa "$(jq -r 'join(", ")' <<< "$DESK_FOLLOW_SCOPE_FIELDS")" \
		--arg fb "$(jq -r 'join(", ")' <<< "$DESK_FOLLOW_CHANGE_FIELDS")" \
		'{scope_jql: $a, changes_jql: $b, scope_fields: $fa, changes_fields: $fb, today: $today}')"
	desk_render_prompt "$(desk_prompt_path "$prompt_rel")" "$placeholders" > "$prompt_file"
	local mcp_config
	mcp_config="$(jq -r '.mcp_config // empty' <<< "$jira")"
	if [ -n "$mcp_config" ]; then
		mcp_config="$(desk_prompt_path "$mcp_config")"
	else
		mcp_config="$scratch/empty-mcp.json"
		printf '%s\n' '{"mcpServers":{}}' > "$mcp_config"
	fi
	out="$out_dir/jira-stream.jsonl"
	desk_log "$pass" "follow: ticket fetch (scope: $([ "$scope_jql" = none ] && echo no || echo yes), changes: $([ "$changes_jql" = none ] && echo no || echo yes))"
	local model max_output
	model="$(jq -r '.model // empty' <<< "$jira")"
	# Results past this many tokens are saved to a file instead of reaching
	# the model; the runner reads them from there. A low limit keeps the
	# tickets' text out of the model's context altogether, which is
	# cheaper and leaves nothing for the text to steer.
	max_output="$(jq -r '.max_output_tokens // 2000' <<< "$jira")"
	(
		export MAX_MCP_OUTPUT_TOKENS="$max_output"
		desk_call_model --scratch "$scratch" --prompt-file "$prompt_file" \
			--allowed-tools "$tool" --tools "" --restricted true \
			--mcp-config "$mcp_config" --strict-mcp-config true \
			--max-budget-usd "$(jq -r '.max_budget_usd // 1' <<< "$jira")" \
			${model:+--model "$model"} --spill-dir "$out_dir/spill" \
			--timeout "$(jq -r '.timeout // 300' <<< "$jira")" \
			--config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" --out "$out"
	)
	local rc=$?
	rm -rf "$scratch"
	desk_follow_note_cost "$out"
	desk_extract_tool_uses "$out" > "$out_dir/jira-uses.jsonl"
	desk_extract_tool_results "$out" > "$out_dir/jira-results-raw.jsonl"
	_desk_follow_resolve_spills "$out_dir/jira-results-raw.jsonl" "$out_dir/spill" > "$out_dir/jira-results.jsonl"
	local got ok="true"
	if [ "$scope_jql" != "none" ]; then
		got="$(_desk_follow_issues_for "$out_dir/jira-uses.jsonl" "$out_dir/jira-results.jsonl" "$scope_jql" "$tool")"
		if [ -n "$got" ] && [ "$got" != "null" ]; then printf '%s\n' "$got" > "$out_dir/scope.json"
		else desk_log "$pass" "follow: the scope query did not come back — keeping the previous scope"; fi
	fi
	if [ "$changes_jql" != "none" ]; then
		got="$(_desk_follow_issues_for "$out_dir/jira-uses.jsonl" "$out_dir/jira-results.jsonl" "$changes_jql" "$tool")"
		if [ -n "$got" ] && [ "$got" != "null" ]; then printf '%s\n' "$got" > "$out_dir/changes.json"
		else desk_log "$pass" "follow: the changes query did not come back (call rc $rc)"; ok="false"; fi
	fi
	[ "$ok" = "true" ]
}

# gh, read-only: `pr list` and `pr view` and nothing else.
desk_follow_gh() {
	case "${1:-} ${2:-}" in
		"pr list" | "pr view") "$DESK_GH_BIN" "$@" ;;
		*)
			desk_log - "follow: refusing gh $* (only pr list and pr view)"
			return 2
			;;
	esac
}

# desk_follow_fetch_prs <pass> <pass_config> <state> <keys json> <since epoch> <with_comments true|false> <out>
# Every PR in the configured repos updated since <since> whose title or
# branch carries one of <keys>, normalized, as one JSON array in <out>;
# returns non-zero (and writes null) when a listing fails.
desk_follow_fetch_prs() {
	local pass="$1" pass_config="$2" state="$3" keys="$4" since="$5" with_comments="$6" out="$7"
	local repos since_iso all='[]' repo listed
	echo null > "$out"
	mapfile -t repos < <(jq -r '(.github_repos // [])[]' <<< "$pass_config")
	if [ "${#repos[@]}" -eq 0 ]; then
		echo '[]' > "$out"
		return 0
	fi
	since_iso="$(date -u -r "$since" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ)"
	for repo in "${repos[@]}"; do
		listed="$(desk_follow_gh pr list --repo "$repo" --state all --limit 100 --search "updated:>=$since_iso" \
			--json number,title,headRefName,state,isDraft,updatedAt,createdAt,reviewDecision,headRefOid,labels,url,body,statusCheckRollup 2> /dev/null)" \
			|| { desk_log "$pass" "follow: gh pr list failed for $repo"; return 1; }
		jq -e 'type == "array"' > /dev/null 2>&1 <<< "$listed" || { desk_log "$pass" "follow: gh pr list for $repo was not a list"; return 1; }
		listed="$(jq -c --arg repo "$repo" --argjson keys "$keys" '
			def pass_c: IN("SUCCESS", "NEUTRAL", "SKIPPED");
			def fail_c: IN("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE");
			[.[] | ([(.title + " " + .headRefName) | scan("[A-Za-z][A-Za-z0-9]+-[0-9]+") | ascii_upcase] | unique) as $k
			 | select(($k - ($k - $keys)) | length > 0)
			 | (.statusCheckRollup // []) as $c
			 | { id: "\($repo)#\(.number)", repo: $repo, number, title, branch: .headRefName, url,
			     state, draft: .isDraft, review: (.reviewDecision // null) | (if . == "" then null else . end),
			     head: .headRefOid, labels: ([.labels[]?.name] | sort), body: (.body // ""),
			     updated: .updatedAt, created: .createdAt, keys: $k,
			     checks: {
			       pass: ([$c[] | select(((.conclusion // .state // "") | pass_c))] | length),
			       fail: ([$c[] | select(((.conclusion // .state // "") | fail_c)) | (.name // .context // "check")] | unique),
			       pending: ([$c[] | select((.status // "COMPLETED") != "COMPLETED" or IN(.state; "PENDING", "EXPECTED"))] | length) },
			     comments: null }]' <<< "$listed")"
		all="$(jq -c --argjson a "$all" '$a + .' <<< "$listed")"
	done
	if [ "$with_comments" = "true" ]; then
		# Comments and reviews only for a PR that moved since its snapshot.
		local n i pr num repo_of prev_updated pr_updated view
		n="$(jq 'length' <<< "$all")"
		for ((i = 0; i < n; i++)); do
			pr="$(jq -c ".[$i]" <<< "$all")"
			prev_updated="$(jq -r --arg id "$(jq -r .id <<< "$pr")" '.prs[$id].updated // ""' <<< "$state")"
			pr_updated="$(jq -r .updated <<< "$pr")"
			[ "$prev_updated" = "$pr_updated" ] && continue
			num="$(jq -r .number <<< "$pr")"
			repo_of="$(jq -r .repo <<< "$pr")"
			view="$(desk_follow_gh pr view "$num" --repo "$repo_of" --json comments,reviews 2> /dev/null)" || continue
			jq -e . > /dev/null 2>&1 <<< "$view" || continue
			all="$(jq -c --argjson i "$i" --argjson v "$view" '
				.[$i].comments = (
					[($v.comments // [])[] | {id: ("c" + (.id // .url // .createdAt | tostring)), kind: "comment",
					   author: (.author.login // "someone"), at: .createdAt, body: (.body // "")}]
					+ [($v.reviews // [])[] | {id: ("r" + (.id // .submittedAt | tostring)), kind: "review",
					   author: (.author.login // "someone"), at: .submittedAt, state: (.state // "COMMENTED"), body: (.body // "")}])' <<< "$all")"
		done
	fi
	printf '%s\n' "$all" > "$out"
}

desk_follow_note_cost() {
	local c
	c="$(desk_extract_total_cost_usd "$1")"
	[ -n "$c" ] && [ -n "${DESK_FOLLOW_COSTS:-}" ] && printf '%s\n' "$c" >> "$DESK_FOLLOW_COSTS"
	return 0
}

# --- the message -----------------------------------------------------------------

# desk_follow_message <entry json> <queue json> <name> <preamble file> <max chars> <timezone>
# The whole message one session gets: the marker line, the instance's
# standing preamble, then every queued change, oldest first. A change's
# `also` holds the current names of the other followed sessions that have
# its ticket (desk_follow_also_names).
desk_follow_message() {
	local entry="$1" queue="$2" name="$3" preamble_file="$4" max="$5" tz="$6" preamble=""
	[ -f "$preamble_file" ] && preamble="$(cat "$preamble_file")"
	TZ="${tz:-${TZ:-UTC}}" jq -jn --argjson e "$entry" --argjson q "$queue" --arg name "$name" \
		--arg marker "$DESK_FOLLOW_MARKER" --arg preamble "$preamble" --argjson max "$max" '
		def when: strflocaltime("%a %d %b %H:%M");
		($q.changes // []) as $c
		| ([$c[].ref] | unique) as $refs
		| ($q.dropped // 0) as $dropped
		| [$c[] | ([(.context // "") | select(. != "")]
		           + (if ((.also // []) | length) > 0 then ["also followed by " + (.also | join(", "))] else [] end)) as $ctx
		   | "- \(.at | when) \(.ref) \"\(.title // "")\"\(if ($ctx | length) > 0 then " (" + ($ctx | join("; ")) + ")" else "" end): \(.what)"] as $lines
		| ("\($marker) Update for \($e.label): \($c | length) change\(if ($c | length) == 1 then "" else "s" end) on \($refs | .[0:6] | join(", "))\(if ($refs | length) > 6 then " and more" else "" end). Not from the user.") as $head
		| ($preamble | sub("\\s+$"; "")) as $pre
		| ("Changes since \(if $q.since then ($q.since | when) else "following started" end), oldest first:") as $intro
		| ($head + "\n\n" + (if $pre != "" then $pre + "\n\n" else "" end) + $intro + "\n") as $top
		# Lines are kept whole, oldest first, while they fit; the rest are
		# named by ticket only.
		| (reduce $lines[] as $l ({text: "", n: 0, full: false};
			if .full then . elif (($top + .text + $l) | length) + 600 > $max then .full = true
			else .text += $l + "\n" | .n += 1 end)) as $fit
		| $top + $fit.text
		  + (if $fit.n < ($lines | length)
		     then "- … and \(($lines | length) - $fit.n) more, too long to include, on \([$c[$fit.n:][] | .ref] | unique | .[0:20] | join(", "))\(if ([$c[$fit.n:][] | .ref] | unique | length) > 20 then " and others" else "" end); look them up if they matter.\n"
		     else "" end)
		  + (if $dropped > 0 then "- Plus \($dropped) older change\(if $dropped == 1 then "" else "s" end) the queue no longer holds.\n" else "" end)
		  # Everything left out on purpose is counted, so nothing is invisible.
		  + "\nSkipped since the last update, not listed: "
		  + (($q.skipped // {}) | to_entries | map(select(.value > 0)) | sort_by(-.value)
		     | if length == 0 then "nothing" else map("\(.value) \(if .value == 1 then (.key | sub("s$"; "")) else .key end)") | join(", ") end) + "."
		| sub("\\s+$"; "")'
}

# desk_follow_also_names <queue json> <entries json>: the queue with each
# change's `also`, the other followed sessions that have its ticket, turned
# from session ids into their current names (the label when the reader
# doesn't know one). A session no longer followed is left out.
desk_follow_also_names() {
	local queue="$1" entries="$2" names='{}' sid name
	while IFS= read -r sid; do
		[ -n "$sid" ] || continue
		name="$(_desk_follow_reader resolve "$sid" 2> /dev/null | jq -r '.name // empty' 2> /dev/null)"
		[ -n "$name" ] || name="$(jq -r --arg s "$sid" '.[$s].label // empty' <<< "$entries")"
		names="$(jq -c --arg s "$sid" --arg n "$name" '.[$s] = $n' <<< "$names")"
	done < <(jq -r --argjson e "$entries" '[(.changes // [])[] | (.also // [])[] | . as $s | select($e | has($s))] | unique[]' <<< "$queue")
	jq -c --argjson n "$names" '.changes = [(.changes // [])[]
		| if has("also") then .also = [.also[] | $n[.] // empty] else . end]' <<< "$queue"
}

# desk_follow_clock <epoch> <timezone>: HH:MM local, for a log line.
desk_follow_clock() {
	TZ="${2:-${TZ:-UTC}}" jq -rn --argjson t "$1" '$t | strflocaltime("%H:%M")'
}

# --- sending -----------------------------------------------------------------------

# desk_follow_send_verdict <stream file> <pinned args file> <to>
# Reads a send call's stream and prints one line: the verdict, a tab, and
# the first line of the tool's result (for the log).
#   confirmed    the pinned SendMessage call ran, and its result reports a
#                delivery to <to>.
#   unconfirmed  it ran and was not refused outright, but the result does
#                not report a delivery: a message may have reached the
#                session anyway, so a resend could land twice.
#   failed       no pinned call ran, or it failed: nothing was delivered.
# A delivery to a peer session answers {"success": true, "message":
# "“<the message's first line>” → <to> (another Claude session on this
# machine; in that session's inbox, … that session may hold it … or refuse
# it …)", "msg_id": …}. So the words after the recipient are boilerplate
# naming what *may* happen, and the preview before it is desk-follow's own
# text: neither is read as an outcome. Only a past-tense outcome after the
# recipient (refused, held, dropped, …) keeps a success from confirming. A
# hold reported later, as a delivery notice, reaches no headless sender.
desk_follow_send_verdict() {
	local stream="$1" pinned="$2" to="$3"
	jq -rs --slurpfile want "$pinned" --arg to "$to" '
		def text_of: if (.content | type) == "string" then .content
			elif (.content | type) == "array" then [.content[] | select(.type == "text") | .text] | join("\n") else "" end;
		def outcome_words: "\\b(refused|rejected|declined|was held|been held|is held|held for|not delivered|undelivered|dropped|expired|failed)\\b";
		def classify:
			(.text | try fromjson catch null) as $r
			| if .err then "failed"
			  elif ($r | type) == "object" then
			    if $r.success == false then "failed"
			    elif $r.success == true then
			      (($r.message // "") | tostring | split("” → " + $to)) as $parts
			      | if ($parts | length) < 2 then "unconfirmed"
			        elif ($parts | last | test(outcome_words; "i")) then "unconfirmed"
			        else "confirmed" end
			    else "unconfirmed" end
			  elif (.text | test("no agent named|not reachable|refused|denied"; "i")) then "failed"
			  else "unconfirmed" end;
		([.[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
		  | {key: .tool_use_id, value: {err: (.is_error == true), text: text_of}}] | from_entries) as $res
		| [.[] | select(.type == "assistant") | .message.content[]?
		   | select(.type == "tool_use" and .name == "SendMessage")
		   | select((.input | del(.summary, .content, .type, .recipient_kind)) as $i | any($want[0][]; . == $i))
		   | ($res[.id] // {err: true, text: ""}) | {v: classify, text}] as $runs
		| (if any($runs[]; .v == "confirmed") then "confirmed"
		   elif any($runs[]; .v == "unconfirmed") then "unconfirmed" else "failed" end) as $v
		| ([$runs[] | select(.v == $v) | .text] | last // "no SendMessage call to the pinned name ran") as $t
		| "\($v)\t\($t | gsub("[\\r\\n\\t]+"; " ") | .[0:300])"' "$stream" 2> /dev/null
}

# desk_follow_send <pass> <send config json> <to> <message file> <work dir>
# One restricted model call whose only tool is SendMessage, pinned by the
# deny hook to exactly {to, message} (its transcript-only `summary` aside).
# Prints desk_follow_send_verdict's line; "failed" when the call could not
# be made at all.
desk_follow_send() {
	local pass="$1" send="$2" to="$3" message_file="$4" work="$5"
	local prompt_rel scratch prompt_file pinned settings hook out
	prompt_rel="$(jq -r '.prompt // empty' <<< "$send")"
	[ -n "$prompt_rel" ] || { desk_log "$pass" "follow: no send.prompt configured"; printf 'failed\tno send.prompt configured\n'; return; }
	scratch="$(desk_scratch_dir "$pass-send")"
	pinned="$scratch/pinned-args.json"
	# The message as written, and with one trailing newline, since a copied
	# message may come back with either; and with Claude Code's own
	# `recipient`, which it fills in from `to`. The other fields it adds
	# (a `content` preview, `type`, `recipient_kind`) and the model's
	# `summary` are transcript-only and ignored.
	jq -n --arg to "$to" --rawfile m "$message_file" \
		'($m | sub("\\s+$"; "")) as $t
		| [($t, $t + "\n") as $msg | {to: $to, message: $msg}, {to: $to, recipient: $to, message: $msg}]' > "$pinned"
	hook="${DESK_DENY_HOOK_SCRIPT:-$DESK_LIB_DIR/deny-unlisted-tool.sh}"
	[ -f "$hook" ] || { desk_log "$pass" "follow: deny hook missing ($hook) — not sending"; rm -rf "$scratch"; printf 'failed\tdeny hook missing\n'; return; }
	settings="$scratch/deny-hook-settings.json"
	jq -n --arg cmd "$(desk_shq "$hook") --pinned $(desk_shq "$pinned") --ignore-keys summary,content,type,recipient_kind -- SendMessage" \
		'{hooks: {PreToolUse: [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' > "$settings"
	printf '%s\n' '{"mcpServers":{}}' > "$scratch/empty-mcp.json"
	prompt_file="$scratch/prompt.txt"
	desk_render_prompt "$(desk_prompt_path "$prompt_rel")" \
		"$(jq -n --arg to "$to" --rawfile m "$message_file" '{to: $to, message: $m}')" > "$prompt_file"
	out="$work/send-$RANDOM-stream.jsonl"
	local model
	model="$(jq -r '.model // empty' <<< "$send")"
	desk_call_model --scratch "$scratch" --prompt-file "$prompt_file" \
		--allowed-tools SendMessage --tools SendMessage --restricted true \
		--mcp-config "$scratch/empty-mcp.json" --strict-mcp-config true --settings "$settings" \
		--max-budget-usd "$(jq -r '.max_budget_usd // 1' <<< "$send")" \
		${model:+--model "$model"} \
		--timeout "$(jq -r '.timeout // 180' <<< "$send")" \
		--config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" --out "$out" > /dev/null
	desk_follow_note_cost "$out"
	local verdict
	verdict="$(desk_follow_send_verdict "$out" "$pinned" "$to")"
	rm -rf "$scratch"
	[ -n "$verdict" ] || verdict="$(printf 'failed\tthe send call left no readable stream')"
	printf '%s\n' "$verdict"
}

# --- the pass ------------------------------------------------------------------------

# desk_follow_main <pass> <pass_config> [--dry-run] [--scheduled] [--lookback-minutes N]
desk_follow_main() {
	local pass="$1" pass_config="$2"
	shift 2
	local dry_run="false" scheduled="false" lookback=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--dry-run) dry_run="true"; shift ;;
			--scheduled) scheduled="true"; shift ;;
			--lookback-minutes) lookback="${2:-}"; shift 2 ;;
			*) desk_log "$pass" "follow: unknown option $1"; return 2 ;;
		esac
	done
	if [ -n "$lookback" ] && ! [[ "$lookback" =~ ^[0-9]+$ ]]; then
		desk_log "$pass" "follow: --lookback-minutes takes whole minutes"
		return 2
	fi

	local entries
	entries="$(desk_follow_entries)"
	if [ "$(jq 'length' <<< "$entries")" -eq 0 ]; then
		desk_log "$pass" "follow: nothing is followed ($DESK_FOLLOW_FILE)"
		return 0
	fi

	local state now
	state="$(cat "$DESK_FOLLOW_STATE_FILE" 2> /dev/null)"
	jq -e 'type == "object"' > /dev/null 2>&1 <<< "$state" || state='{}'
	now="$(desk_now)"

	local interval
	interval="$(desk_follow_interval_minutes "$pass_config" "$pass")"
	if [ "$scheduled" = "true" ]; then
		local last_run
		last_run="$(jq -r '.last_run.at // 0' <<< "$state")"
		if [ $((now - last_run)) -lt $((interval * 60 - 60)) ]; then
			desk_log "$pass" "follow: last run was under $interval minutes ago — skipping"
			return 0
		fi
	fi

	# Its own lock, never the runner's: the follow pass touches nothing a morning
	# pass does. Waits a minute at most for another follow run.
	local lockdir
	lockdir="$(DESK_LOCK_NAME=follow DESK_LOCK_MAX_WAIT_SECS="${DESK_FOLLOW_LOCK_WAIT_SECS:-60}" desk_lock_acquire "$pass")"
	if [ -z "$lockdir" ]; then
		desk_log "$pass" "follow: another follow run holds the lock — skipping"
		return 0
	fi
	local work
	work="$(desk_scratch_dir "$pass-follow")"
	# shellcheck disable=SC2064
	trap "DESK_LOCK_NAME=follow desk_lock_release; rm -rf '$work'" EXIT
	export DESK_FOLLOW_COSTS="$work/costs.log"
	: > "$DESK_FOLLOW_COSTS"
	DESK_DENY_HOOK_SCRIPT="$work/deny-unlisted-tool.sh"
	cp "$DESK_LIB_DIR/deny-unlisted-tool.sh" "$DESK_DENY_HOOK_SCRIPT" || { desk_log "$pass" "follow: couldn't copy the deny hook"; return 2; }
	export DESK_DENY_HOOK_SCRIPT

	# Re-read under the lock: another run may have just finished.
	state="$(cat "$DESK_FOLLOW_STATE_FILE" 2> /dev/null)"
	jq -e 'type == "object"' > /dev/null 2>&1 <<< "$state" || state='{}'
	# The follow list changed: drop queues for sessions no longer followed.
	state="$(jq -c --argjson e "$entries" '.queues = ((.queues // {}) | with_entries(select(.key as $k | $e | has($k))))' <<< "$state")"

	# Windows: since the last fetch that came back, overlapping by five
	# minutes; the first run of a source records snapshots and sends nothing.
	local jira_last gh_last jira_since="" gh_since baseline_jira="false" baseline_gh="false"
	jira_last="$(jq -r '.last_jira_ok // empty' <<< "$state")"
	gh_last="$(jq -r '.last_gh_ok // empty' <<< "$state")"
	if [ -n "$lookback" ]; then
		jira_since=$((now - lookback * 60))
		gh_since=$jira_since
	else
		if [ -n "$jira_last" ]; then jira_since=$((jira_last - 300)); else baseline_jira="true"; fi
		if [ -n "$gh_last" ]; then gh_since=$((gh_last - 300)); else baseline_gh="true"; gh_since=$((now - 14 * 86400)); fi
	fi

	# Scope: tracked tickets, their children, and what links to either;
	# refreshed every scope_refresh_minutes, or when the follow list's keys
	# changed since the last refresh.
	local scope_due="false" refresh_minutes refreshed keys_sig
	refresh_minutes="$(jq -r '.scope_refresh_minutes // 60' <<< "$pass_config")"
	refreshed="$(jq -r '.scope.refreshed_at // 0' <<< "$state")"
	keys_sig="$(jq -c '[.[] | (.keys // []) + (.related // []) | .[]] | unique' <<< "$entries")"
	if [ $((now - refreshed)) -ge $((refresh_minutes * 60)) ] \
		|| [ "$(jq -c '.scope.keys_sig // null' <<< "$state")" != "$keys_sig" ]; then
		scope_due="true"
	fi

	local jira_ok="true"
	desk_follow_fetch_jira "$pass" "$pass_config" "$entries" "$state" "$now" "$jira_since" "$scope_due" "$work" || jira_ok="false"
	local scope_issues change_issues
	scope_issues="$(cat "$work/scope.json")"
	change_issues="$(cat "$work/changes.json")"
	if [ "$baseline_jira" = "true" ] && [ "$scope_issues" = "null" ]; then
		jira_ok="false"
	fi

	# PRs: matched against every key any follow's scope holds, including
	# children and links the scope query just found.
	local all_scope gh_ok="true"
	all_scope="$(jq -c --argjson s "$scope_issues" --argjson c "$change_issues" --argjson k "$keys_sig" '
		[(.queues // {})[] | (.scope // [])[]] + $k
		+ [($s // [])[] | .key, (.links[] | .key)] + [($c // [])[] | .key] | unique' <<< "$state")"
	local with_comments="true"
	[ "$baseline_gh" = "true" ] && with_comments="false"
	desk_follow_fetch_prs "$pass" "$pass_config" "$state" "$all_scope" "$gh_since" "$with_comments" "$work/prs.json" || gh_ok="false"

	local new_state
	jq -n --argjson entries "$entries" --slurpfile state <(printf '%s\n' "$state") \
		--slurpfile scope "$work/scope.json" --slurpfile changes "$work/changes.json" --slurpfile prs "$work/prs.json" \
		--argjson now "$now" --argjson jira_since "${jira_since:-$now}" --argjson gh_since "$gh_since" \
		--argjson baseline_jira "$baseline_jira" --argjson baseline_gh "$baseline_gh" \
		--argjson queue_max "$(jq -r '.queue_max // 200' <<< "$pass_config")" \
		--argjson skip "$(jq -c '.skip // {}' <<< "$pass_config")" --argjson lookback "$([ -n "$lookback" ] && echo true || echo false)" '
		{entries: $entries, state: $state[0], scope_issues: $scope[0], change_issues: $changes[0], prs: $prs[0],
		 now: $now, jira_since: $jira_since, gh_since: $gh_since,
		 baseline_jira: $baseline_jira, baseline_gh: $baseline_gh, queue_max: $queue_max,
		 skip: $skip, lookback: $lookback}' > "$work/diff-input.json"
	new_state="$(jq -c -f "$DESK_FOLLOW_DIFF_JQ" "$work/diff-input.json" 2> "$work/diff.err")" || new_state=""
	if [ -z "$new_state" ]; then
		desk_log "$pass" "follow: the diff failed: $(head -c 400 "$work/diff.err")"
		return 1
	fi
	new_state="$(jq -c --argjson k "$keys_sig" --argjson now "$now" --arg jira_ok "$jira_ok" --arg gh_ok "$gh_ok" \
		--arg lookback "$lookback" '
		.scope.keys_sig = (if .scope.refreshed_at == $now then $k else .scope.keys_sig end)
		| if $lookback != "" then . else
		    (if $jira_ok == "true" then .last_jira_ok = $now else . end)
		    | (if $gh_ok == "true" then .last_gh_ok = $now else . end)
		  end' <<< "$new_state")"

	# Delivery: one message per followed session with anything queued, to
	# its current name, only while it is live and the name addresses it
	# alone. The queue empties only on a confirmed send.
	local send preamble_file max_chars tz sent=0 held=0
	send="$(jq -c '.send // {}' <<< "$pass_config")"
	preamble_file="$(desk_prompt_path "$(jq -r '.preamble // "prompts/follow-preamble.md"' <<< "$pass_config")")"
	max_chars="$(jq -r '.message_max_chars // 8000' <<< "$pass_config")"
	tz="$(jq -r '.timezone // empty' "$DESK_CONFIG" 2> /dev/null)"
	local sid entry queue n hit name live dup back
	while IFS= read -r sid; do
		[ -n "$sid" ] || continue
		entry="$(jq -c --arg s "$sid" '.[$s]' <<< "$entries")"
		queue="$(jq -c --arg s "$sid" '.queues[$s] // {changes: []}' <<< "$new_state")"
		queue="$(jq -c --argjson st "$new_state" --arg s "$sid" '.since = ($st.last_sent[$s].at // null)' <<< "$queue")"
		n="$(jq '.changes | length' <<< "$queue")"
		[ "$n" -gt 0 ] || continue
		hit="$(_desk_follow_reader resolve "$sid" 2> /dev/null)" || hit=""
		name="$(jq -r '.name // empty' <<< "$hit" 2> /dev/null)"
		live="$(jq -r '.live // false' <<< "$hit" 2> /dev/null)"
		dup="$(jq -r '.duplicate_pids // false' <<< "$hit" 2> /dev/null)"
		local label
		label="$(jq -r '.label' <<< "$entry")"
		if [ "$live" != "true" ] || [ -z "$name" ]; then
			desk_log "$pass" "follow: $label: $n change(s) queued, the session is not running"
			held=$((held + 1))
			continue
		fi
		back="$(_desk_follow_reader resolve "$name" 2> /dev/null | jq -r '.id // empty' 2> /dev/null)"
		if [ "$dup" = "true" ] || [ "$back" != "$sid" ]; then
			desk_log "$pass" "follow: $label: the name '$name' does not address this session alone — $n change(s) stay queued"
			held=$((held + 1))
			continue
		fi
		# A send that failed backs off before a scheduled run tries again,
		# doubling from the interval up to four hours; a manual run always
		# tries.
		local retry_at
		retry_at="$(jq -r --arg s "$sid" '.queues[$s].retry_at // 0' <<< "$new_state")"
		if [ "$scheduled" = "true" ] && [ "$dry_run" != "true" ] && [ "$now" -lt "$retry_at" ]; then
			desk_log "$pass" "follow: $label: the last send failed — $n change(s) stay queued until the next try at $(desk_follow_clock "$retry_at" "$tz")"
			held=$((held + 1))
			continue
		fi
		local msg_file="$work/message-${sid:0:8}.txt"
		queue="$(desk_follow_also_names "$queue" "$entries")"
		desk_follow_message "$entry" "$queue" "$name" "$preamble_file" "$max_chars" "$tz" > "$msg_file"
		if [ "$dry_run" = "true" ]; then
			printf '=== would send to %s (%s change(s)) ===\n' "$name" "$n"
			cat "$msg_file"
			printf '\n'
			continue
		fi
		local result_line verdict detail
		result_line="$(desk_follow_send "$pass" "$send" "$name" "$msg_file" "$work")"
		verdict="${result_line%%$'\t'*}"
		detail="${result_line#*$'\t'}"
		local tries
		tries="$(jq -r --arg s "$sid" '.queues[$s].unconfirmed_sends // 0' <<< "$new_state")"
		if [ "$verdict" = "unconfirmed" ] && [ $((tries + 1)) -ge "$DESK_FOLLOW_MAX_UNCONFIRMED" ]; then
			# The call ran each time and the session may well have every
			# copy: sending the same changes again would only repeat them.
			desk_log "$pass" "follow: $label: the send to $name ran but was not confirmed, ${DESK_FOLLOW_MAX_UNCONFIRMED} times — treating the $n change(s) as sent, not sending them again (result: $detail)"
			sent=$((sent + 1))
			new_state="$(jq -c --arg s "$sid" --arg name "$name" --argjson now "$now" --argjson n "$n" '
				.queues[$s].changes = [] | .queues[$s].dropped = 0 | .queues[$s].skipped = {}
				| .queues[$s] |= del(.queued_since, .unconfirmed_sends, .failed_sends, .retry_at)
				| .last_sent[$s] = {at: $now, name: $name, changes: $n, confirmed: false}' <<< "$new_state")"
		elif [ "$verdict" = "confirmed" ]; then
			sent=$((sent + 1))
			desk_log "$pass" "follow: $label: sent $n change(s) to $name"
			new_state="$(jq -c --arg s "$sid" --arg name "$name" --argjson now "$now" --argjson n "$n" '
				.queues[$s].changes = [] | .queues[$s].dropped = 0 | .queues[$s].skipped = {}
				| .queues[$s] |= del(.queued_since, .unconfirmed_sends, .failed_sends, .retry_at)
				| .last_sent[$s] = {at: $now, name: $name, changes: $n}' <<< "$new_state")"
		elif [ "$verdict" = "unconfirmed" ]; then
			held=$((held + 1))
			desk_log "$pass" "follow: $label: the send to $name ran but was not confirmed — $n change(s) stay queued for one more try (result: $detail)"
			new_state="$(jq -c --arg s "$sid" '.queues[$s].unconfirmed_sends = ((.queues[$s].unconfirmed_sends // 0) + 1) | .queues[$s] |= del(.failed_sends, .retry_at)' <<< "$new_state")"
		else
			held=$((held + 1))
			local fails wait_min
			fails="$(jq -r --arg s "$sid" '(.queues[$s].failed_sends // 0) + 1' <<< "$new_state")"
			wait_min=$((interval * (1 << (fails > 5 ? 4 : fails - 1))))
			[ "$wait_min" -le 240 ] || wait_min=240
			# A minute short, as the interval check is, so launchd's own
			# drift never pushes the retry a whole interval later.
			retry_at=$((now + wait_min * 60 - 60))
			desk_log "$pass" "follow: $label: the send to $name failed — $n change(s) stay queued, next try at $(desk_follow_clock "$retry_at" "$tz") (result: $detail)"
			new_state="$(jq -c --arg s "$sid" --argjson f "$fails" --argjson at "$retry_at" \
				'.queues[$s].failed_sends = $f | .queues[$s].retry_at = $at' <<< "$new_state")"
		fi
	done < <(jq -r 'keys[]' <<< "$entries")

	local cost
	cost="$(jq -s 'add // 0' "$DESK_FOLLOW_COSTS" 2> /dev/null || echo 0)"
	local result="ok"
	{ [ "$jira_ok" = "true" ] && [ "$gh_ok" = "true" ]; } || result="partial"
	if [ "$dry_run" = "true" ]; then
		desk_log "$pass" "follow: dry run — nothing sent, no state written (jira $jira_ok, github $gh_ok, cost \$$cost)"
		return 0
	fi
	new_state="$(jq -c --argjson now "$now" --arg r "$result" --argjson sent "$sent" --argjson held "$held" --argjson cost "$cost" \
		'.last_run = {at: $now, result: $r, sent: $sent, held: $held, cost_usd: $cost}' <<< "$new_state")"
	desk_write_atomic "$DESK_FOLLOW_STATE_FILE" "$new_state
"
	desk_log "$pass" "follow: done: $result (sent $sent, queued for $held, cost \$$cost)"
	[ "$result" = "ok" ]
}
