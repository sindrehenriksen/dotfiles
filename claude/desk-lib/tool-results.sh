#!/usr/bin/env bash
# Reads raw tool_use/tool_result pairs out of a call's own stream-json
# extraction (desk-lib/model-call.sh's desk_extract_tool_uses/
# desk_extract_tool_results) and collects the literal URLs a call's raw
# results actually carry — the trusted half of design.md's "accepts a
# source URL only if it appears verbatim in the fetch calls' raw
# tool_results" (§4, §9(e), the Runner decisions note). Nothing here reads
# a model's prose reply; everything is keyed off tool_use_id, the one
# link between a call and what it actually did.
set -u

# Every text content block of one tool_result object, concatenated —
# `content` is documented as either a bare string or an array of content
# blocks, and both shapes turn up in a real stream-json transcript.
_DESK_JQ_RESULT_TEXT='if (.content | type) == "string" then .content
	elif (.content | type) == "array" then [.content[] | select(.type == "text") | .text] | join("\n")
	else "" end'

# desk_tool_call_pairs <tool-uses.jsonl> <tool-results.jsonl> <tool-name>
# Every {input, text} pair for calls to <tool-name>, in call order: `input`
# is the tool_use's own arguments, `text` is its paired tool_result's text
# (joined per _DESK_JQ_RESULT_TEXT), "" if the result never arrived (e.g.
# the call was still in flight when a timeout killed it). Printed as a
# JSON array; `[]` if either file is missing or nothing matches.
desk_tool_call_pairs() {
	local uses_file="$1" results_file="$2" tool_name="$3"
	if [ ! -f "$uses_file" ] || [ ! -f "$results_file" ]; then
		echo '[]'
		return
	fi
	local results_by_id
	results_by_id="$(jq -cs "map({(.tool_use_id): ($_DESK_JQ_RESULT_TEXT)}) | add // {}" \
		"$results_file" 2> /dev/null)"
	[ -n "$results_by_id" ] || results_by_id='{}'
	jq -cs --arg tool "$tool_name" --argjson by_id "$results_by_id" '
		map(select(.name == $tool))
		| map({input: .input, text: ($by_id[.id] // "")})
	' "$uses_file" 2> /dev/null || echo '[]'
}

# Every text block across $@ (one or more *-tool-results.jsonl files),
# one per line — the raw material desk_collect_literal_urls and
# desk_collect_slack_ts_pairs both walk.
_desk_result_texts() {
	local f
	for f in "$@"; do
		[ -f "$f" ] || continue
		jq -r "$_DESK_JQ_RESULT_TEXT" "$f" 2> /dev/null
	done
}

# Every literal http(s) URL string found in $@'s raw tool_results — parsed
# as JSON where a text block is one (a recursive `..` walk, generic across
# whatever shape a connector or built-in tool happens to return, rather
# than a field path hand-picked per tool) and always also scanned as plain
# text (a regex), since a tool's text block is often prose with a URL in
# it rather than a JSON blob (Gmail's viewUrl and WebSearch's result URLs
# both reach this, plain and JSON alike).
desk_collect_literal_urls() {
	_desk_result_texts "$@" | while IFS= read -r text; do
		[ -n "$text" ] || continue
		if jq -e . > /dev/null 2>&1 <<< "$text"; then
			jq -r '[.. | strings | select(test("^https?://"))] | .[]' <<< "$text" 2> /dev/null
		fi
		grep -oE 'https?://[^[:space:]"'"'"'<>)]+' <<< "$text" 2> /dev/null
	done | sort -u
}

# Every (channel, ts) pair found anywhere in $@'s raw tool_results — a
# recursive walk for any JSON object carrying both a "ts" matching Slack's
# <secs>.<micros> shape and a "channel" or "channel_id" field, per
# prompts/morning-f-private.md ("give channel_id and ts exactly as the
# tool returned them"). Printed as JSON lines {"channel": "...", "ts":
# "..."}. Unverified against a live Slack tool result (design.md §8's
# Phase-0 table flags the exact tool shapes generally) — this is the one
# place to adjust if a real call's shape differs.
desk_collect_slack_ts_pairs() {
	_desk_result_texts "$@" | while IFS= read -r text; do
		[ -n "$text" ] || continue
		jq -e . > /dev/null 2>&1 <<< "$text" || continue
		jq -c '
			.. | objects
			| select((.ts? | type) == "string" and (.ts | test("^[0-9]+\\.[0-9]+$")))
			| { channel: (.channel // .channel_id // empty), ts }
			| select(.channel != null and .channel != "")
		' <<< "$text" 2> /dev/null
	done
}

# The canonical Slack permalink design.md pins: <workspace_url>/archives/
# <channel_id>/p<ts with the dot removed>.
desk_slack_permalink() {
	local workspace_url="$1" channel="$2" ts="$3"
	printf '%s/archives/%s/p%s' "$workspace_url" "$channel" "${ts//./}"
}

# desk_allowed_urls <workspace_url> <tool-results.jsonl>...
# The full set of URLs an item's `source` may cite for this pass: every
# literal URL a raw tool_result actually carries, plus a rebuilt Slack
# permalink for every (channel, ts) pair genuinely present in the raw
# results — never a permalink for a pair a call only claimed in prose.
# $1 = the Slack workspace URL (e.g. https://<workspace>.slack.com); ""
# skips Slack entirely, for a pass with no Slack tool. One URL per line.
desk_allowed_urls() {
	local workspace_url="$1"
	shift
	desk_collect_literal_urls "$@"
	if [ -n "$workspace_url" ]; then
		desk_collect_slack_ts_pairs "$@" | while IFS= read -r pair; do
			[ -n "$pair" ] || continue
			local channel ts
			channel="$(jq -r '.channel' <<< "$pair")"
			ts="$(jq -r '.ts' <<< "$pair")"
			desk_slack_permalink "$workspace_url" "$channel" "$ts"
		done
	fi
}
