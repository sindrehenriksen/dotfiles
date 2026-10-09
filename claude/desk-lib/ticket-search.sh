#!/usr/bin/env bash
# The ticket search (docs/desk.md, "The ticket search"): a fetch step with a
# `ticket_search` key runs one ticket query the runner builds, for the
# tickets created in the pass's window, and the runner, not the model, reads
# its raw result. A result past Claude Code's output limit reaches the
# stream only as a saved file, which the call cannot open but the runner
# can (the call's spill directory), so a large day is read whole rather than
# lost. The step's judge file, <lowercased id>.json, is the runner's
# {window, tickets, coverage} in place of the model's reply.
#
# Files, in $PASS_SCRATCH and named after the step, so the same-day fetch
# cache carries them to a retry slot:
#   <id>-ticket-search-window.jsonl   {since, until, jql, capped}, fixed when the call is made
#   <id>-ticket-search.jsonl          the judge file
set -u

# The fields asked for when the config names none.
DESK_TICKET_SEARCH_FIELDS='["summary","status","issuetype","creator","assignee","created","parent","labels","priority","description"]'

# desk_ticket_search_config <step_json>: the step's `ticket_search` with its
# defaults filled in, or nothing when it has none or no jql.
desk_ticket_search_config() {
	jq -c --argjson f "$DESK_TICKET_SEARCH_FIELDS" '
		.ticket_search // empty
		| select((.jql // "") != "")
		| { jql, fields: (.fields // $f), self: (.self // []),
		    max_window_days: (.max_window_days // 4),
		    max_description_chars: (.max_description_chars // 1500) }' <<< "$1" 2> /dev/null
}

# desk_ticket_search_window <id> <cfg> <window_start epoch> <window_end epoch>
# Fixes this call's query and writes it beside the call's other files;
# prints the placeholders the prompt gets. The query asks in relative
# minutes, so the Jira account's own time zone never shifts it, five
# minutes wider than the window, which the runner then cuts to exactly. It
# reaches back at most max_window_days: past that, more results than one
# page holds are likely, and a saved result's next page cannot be fetched.
desk_ticket_search_window() {
	local id="$1" cfg="$2" start="$3" end="$4" floor since capped="false" minutes jql
	floor=$((end - $(jq -r '.max_window_days' <<< "$cfg") * 86400))
	since="$start"
	if [ "$since" -lt "$floor" ]; then
		since="$floor"
		capped="true"
	fi
	minutes=$(((end - since + 59) / 60 + 5))
	jql="($(jq -r '.jql' <<< "$cfg")) AND created >= -${minutes}m"
	jq -cn --argjson since "$since" --argjson until "$end" --arg jql "$jql" --argjson capped "$capped" \
		'{since: $since, until: $until, jql: $jql, capped: $capped}' > "$PASS_SCRATCH/$id-ticket-search-window.jsonl"
	jq -cn --arg jql "$jql" --arg f "$(jq -r '.fields | join(", ")' <<< "$cfg")" \
		'{ticket_search_jql: $jql, ticket_search_fields: $f}'
}

# One search result issue to the shape the judge gets.
_DESK_TICKET_SEARCH_NORM='
	def str: if . == null then null elif type == "string" then . else tojson end;
	def epoch: try (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $m
		| (($m.d + "Z") | fromdateiso8601)
		  - (if ($m.z // "Z") == "Z" then 0
		     else ($m.z | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<n>[0-9]{2})")
		           | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.n | tonumber) * 60)) end))
		catch null;
	(.fields // .) as $f
	| ($f.description | str) as $desc
	| { key: .key,
	    summary: ($f.summary // ""),
	    type: ($f.issuetype.name // null),
	    status: ($f.status.name // $f.status // null),
	    creator: ($f.creator.displayName // null),
	    assignee: ($f.assignee.displayName // null),
	    priority: ($f.priority.name // null),
	    created: ($f.created // null),
	    created_epoch: (($f.created // null) | if . == null then null else epoch end),
	    parent: (if $f.parent then {key: $f.parent.key, summary: ($f.parent.fields.summary // null)} else null end),
	    labels: (($f.labels // []) | sort),
	    mention_text: (($f.summary // "") + " " + ($desc // "")),
	    description: (if $desc == null then null
	                  elif ($desc | length) > $max then $desc[0:$max] + " …" else $desc end) }
	| select(.key != null)'

# desk_ticket_search_collect <pass> <id> <cfg> <tool>
# After the call: the tickets from the results of the calls whose jql is
# exactly the one built (a saved oversized result read back from the call's
# spill directory), cut to those created in the window, written as the
# step's judge file. When the query did not come back whole, the judge file
# says so in a `coverage` starting "FAILED:" and this returns non-zero,
# which fails the step: new tickets went unchecked, which is not "none".
desk_ticket_search_collect() {
	local pass="$1" id="$2" cfg="$3" tool="$4" window jql out="$PASS_SCRATCH/$id-ticket-search.jsonl"
	window="$(cat "$PASS_SCRATCH/$id-ticket-search-window.jsonl" 2> /dev/null)"
	jql="$(jq -r '.jql // empty' <<< "$window" 2> /dev/null)"
	if [ -z "$jql" ]; then
		desk_log "$pass" "$id: ticket search: no window recorded"
		return 1
	fi
	_desk_follow_resolve_spills "$PASS_SCRATCH/$id-tool-results.jsonl" "$PASS_SCRATCH/$id-spill" \
		> "$PASS_SCRATCH/$id-ticket-search-results.json" 2> /dev/null
	local pairs issues
	pairs="$(desk_tool_call_pairs "$PASS_SCRATCH/$id-tool-uses.jsonl" "$PASS_SCRATCH/$id-ticket-search-results.json" "$tool")"
	rm -f "$PASS_SCRATCH/$id-ticket-search-results.json"
	issues="$(jq -c --arg q "$jql" --argjson max "$(jq -r '.max_description_chars' <<< "$cfg")" "
		[.[] | select(.input.jql == \$q) | .text | (try fromjson catch null)] as \$all
		| [\$all[] | select(. != null)
		   | (if (.issues | type) == \"array\" then .issues
		      elif (.issues.nodes | type) == \"array\" then .issues.nodes else null end)] as \$pages
		| (\$all | last) as \$tail
		| ((\$tail.issues | objects | .pageInfo) // {}) as \$info
		| (\$tail != null and ((\$tail.nextPageToken // \$info.endCursor // null) != null
			and (\$tail.isLast != true) and (\$info.hasNextPage // true) != false)) as \$short
		| if (\$all | length) == 0 or any(\$all[]; . == null) or any(\$pages[]; . == null) or \$short then null
		  else [\$pages[][] | $_DESK_TICKET_SEARCH_NORM] | unique_by(.key) end" <<< "$pairs" 2> /dev/null)"

	if [ -z "$issues" ] || [ "$issues" = "null" ]; then
		local why="the ticket search did not come back whole (no result, one that could not be read, or a last page saying more follow)"
		desk_log "$pass" "$id: ticket search: $why"
		desk_run_note "$id's ticket search did not come back whole, so the tickets created since the last pass went unchecked: not none, unknown."
		jq -cn --argjson w "$window" --arg why "$why" \
			'{window: {since: ($w.since | todate), until: ($w.until | todate)}, tickets: [], coverage: ("FAILED: " + $why)}' > "$out"
		return 1
	fi
	jq -c --argjson w "$window" --argjson self "$(jq -c '.self' <<< "$cfg")" '
		length as $returned
		| [.[] | select(.created_epoch != null and .created_epoch >= $w.since and .created_epoch < $w.until)
		   | . as $t
		   | (if ($self | index($t.assignee)) != null then "assigned"
		      elif any($self[]; . as $n | ($t.mention_text | ascii_downcase | contains($n | ascii_downcase)))
		      then "mentioned" else null end) as $part
		   | del(.created_epoch, .mention_text) + (if $part then {user_part: $part} else {} end)] as $kept
		| { window: {since: ($w.since | todate), until: ($w.until | todate)},
		    tickets: ($kept | sort_by(.created)),
		    coverage: ("\($returned) returned, \($kept | length) created in the window"
		               + (if $w.capped then "; the window was cut to its last days, so tickets created before \($w.since | todate) were not searched" else "" end)) }' \
		<<< "$issues" > "$out"
	desk_log "$pass" "$id: ticket search: $(jq -r '.coverage' "$out")"
}
