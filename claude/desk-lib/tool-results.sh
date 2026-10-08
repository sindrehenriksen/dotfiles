#!/usr/bin/env bash
# Reads raw tool_use/tool_result pairs out of a call's own stream-json
# extraction (desk-lib/model-call.sh's desk_extract_tool_uses/
# desk_extract_tool_results) and collects the literal URLs a call's raw
# results actually carry — the trusted half of the rule that a
# source URL is accepted only if it appears verbatim in the fetch calls' raw
# tool_results. Nothing here reads
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
# <secs>.<micros> shape and a "channel" or "channel_id" field. Printed as
# JSON lines {"channel": "...", "ts": "..."}. A result that names its own
# channel is the rarer shape; desk_collect_slack_call_pairs covers the
# usual one.
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

# desk_collect_slack_call_pairs <tool-uses.jsonl> <tool-results.jsonl>
# The (channel, ts) pairs of the Slack shape seen live: the channel is only
# in the call's own arguments (`channel_id`, or `channel`), and the result
# is prose with a `Message TS: <ts>` line per message (a thread's replies
# too, under whatever word precedes `TS:`), or JSON whose objects carry a
# bare `ts`/`thread_ts`. Each such ts is paired with the channel its own
# call read, as is the thread parent the call named (`message_ts`). The
# window bounds (`oldest`, `latest`) are ts-shaped too and never paired: a
# bound is not a message. A call whose result never arrived pairs nothing.
# Same output as desk_collect_slack_ts_pairs.
desk_collect_slack_call_pairs() {
	local uses_file="$1" results_file="$2"
	[ -f "$uses_file" ] && [ -f "$results_file" ] || return 0
	local results_by_id
	results_by_id="$(jq -cs "map({(.tool_use_id): ($_DESK_JQ_RESULT_TEXT)}) | add // {}" \
		"$results_file" 2> /dev/null)"
	[ -n "$results_by_id" ] || return 0
	jq -c --argjson by_id "$results_by_id" '
		def is_ts: type == "string" and test("^[0-9]+\\.[0-9]+$");
		select((.input | type) == "object")
		| ((.input.channel_id // .input.channel) | select(type == "string" and . != "")) as $channel
		| ($by_id[.id] // "") as $text
		| select($text != "")
		| ([.input.message_ts | select(is_ts)]
			+ [$text | scan("(?i)\\bTS:\\s*([0-9]+\\.[0-9]+)") | .[0]]
			+ (($text | try fromjson catch null)
				| if . == null then [] else [.. | objects | (.ts?, .thread_ts?) | select(is_ts)] end))
		| unique[]
		| {channel: $channel, ts: .}
	' "$uses_file" 2> /dev/null
}

# desk_allowed_urls <workspace_url> <tool-results.jsonl>...
# The full set of URLs an item's `source` may cite for this pass: every
# literal URL a raw tool_result actually carries, plus a rebuilt Slack
# permalink for every (channel, ts) pair genuinely present in the raw
# calls — never a permalink for a pair a call only claimed in prose. Each
# `<id>-tool-results.jsonl` is read with the `<id>-tool-uses.jsonl` beside
# it, as desk_step_model_call writes the two, since the channel a Slack
# call read is only in its arguments. A permalink is the canonical
# <workspace_url>/archives/<channel_id>/p<ts with the dot removed>.
# $1 = the Slack workspace URL (e.g. https://<workspace>.slack.com); ""
# skips Slack entirely, for a pass with no Slack tool. One URL per line.
desk_allowed_urls() {
	local workspace_url="$1"
	shift
	desk_collect_literal_urls "$@"
	if [ -n "$workspace_url" ]; then
		local f
		{
			desk_collect_slack_ts_pairs "$@"
			for f in "$@"; do
				desk_collect_slack_call_pairs "${f%-tool-results.jsonl}-tool-uses.jsonl" "$f"
			done
		} | jq -r --arg w "$workspace_url" '"\($w)/archives/\(.channel)/p\(.ts | gsub("\\."; ""))"' 2> /dev/null | sort -u
	fi
}

# desk_mail_opened_thread_ids <tool-uses.jsonl> <tool-results.jsonl> <search-tool> <threads-json>
# Which of <threads-json>'s `[{id, ...}]` threads a call actually opened:
# a call to any tool but <search-tool> that names the thread's id as one of
# its argument values and got back a result that is neither empty nor an
# error. Generic over the read tool's name, since the one read a mail fetch
# makes on a thread id is opening it. Printed as a JSON array of ids, `[]`
# when either file is missing.
desk_mail_opened_thread_ids() {
	local uses_file="$1" results_file="$2" search_tool="$3" threads="$4"
	if [ ! -f "$uses_file" ] || [ ! -f "$results_file" ]; then
		echo '[]'
		return
	fi
	local results_by_id
	results_by_id="$(jq -cs "map(select(.is_error != true) | {(.tool_use_id): ($_DESK_JQ_RESULT_TEXT)}) | add // {}" \
		"$results_file" 2> /dev/null)"
	[ -n "$results_by_id" ] || results_by_id='{}'
	jq -cs --arg search "$search_tool" --argjson by_id "$results_by_id" --argjson threads "$threads" '
		[.[] | select(.name != $search) | select(($by_id[.id] // "") != "")
			| [.input | .. | strings]] | add // []
		| . as $named
		| [$threads[] | .id | select(. as $i | $named | index($i))]
	' "$uses_file" 2> /dev/null || echo '[]'
}
