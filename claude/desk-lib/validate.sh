#!/usr/bin/env bash
# Item validation shared by J (morning) and the 16:30 close calls
# (design.md §4, §9(e), the Runner decisions note): every item a judge-
# shaped call returns is untrusted until checked against that call's own
# raw tool_results, never its prose. This is the one place that runs: the
# source-URL check (desk-lib/tool-results.sh supplies the allowed set),
# control/ANSI-character and modeline stripping, 16:30's turn-citation
# check, and the daily/weekly tier caps with dated-brief overflow.
set -u

DESK_BRIEF_DIR="${DESK_BRIEF_DIR:-$DESK_STATE_DIR/briefs}"

# ---------------------------------------------------------------------------
# Stripping (design.md §5: "Suggested lines are stripped of control and
# ANSI characters"; this build's own modeline defense-in-depth, since the
# notes buffer's `nomodeline` is the other half of that).
# ---------------------------------------------------------------------------

# ANSI CSI sequences, a bare ESC, and any other C0 control byte except \t
# and \n.
desk_strip_control_chars() {
	perl -pe '
		s/\x1b\[[0-9;?]*[@-~]//g;
		s/\x1b//g;
		s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
	' 2> /dev/null
}

# The common vim/ex modeline forms, case-insensitive, wherever they occur
# in the text (a suggestion's before/after is a snippet, not a whole file,
# so this never assumes one sits at a line's start or end).
desk_strip_modelines() {
	perl -pe '
		s/\b(?:vim|ex):\s*set\s+[^\r\n:]*:?//gi;
		s/\b(?:vim|ex):[^\r\n]*//gi;
	' 2> /dev/null
}

# Removes any http(s) URL substring from $1 that isn't one of the allowed
# URLs in $2 (newline-separated), replacing it with "[url removed]" —
# design's "rejects or defangs other URLs in item text." An allowed URL is
# left exactly as it appears; a text with no URLs at all is unchanged.
desk_strip_disallowed_urls() {
	local text="$1" allowed_newline="$2"
	local urls
	urls="$(grep -oE 'https?://[^[:space:]"'"'"'<>)]+' <<< "$text" 2> /dev/null | sort -u)"
	[ -n "$urls" ] || { printf '%s' "$text"; return; }
	local url
	while IFS= read -r url; do
		[ -n "$url" ] || continue
		if ! grep -qxF "$url" <<< "$allowed_newline" 2> /dev/null; then
			local esc
			esc="$(printf '%s' "$url" | sed 's/[.[\*^$\/]/\\&/g')"
			text="$(printf '%s' "$text" | sed "s|$esc|[url removed]|g")"
		fi
	done <<< "$urls"
	printf '%s' "$text"
}

# Strips desk-lib/steps.sh's own DESK_AGENT_MARK suffix (a scratch-copy-only
# annotation on a line whose HEAD content is an accepted suggestion —
# desk_write_marked_head_copy's own comment) from $1. J or a 1630 call may
# echo a marked line back verbatim as part of an anchor/before/after; this
# is what keeps that mark from ever reaching his real files, and from
# breaking an exact-line anchor match against real (unmarked) HEAD content.
desk_strip_agent_marks() {
	local text="$1"
	printf '%s' "${text//${DESK_AGENT_MARK:-  <<agent-suggested>>}/}"
}

# One item's before/after/headline run through both stripping passes and
# the URL check, in one place so nothing downstream can apply only one of
# them. $2 = allowed URLs, newline-separated (desk_allowed_urls's output).
desk_sanitize_item_text() {
	local item_json="$1" allowed_urls="$2"
	local before after headline
	before="$(jq -r '.before // ""' <<< "$item_json")"
	after="$(jq -r '.after // ""' <<< "$item_json")"
	headline="$(jq -r '.headline // ""' <<< "$item_json")"
	local field
	for field in before after headline; do
		local val
		val="${!field}"
		val="$(desk_strip_agent_marks "$val")"
		val="$(desk_strip_disallowed_urls "$val" "$allowed_urls")"
		val="$(desk_strip_modelines <<< "$val")"
		val="$(desk_strip_control_chars <<< "$val")"
		printf -v "$field" '%s' "$val"
	done
	jq -c --arg b "$before" --arg a "$after" --arg h "$headline" \
		'.before = $b | .after = $a | .headline = $h' <<< "$item_json"
}

# Also validates the item's own `source` field: a bare non-URL source
# (e.g. "notes", "ticket:TICKET-1", "session:<id>") always passes; a URL
# source must be one of $2. An item whose URL source isn't allowed is
# dropped outright (its source is what J is citing as grounding — a
# stripped-but-kept source would misrepresent where it came from).
desk_source_allowed() {
	local item_json="$1" allowed_urls="$2"
	local source
	source="$(jq -r '.source // ""' <<< "$item_json")"
	if [[ "$source" != http://* ]] && [[ "$source" != https://* ]]; then
		return 0
	fi
	grep -qxF "$source" <<< "$allowed_urls" 2> /dev/null
}

# ---------------------------------------------------------------------------
# The full validation pass for a set of proposal-shaped items (design.md
# §9(e)): drops an item whose URL source isn't verifiably from this call's
# own raw results, then sanitizes every remaining item's text. $2 = the
# allowed-URL set (desk_allowed_urls's output, newline-separated).
# Caps are a separate step (desk_apply_caps below) since 16:30's items are
# never capped, only J's news items are.
# ---------------------------------------------------------------------------
desk_validate_items() {
	local items_json="$1" allowed_urls="$2"
	local n out
	out="[]"
	n="$(jq 'length' <<< "$items_json" 2> /dev/null || echo 0)"
	local i
	for ((i = 0; i < n; i++)); do
		local item
		item="$(jq -c ".[$i]" <<< "$items_json")"
		desk_source_allowed "$item" "$allowed_urls" || continue
		item="$(desk_sanitize_item_text "$item" "$allowed_urls")"
		out="$(jq -c --argjson it "$item" '. + [$it]' <<< "$out")"
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 16:30's own extra check (the Runner decisions note: "16:30 turn citations
# are verified by the runner and stripped"). prompts/1630-close.md pins the
# exact format: each bullet ends with "[turn <first 8 chars of a
# transcript entry's uuid>]". An item citing a uuid prefix absent from the
# transcript tail it was actually given is dropped (a fabricated citation
# is worse than none); every citation marker is stripped from before/after
# before an item is kept, valid or not — the marker itself never belongs
# in his notes.
# ---------------------------------------------------------------------------
_DESK_TURN_MARK_GREP='\[turn [A-Za-z0-9]+\]'
_DESK_TURN_MARK_SED='s/\[turn [A-Za-z0-9]+\]//g'

desk_verify_and_strip_turn_citations() {
	local items_json="$1" transcript_tail_file="$2"
	local valid_prefixes=""
	if [ -f "$transcript_tail_file" ]; then
		valid_prefixes="$(jq -r '.uuid? // empty | .[0:8]' "$transcript_tail_file" 2> /dev/null)"
	fi

	local n out
	out="[]"
	n="$(jq 'length' <<< "$items_json" 2> /dev/null || echo 0)"
	local i
	for ((i = 0; i < n; i++)); do
		local item before after combined citations ok
		item="$(jq -c ".[$i]" <<< "$items_json")"
		before="$(jq -r '.before // ""' <<< "$item")"
		after="$(jq -r '.after // ""' <<< "$item")"
		combined="$before"$'\n'"$after"
		citations="$(grep -oE "$_DESK_TURN_MARK_GREP" <<< "$combined" 2> /dev/null \
			| sed -E 's/\[turn ([A-Za-z0-9]+)\]/\1/')"
		ok="true"
		if [ -n "$citations" ]; then
			local cite
			while IFS= read -r cite; do
				[ -n "$cite" ] || continue
				grep -qxF "$cite" <<< "$valid_prefixes" 2> /dev/null || ok="false"
			done <<< "$citations"
		fi
		before="$(sed -E "$_DESK_TURN_MARK_SED" <<< "$before")"
		after="$(sed -E "$_DESK_TURN_MARK_SED" <<< "$after")"
		item="$(jq -c --arg b "$before" --arg a "$after" '.before = $b | .after = $a' <<< "$item")"
		[ "$ok" = "true" ] || continue
		out="$(jq -c --argjson it "$item" '. + [$it]' <<< "$out")"
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Caps (design.md §4: "daily ≤3 ACT, ≤3 worth-knowing, ≤1 wildcard; weekly
# ≤5/≤8/≤1; overflow to the dated brief"). Only tiered items (news, via
# `tier`) are ever capped; anything else (edits, removals, closure notes)
# passes straight through uncounted.
# ---------------------------------------------------------------------------

# desk_apply_caps <items-json> <caps-json> <pass>
# caps-json: {"act": N, "worth_knowing": N, "wildcard": N}. Prints
# {"kept": [...], "overflow": [...]}. An overflowing tier's dropped items
# are appended to today's dated brief ($DESK_BRIEF_DIR/<date>.md) and
# replaced in `kept` by one "+N more <tier> → brief" item landing on top.
desk_apply_caps() {
	local items_json="$1" caps_json="$2" pass="$3"
	local today brief_file
	today="$(date +%F)"
	brief_file="$DESK_BRIEF_DIR/$today.md"

	local n kept overflow
	kept="[]"
	overflow="[]"
	n="$(jq 'length' <<< "$items_json" 2> /dev/null || echo 0)"
	local act=0 worth_knowing=0 wildcard=0
	local i
	for ((i = 0; i < n; i++)); do
		local item tier cap count_var count cap_ok
		item="$(jq -c ".[$i]" <<< "$items_json")"
		tier="$(jq -r '.tier // empty' <<< "$item")"
		if [ -z "$tier" ]; then
			kept="$(jq -c --argjson it "$item" '. + [$it]' <<< "$kept")"
			continue
		fi
		cap="$(jq -r --arg t "$tier" '.[$t] // 999999' <<< "$caps_json")"
		case "$tier" in
			act) count=$act ;;
			worth_knowing) count=$worth_knowing ;;
			wildcard) count=$wildcard ;;
			*) count=0 ;;
		esac
		if [ "$count" -lt "$cap" ]; then
			case "$tier" in
				act) act=$((act + 1)) ;;
				worth_knowing) worth_knowing=$((worth_knowing + 1)) ;;
				wildcard) wildcard=$((wildcard + 1)) ;;
			esac
			kept="$(jq -c --argjson it "$item" '. + [$it]' <<< "$kept")"
		else
			overflow="$(jq -c --argjson it "$item" '. + [$it]' <<< "$overflow")"
		fi
	done

	local overflow_n
	overflow_n="$(jq 'length' <<< "$overflow")"
	if [ "$overflow_n" -gt 0 ]; then
		mkdir -p "$DESK_BRIEF_DIR" 2> /dev/null
		{
			printf '\n## %s overflow (%s)\n\n' "$pass" "$today"
			jq -r '.[] | "- [" + (.tier // "?") + "] " + (.headline // "(no headline)") + " — " + (.source // "")' <<< "$overflow"
		} >> "$brief_file"

		local per_tier pt_n pi
		per_tier="$(jq -c '[.[] | .tier] | group_by(.) | map({tier: .[0], n: length})' <<< "$overflow")"
		pt_n="$(jq 'length' <<< "$per_tier")"
		for ((pi = 0; pi < pt_n; pi++)); do
			local pt tier_name tier_count summary_item
			pt="$(jq -c ".[$pi]" <<< "$per_tier")"
			tier_name="$(jq -r '.tier' <<< "$pt")"
			tier_count="$(jq -r '.n' <<< "$pt")"
			summary_item="$(jq -n --arg id "${pass}-overflow-${tier_name}-${today}" \
				--arg headline "+${tier_count} more ${tier_name} → brief" \
				--arg source "brief:$brief_file" '{
					id: $id, file: "notes.md", kind: "new", target: "top",
					before: "", after: "", source: $source, headline: $headline
				}')"
			kept="$(jq -c --argjson it "$summary_item" '. + [$it]' <<< "$kept")"
		done
	fi
	jq -n --argjson kept "$kept" --argjson overflow "$overflow" '{kept: $kept, overflow: $overflow}'
}
