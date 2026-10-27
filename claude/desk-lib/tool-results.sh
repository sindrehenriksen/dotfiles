#!/usr/bin/env bash
# Reads a call's tool_use/tool_result pairs out of its stream-json
# extraction (model-call.sh), keyed by tool_use_id: what the runner trusts
# of a call is what its tools returned, never its prose.
set -u

# Every text block of one tool_result, joined: `content` is a bare string
# or an array of content blocks.
_DESK_JQ_RESULT_TEXT='if (.content | type) == "string" then .content
	elif (.content | type) == "array" then [.content[] | select(.type == "text") | .text] | join("\n")
	else "" end'

# desk_tool_call_pairs <tool-uses.jsonl> <tool-results.jsonl> <tool-name>
# Every {input, text} pair for calls to <tool-name>, in call order, `text`
# "" for a result that never arrived. A JSON array, `[]` when either file
# is missing or nothing matches.
desk_tool_call_pairs() {
	local uses_file="$1" results_file="$2" tool_name="$3"
	if [ ! -f "$uses_file" ] || [ ! -f "$results_file" ]; then
		echo '[]'
		return
	fi
	# The results are read by jq itself: a long search's run to megabytes,
	# past what one argument may hold.
	jq -cs --arg tool "$tool_name" --slurpfile results "$results_file" '
		($results | map({(.tool_use_id): ('"$_DESK_JQ_RESULT_TEXT"')}) | add // {}) as $by_id
		| map(select(.name == $tool))
		| map({input: .input, text: ($by_id[.id] // "")})
	' "$uses_file" 2> /dev/null || echo '[]'
}
