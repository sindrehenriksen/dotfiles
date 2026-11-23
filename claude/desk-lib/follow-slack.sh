#!/usr/bin/env bash
# The follow pass's Slack source (docs/desk.md, "The follow pass"): the
# messages new in a followed channel or thread since the last run. Sourced
# by follow.sh; follow-slack.jq decides the reads and parses their results.
#
# Read-only, and only through the two read tools the pass config names
# (`slack.channel_tool`, `slack.thread_tool`), every call pinned by the deny
# hook to arguments the runner built. The tools come from the account's own
# Slack connector, so this is the one desk call without --strict-mcp-config:
# `slack.connector_url` is instead the only MCP server its settings admit
# (`allowedMcpServers`), and the connectors are waited for before the first
# turn, which a headless call otherwise starts without.
set -u

DESK_FOLLOW_SLACK_JQ="$DESK_LIB_DIR/follow-slack.jq"

# A channel id, `<channel id>:<parent ts>`, or a Slack link to a channel, a
# message or a thread, as the ref a follow stores: the channel id, or for a
# thread `<channel id>:<parent ts>`. Fails on anything else.
desk_follow_slack_ref() {
	local in="$1" id='[CGD][A-Z0-9]{6,}' ts='[0-9]{10}\.[0-9]{6}'
	if [[ "$in" =~ ^($id)(:($ts))?$ ]]; then
		printf '%s\n' "$in"
	elif [[ "$in" =~ ^https://[A-Za-z0-9.-]+\.slack\.com/archives/($id)(/p([0-9]{10})([0-9]{6}))?/?(\?.*)?$ ]]; then
		local c="${BASH_REMATCH[1]}" secs="${BASH_REMATCH[3]}" micros="${BASH_REMATCH[4]}" query="${BASH_REMATCH[5]}"
		if [[ "$query" =~ [?\&]thread_ts=($ts) ]]; then
			printf '%s:%s\n' "$c" "${BASH_REMATCH[1]}"
		elif [ -n "$secs" ]; then
			printf '%s:%s.%s\n' "$c" "$secs" "$micros"
		else
			printf '%s\n' "$c"
		fi
	else
		return 1
	fi
}

# _desk_follow_slack_call <pass> <slack config> <calls json> <out_dir> <n>
# One restricted call making exactly the reads in <calls> ([{tool: "channel"
# | "thread", args}]), its tool uses and raw results appended to
# <out_dir>/slack-uses.jsonl and slack-results-raw.jsonl.
_desk_follow_slack_call() {
	local pass="$1" cfg="$2" calls="$3" out_dir="$4" n="$5"
	local channel_tool thread_tool url scratch pinned settings hook out model
	channel_tool="$(jq -r '.channel_tool' <<< "$cfg")"
	thread_tool="$(jq -r '.thread_tool' <<< "$cfg")"
	url="$(jq -r '.connector_url' <<< "$cfg")"
	hook="${DESK_DENY_HOOK_SCRIPT:-$DESK_LIB_DIR/deny-unlisted-tool.sh}"
	scratch="$(desk_scratch_dir "$pass-slack")"
	pinned="$scratch/pinned-args.json"
	jq -c --arg ct "$channel_tool" --arg tt "$thread_tool" \
		'{($ct): [.[] | select(.tool == "channel") | .args], ($tt): [.[] | select(.tool == "thread") | .args]}' <<< "$calls" > "$pinned"
	settings="$scratch/deny-hook-settings.json"
	jq -n --arg url "$url" \
		--arg cmd "$(desk_shq "$hook") --pinned $(desk_shq "$pinned") -- $(desk_shq "$channel_tool") $(desk_shq "$thread_tool")" \
		'{allowedMcpServers: [{serverUrl: $url}],
		  hooks: {PreToolUse: [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]}}' > "$settings"
	desk_render_prompt "$(desk_prompt_path "$(jq -r '.prompt' <<< "$cfg")")" \
		"$(jq -c --arg ct "$channel_tool" --arg tt "$thread_tool" \
			'{calls: (map((if .tool == "channel" then $ct else $tt end) + " " + (.args | tojson)) | join("\n"))}' <<< "$calls")" > "$scratch/prompt.txt"
	model="$(jq -r '.model // empty' <<< "$cfg")"
	out="$out_dir/slack-$n-stream.jsonl"
	(
		# A low limit, as for the ticket fetch: a long result is saved to a
		# file the runner reads and stays out of the call's context.
		export MAX_MCP_OUTPUT_TOKENS="$(jq -r '.max_output_tokens // 2000' <<< "$cfg")"
		export MCP_CONNECTION_NONBLOCKING=false
		desk_call_model --scratch "$scratch" --prompt-file "$scratch/prompt.txt" \
			--allowed-tools "$channel_tool,$thread_tool" --tools "" --restricted true \
			--settings "$settings" --max-budget-usd "$(desk_max_budget_usd)" \
			${model:+--model "$model"} --spill-dir "$out_dir/slack-spill" \
			--timeout "$(jq -r '.timeout // 300' <<< "$cfg")" \
			--config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" --out "$out"
	) > /dev/null
	rm -rf "$scratch"
	desk_follow_note_cost "$out"
	desk_extract_tool_uses "$out" >> "$out_dir/slack-uses.jsonl"
	desk_extract_tool_results "$out" >> "$out_dir/slack-results-raw.jsonl"
}

# _desk_follow_slack_digest <slack config> <out_dir> <final true|false>
# follow-slack.jq's reading of every result so far; "" when it failed.
_desk_follow_slack_digest() {
	local cfg="$1" out_dir="$2" final="$3"
	_desk_follow_resolve_spills "$out_dir/slack-results-raw.jsonl" "$out_dir/slack-spill" > "$out_dir/slack-results.jsonl"
	desk_tool_call_pairs "$out_dir/slack-uses.jsonl" "$out_dir/slack-results.jsonl" "$(jq -r '.channel_tool' <<< "$cfg")" > "$out_dir/slack-channel-pairs.json"
	desk_tool_call_pairs "$out_dir/slack-uses.jsonl" "$out_dir/slack-results.jsonl" "$(jq -r '.thread_tool' <<< "$cfg")" > "$out_dir/slack-thread-pairs.json"
	jq -c --slurpfile cp "$out_dir/slack-channel-pairs.json" --slurpfile tp "$out_dir/slack-thread-pairs.json" --argjson final "$final" \
		'. + {channel_pairs: $cp[0], thread_pairs: $tp[0], final: $final}' "$out_dir/slack-input.json" \
		| jq -c --arg mode digest -f "$DESK_FOLLOW_SLACK_JQ" 2> "$out_dir/slack.err"
}

# desk_follow_fetch_slack <pass> <pass_config> <entries> <slack state> <now> <lookback since or ""> <out_dir>
# Writes <out_dir>/slack.json, {events, state}: the new messages, each
# naming the ref it came from, and the `slack` state to keep. Returns
# non-zero when a read did not come back; the sources that did are still in
# both.
desk_follow_fetch_slack() {
	local pass="$1" pass_config="$2" entries="$3" prev="$4" now="$5" since="$6" out_dir="$7"
	local refs cfg tz
	refs="$(jq -c '[.[] | (.slack // [])[]] | unique' <<< "$entries")"
	if [ "$(jq 'length' <<< "$refs")" -eq 0 ]; then
		echo '{"events": [], "state": {}}' > "$out_dir/slack.json"
		return 0
	fi
	jq -n --argjson s "$prev" '{events: [], state: $s}' > "$out_dir/slack.json"
	cfg="$(jq -c '.slack // {}' <<< "$pass_config")"
	if ! jq -e 'all(.channel_tool, .thread_tool, .prompt, .connector_url; (. // "") != "")' > /dev/null <<< "$cfg"; then
		desk_log "$pass" "follow: slack.channel_tool, thread_tool, prompt and connector_url are not all configured — no Slack read"
		return 1
	fi
	if [ ! -f "${DESK_DENY_HOOK_SCRIPT:-$DESK_LIB_DIR/deny-unlisted-tool.sh}" ]; then
		desk_log "$pass" "follow: deny hook missing — no Slack read"
		return 1
	fi
	tz="$(jq -r '.timezone // empty' "$DESK_CONFIG" 2> /dev/null)"
	jq -n --argjson refs "$refs" --argjson state "$prev" --argjson now "$now" --arg since "$since" \
		--arg local "$([ -z "$since" ] || TZ="${tz:-${TZ:-UTC}}" jq -rn --argjson t "$since" '$t | strflocaltime("%Y-%m-%d %H:%M:%S")')" \
		'{refs: $refs, state: $state, now: $now,
		  since: (if $since == "" then null else ($since | tonumber) end),
		  since_local: (if $local == "" then null else $local end)}' > "$out_dir/slack-input.json"
	: > "$out_dir/slack-uses.jsonl"
	: > "$out_dir/slack-results-raw.jsonl"

	# The first call reads every channel and followed thread; a second
	# reads the threads the channel reads showed have moved.
	local calls result="" final
	calls="$(jq -c --arg mode plan -f "$DESK_FOLLOW_SLACK_JQ" "$out_dir/slack-input.json" 2> "$out_dir/slack.err")" || calls='[]'
	for final in false true; do
		if [ "$(jq 'length' <<< "$calls")" -gt 0 ]; then
			desk_log "$pass" "follow: Slack read ($(jq '[.[] | select(.tool == "channel")] | length' <<< "$calls") channel(s), $(jq '[.[] | select(.tool == "thread")] | length' <<< "$calls") thread(s))"
			_desk_follow_slack_call "$pass" "$cfg" "$calls" "$out_dir" "$([ "$final" = true ] && echo 2 || echo 1)"
		fi
		result="$(_desk_follow_slack_digest "$cfg" "$out_dir" "$final")"
		[ -n "$result" ] || break
		calls="$(jq -c '[.thread_calls[] | {tool: "thread", args: .}]' <<< "$result")"
		[ "$(jq 'length' <<< "$calls")" -gt 0 ] || break
	done
	if [ -z "$result" ]; then
		desk_log "$pass" "follow: the Slack reads could not be worked out: $(head -c 400 "$out_dir/slack.err" 2> /dev/null)"
		return 1
	fi
	local line
	while IFS= read -r line; do
		[ -z "$line" ] || desk_log "$pass" "follow: Slack: $line"
	done < <(jq -r '(.failed[] | "no read of " + .), .notes[]' <<< "$result")
	jq -c '{events, state}' <<< "$result" > "$out_dir/slack.json"
	desk_log "$pass" "follow: Slack: $(jq '.events | length' <<< "$result") new message(s) in $(jq 'length' <<< "$refs") source(s)"
	if [ "$(jq -r '.ok' <<< "$result")" != "true" ]; then
		_desk_follow_keep_failed "$pass" slack-read "$out_dir/slack-1-stream.jsonl" "$out_dir/slack-results.jsonl" \
			"$out_dir/slack-uses.jsonl" "$out_dir/slack-spill" "$out_dir"/slack-2-stream.jsonl
		return 1
	fi
}
