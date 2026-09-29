#!/usr/bin/env bash
# T's own two jobs (design.md §4 "Ticket status, both passes", §9(c)'s
# `tokens` list, and nvim/lua/desk/annotate.lua's own pinned cache shape):
# building the `key in (...)` query from every ticket-like token in his
# notes, and turning T's raw search results — either Jira shape — into
# the ticket cache the editor reads. Never the model's reply: T's own
# prompt (prompts/ticket-status.md) tells it to reply "done" and nothing
# else, precisely so there's no prose to parse.
set -u

# Default follows $DESK_STATE_DIR (never a bare $HOME literal): common.sh's
# own DESK_STATE_DIR is already override-aware by the time this file is
# sourced, so a caller that points DESK_STATE_DIR at a throwaway dir (a
# test, or a differently-configured instantiation) gets its ticket cache
# under that same dir without having to separately override this one too —
# a bare $HOME default here is exactly how a test that only remembered to
# override DESK_STATE_DIR still wrote into the real
# ~/.local/state/desk/ticket-status.json.
DESK_TICKET_CACHE="${DESK_TICKET_CACHE:-${DESK_STATE_DIR:-$HOME/.local/state/desk}/ticket-status.json}"

# desk_ticket_keys_from_text <text> <tokens-config-json>
# Every distinct ticket key found in <text>, matched against every
# `tokens` entry whose handler is "url" (annotate.lua's own url-handler
# tokens — a "session" handler entry never names a ticket), case-folded
# per that entry's own `case_insensitive`, and always upper-cased in the
# output (Jira keys are canonically upper-case; his notes mix casing, per
# annotate.lua's own comment, but a JQL `key in (...)` needs one spelling
# per key or it just matches the same issue twice).
desk_ticket_keys_from_text() {
	local text="$1" tokens_json="$2"
	local n
	n="$(jq 'length' <<< "$tokens_json" 2> /dev/null || echo 0)"
	local i
	for ((i = 0; i < n; i++)); do
		local entry handler pattern ci
		entry="$(jq -c ".[$i]" <<< "$tokens_json")"
		handler="$(jq -r '.handler // empty' <<< "$entry")"
		[ "$handler" = "url" ] || continue
		pattern="$(jq -r '.pattern // empty' <<< "$entry")"
		[ -n "$pattern" ] || continue
		ci="$(jq -r '.case_insensitive // false' <<< "$entry")"
		local grep_opts=(-oE)
		[ "$ci" = "true" ] && grep_opts+=(-i)
		# Token patterns are anchored (^...$) for a whole-token match
		# (annotate.lua matches a token, not a substring); a note's running
		# text isn't pre-tokenized here, so anchors are stripped for the
		# free-text scan and every non-word character is treated as a
		# boundary instead — close enough for "TICKET-123" in a sentence
		# without a second tokenizer to keep in step with annotate.lua's.
		local body="${pattern#^}"
		body="${body%\$}"
		grep "${grep_opts[@]}" "\\b${body}\\b" <<< "$text" 2> /dev/null
	done | tr '[:lower:]' '[:upper:]' | sort -u
}

# desk_build_jql <notes-text> <tokens-config-json>
# The `jql` placeholder for prompts/ticket-status.md: `key in (...)` over
# every distinct key found. No keys found still returns valid JQL that
# matches nothing (an empty `in ()` is invalid JQL), rather than skip the
# call — T always runs, both passes (design.md §4).
desk_build_jql() {
	local text="$1" tokens_json="$2"
	local keys
	keys="$(desk_ticket_keys_from_text "$text" "$tokens_json")"
	if [ -z "$keys" ]; then
		echo 'key in ("DESK-NONE-0")'
		return
	fi
	local joined
	joined="$(tr '\n' ',' <<< "$keys" | sed 's/,$//')"
	echo "key in ($joined)"
}

# desk_parse_jira_issues <raw-result-text>
# Both Cloud Jira search shapes (prompts/README.md's own note, verbatim):
# interactive `{"issues": [...], "nextPageToken"}`, headless --mcp-config
# `{"issues": {"nodes": [...], "pageInfo"}}`. Prints one JSON object per
# issue found, `{"key", "summary", "status"}` — defensively over the
# field path within one issue, since neither shape's own per-issue layout
# is pinned by a live call yet (design.md §8's Phase-0 table): tries the
# REST shape (`fields.summary`/`fields.status.name`) first, falling back
# to a flatter one a GraphQL-style node might use instead.
desk_parse_jira_issues() {
	local text="$1"
	jq -e . > /dev/null 2>&1 <<< "$text" || return 1
	jq -c '
		(if (.issues | type) == "array" then .issues
		 elif (.issues.nodes | type) == "array" then .issues.nodes
		 else [] end)
		| .[]
		| { key: .key,
		    summary: (.fields.summary // .summary // empty),
		    status: (.fields.status.name // .status.name // .status // empty) }
		| select(.key != null)
	' <<< "$text" 2> /dev/null
}

# desk_build_ticket_cache <tool-uses.jsonl> <tool-results.jsonl> <tool-name>
# Parses every search-tool call/result pair (across however many pages T
# made) into the ticket cache's pinned shape and writes it atomically to
# $DESK_TICKET_CACHE: {"checked_at": <epoch>, "tickets": {"<KEY>":
# {"status": "...", "summary": "..."}}}. Prints "ok" and writes the file,
# or "failed" and writes nothing (design's "on failure the old cache
# stays, its age visible") when not one page parsed as valid JSON — an
# empty issue list from valid JSON (his notes name zero tickets, or all
# are gone) is still an "ok", refreshing checked_at with an empty map.
# `<tool-name>` is the instantiation's own ticket-search tool (desk-run's
# own required $DESK_CONFIG field "ticket_search_tool") — never a literal
# here, since dotfiles names no work-specific tool.
desk_build_ticket_cache() {
	local uses_file="$1" results_file="$2" tool_name="$3"
	local pairs
	pairs="$(desk_tool_call_pairs "$uses_file" "$results_file" "$tool_name")"
	local n
	n="$(jq 'length' <<< "$pairs" 2> /dev/null || echo 0)"
	if [ "$n" -eq 0 ]; then
		echo "failed"
		return 1
	fi

	local tickets="{}" any_valid="false"
	local i
	for ((i = 0; i < n; i++)); do
		local text issues
		text="$(jq -r ".[$i].text" <<< "$pairs")"
		[ -n "$text" ] || continue
		issues="$(desk_parse_jira_issues "$text")" || continue
		any_valid="true"
		local issue key summary status
		while IFS= read -r issue; do
			[ -n "$issue" ] || continue
			key="$(jq -r '.key' <<< "$issue")"
			summary="$(jq -r '.summary // ""' <<< "$issue")"
			status="$(jq -r '.status // ""' <<< "$issue")"
			tickets="$(jq -c --arg k "$key" --arg s "$status" --arg sum "$summary" \
				'.[$k] = {status: $s, summary: $sum}' <<< "$tickets")"
		done <<< "$issues"
	done

	if [ "$any_valid" != "true" ]; then
		echo "failed"
		return 1
	fi

	local now out
	now="$(desk_now)"
	out="$(jq -n --argjson now "$now" --argjson tickets "$tickets" \
		'{checked_at: $now, tickets: $tickets}')"
	desk_write_atomic "$DESK_TICKET_CACHE" "$out"
	echo "ok"
}
