#!/usr/bin/env bash
# Item validation shared by J (morning) and the close calls: every item a judge-
# shaped call returns is untrusted until checked against that call's own
# raw tool_results, never its prose. This is the one place that runs: the
# source-URL check (desk-lib/tool-results.sh supplies the allowed set),
# control/ANSI-character and modeline stripping, the close call's turn-citation
# check, and the daily/weekly tier caps.
set -u

# ---------------------------------------------------------------------------
# Stripping: control and ANSI characters, and vim modelines (the notes
# buffer's `nomodeline` is the other half of that defense).
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
# URLs in $2 (newline-separated), replacing it with "[url removed]".
# An allowed URL is left exactly as it appears; a text with no URLs at all is
# unchanged. A labelled link, `[label](url)`, is kept whole when its URL is
# allowed, and becomes `label [url removed]` when it is not, so no link
# syntax is left pointing at nothing.
desk_strip_disallowed_urls() {
	local text="$1" allowed_newline="$2"
	DESK_ALLOWED_URLS="$allowed_newline" perl -0777 -e '
		my %ok = map { $_ => 1 } grep { length } split /\n/, $ENV{DESK_ALLOWED_URLS};
		my $t = join "", <STDIN>;
		my $url = qr{https?://[^\s"\x27<>)]+};
		my @kept;
		$t =~ s{\[([^\]\n]*)\]\(($url)\)}{
			if ($ok{$2}) { push @kept, "[$1]($2)"; "\x00" . $#kept . "\x00" } else { "$1 [url removed]" }
		}ge;
		$t =~ s{($url)}{ $ok{$1} ? $1 : "[url removed]" }ge;
		$t =~ s{\x00(\d+)\x00}{$kept[$1]}g;
		print $t;
	' <<< "$text" | perl -pe 'chomp if eof'
}

# Strips desk-lib/steps.sh's own DESK_AGENT_MARK suffix (a scratch-copy-only
# annotation on a line whose HEAD content is an accepted suggestion —
# desk_write_marked_head_copy's own comment) from $1. J or a close call may
# echo a marked line back verbatim as part of an anchor/before/after; this
# is what keeps that mark from ever reaching the user's real files, and from
# breaking an exact-line anchor match against real (unmarked) HEAD content.
desk_strip_agent_marks() {
	local text="$1"
	printf '%s' "${text//${DESK_AGENT_MARK:-  <<agent-suggested>>}/}"
}

# One item's text run through the stripping passes and the URL check, in one
# place so nothing downstream can apply only one of them. $2 = allowed URLs,
# newline-separated (desk_allowed_urls's output). `before` is the user's text as the
# agent quoted it and must keep matching the user's file, so it is never altered
# (beyond the scratch-copy agent mark). The URLs on the user's own line are the user's:
# an edit, move or merge may keep in `after` any URL its `before` carries, and only
# URLs the agent adds (in `after` or the headline) are checked against the
# allowed set. `before` is the model's own claim, so it counts only when it
# sits verbatim, as whole lines, in the item's file as committed in $3 (the
# notes repo); without $3, or for any other kind, the allowed set is all
# there is.
# A blank line `after` ends with is kept, newlines and all, since it can
# be the point of an item (desk.apply fits it to where it lands); every
# command substitution here would otherwise drop it. A lone final newline
# only ends the text, and goes as before.
desk_sanitize_item_text() {
	local item_json="$1" allowed_urls="$2" repo="${3:-}"
	local before after headline after_tail
	before="$(jq -r '.before // ""' <<< "$item_json")"
	after="$(jq -r '.after // ""' <<< "$item_json")"
	after_tail="$(jq -r '.after // "" | if test("[^\n]") then (capture("(?<t>\n*)$").t | length) else 0 end' <<< "$item_json")"
	headline="$(jq -r '.headline // ""' <<< "$item_json")"
	before="$(desk_strip_agent_marks "$before")"
	local own_urls="" after_allowed
	if desk_before_is_committed "$item_json" "$before" "$repo"; then
		own_urls="$(grep -oE 'https?://[^[:space:]"'"'"'<>)]+' <<< "$before" 2> /dev/null | sort -u)"
	fi
	after_allowed="$allowed_urls"
	[ -z "$own_urls" ] || after_allowed="$allowed_urls"$'\n'"$own_urls"
	local field val allow
	for field in after headline; do
		val="${!field}"
		allow="$allowed_urls"
		[ "$field" != after ] || allow="$after_allowed"
		val="$(desk_strip_agent_marks "$val")"
		val="$(desk_strip_disallowed_urls "$val" "$allow")"
		val="$(desk_strip_modelines <<< "$val")"
		val="$(desk_strip_control_chars <<< "$val")"
		if [ "$field" = after ] && [ "${after_tail:-0}" -ge 2 ]; then
			local i
			for ((i = 0; i < ${after_tail:-0}; i++)); do val+=$'\n'; done
		fi
		printf -v "$field" '%s' "$val"
	done
	jq -c --arg b "$before" --arg a "$after" --arg h "$headline" \
		'.before = $b | .after = $a | .headline = $h' <<< "$item_json"
}

# desk_before_is_committed <item-json> <before> <repo>: true when the item
# rewrites existing lines (edit, move, merge) and <before> is a run of whole
# lines of the item's file at <repo>'s HEAD.
desk_before_is_committed() {
	local item_json="$1" before="$2" repo="$3" file content
	[ -n "$repo" ] && [ -n "$before" ] || return 1
	jq -e '.kind == "edit" or .kind == "move" or .kind == "merge"' > /dev/null 2>&1 <<< "$item_json" || return 1
	file="$(jq -r '.file // empty' <<< "$item_json")"
	[ -n "$file" ] || return 1
	content="$(git -C "$repo" show "HEAD:$file" 2> /dev/null)" || return 1
	while [[ "$before" == *$'\n' ]]; do before="${before%$'\n'}"; done
	[[ $'\n'"$content"$'\n' == *$'\n'"$before"$'\n'* ]]
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
	grep -qxF -- "$source" <<< "$allowed_urls" 2> /dev/null
}

# Validates `also_sources` (one story arriving from several fetchers: the
# other URLs beside `source`). Each entry must be a string URL present
# verbatim in $2; an invalid one, or one repeating `source` or an earlier
# entry, is dropped rather than the item. Prints the item with a cleaned
# array (absent if the item had none). Counting the drops is
# desk_validate_items's job: this runs in a command substitution, where a
# counter could not reach the caller.
desk_validate_also_sources() {
	local item_json="$1" allowed_urls="$2"
	if ! jq -e 'has("also_sources")' > /dev/null 2>&1 <<< "$item_json"; then
		printf '%s' "$item_json"
		return
	fi
	local source kept="[]" u
	source="$(jq -r '.source // ""' <<< "$item_json")"
	while IFS= read -r u; do
		[ -n "$u" ] || continue
		[ "$u" != "$source" ] || continue
		grep -qxF -- "$u" <<< "$allowed_urls" 2> /dev/null || continue
		jq -e --arg u "$u" 'index($u) != null' > /dev/null 2>&1 <<< "$kept" && continue
		kept="$(jq -c --arg u "$u" '. + [$u]' <<< "$kept")"
	done < <(jq -r 'if (.also_sources | type) == "array" then .also_sources[] | strings else empty end' <<< "$item_json")
	jq -c --argjson k "$kept" 'if ($k | length) > 0 then .also_sources = $k else del(.also_sources) end' <<< "$item_json"
}

# ---------------------------------------------------------------------------
# The full validation pass for a set of proposal-shaped items: drops an item whose URL source isn't verifiably from this call's
# own raw results, then sanitizes every remaining item's text. $2 = the
# allowed-URL set (desk_allowed_urls's output, newline-separated). $3 = the
# notes repo, whose committed files decide which URLs a `before` may lend
# to `after` (desk_sanitize_item_text).
# Caps are a separate step (desk_apply_caps below) since a close call's items
# are never capped, only tiered items are.
# ---------------------------------------------------------------------------
desk_validate_items() {
	local items_json="$1" allowed_urls="$2" repo="${3:-}"
	local n out dropped=0
	out="[]"
	n="$(jq 'length' <<< "$items_json" 2> /dev/null || echo 0)"
	local i
	for ((i = 0; i < n; i++)); do
		local item before_n after_n
		item="$(jq -c ".[$i]" <<< "$items_json")"
		if ! desk_source_allowed "$item" "$allowed_urls"; then
			desk_record_dropped "$item"
			continue
		fi
		before_n="$(jq -r 'if (.also_sources | type) == "array" then (.also_sources | length) elif has("also_sources") then 1 else 0 end' <<< "$item")"
		item="$(desk_validate_also_sources "$item" "$allowed_urls")"
		after_n="$(jq -r '(.also_sources // []) | length' <<< "$item")"
		dropped=$((dropped + before_n - after_n))
		item="$(desk_sanitize_item_text "$item" "$allowed_urls" "$repo")"
		out="$(jq -c --argjson it "$item" '. + [$it]' <<< "$out")"
	done
	[ "$dropped" -eq 0 ] || echo "desk: dropped $dropped invalid also_sources URL(s)" >&2
	DESK_ALSO_SOURCES_DROPPED="$dropped"
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# A close call's own extra check: its turn citations are verified by the
# runner and stripped. The exact format: each bullet ends with "[turn <first 8 chars of a
# transcript entry's uuid>]". An item citing a uuid prefix absent from the
# transcript tail it was actually given is dropped (a fabricated citation
# is worse than none); every citation marker is stripped from before/after
# before an item is kept, valid or not — the marker itself never belongs
# in the user's notes.
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
				grep -qxF -- "$cite" <<< "$valid_prefixes" 2> /dev/null || ok="false"
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
# Caps: per-tier maximums. Only tiered items (news, via `tier`) are ever
# capped; anything else (edits, removals, closure notes) passes straight
# through uncounted.
# ---------------------------------------------------------------------------

# desk_apply_caps <items-json> <caps-json>
# caps-json: {"act": N, "worth_knowing": N, "wildcard": N}. Prints
# {"kept": [...], "overflow": [...]}. The overflow is never a proposal
# item: the runner counts it per tier in the status file and names it in
# the follow-up summary (desk_record_capped), where the user can ask for it.
desk_apply_caps() {
	local items_json="$1" caps_json="$2"
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

	jq -n --argjson kept "$kept" --argjson overflow "$overflow" '{kept: $kept, overflow: $overflow}'
}

# desk_record_capped <overflow-json>: adds a step's capped items to
# $PASS_SCRATCH/capped.json, the follow-up summary's list of them.
desk_record_capped() {
	local file="$PASS_SCRATCH/capped.json" prev
	prev="$(cat "$file" 2> /dev/null)"
	jq -e 'type == "array"' > /dev/null 2>&1 <<< "$prev" || prev='[]'
	jq -c --argjson prev "$prev" '$prev + [.[] | {tier, headline, source, file, kind, after}
		| with_entries(select(.value != null and .value != ""))]' <<< "$1" > "$file.tmp" 2> /dev/null \
		&& mv -f "$file.tmp" "$file"
}

# desk_record_dropped <item-json>: adds an item dropped because its source
# URL was not in the allowed set to $PASS_SCRATCH/dropped.json, which the
# status file counts and the follow-up summary names. Nothing is recorded
# outside a pass.
desk_record_dropped() {
	[ -n "${PASS_SCRATCH:-}" ] || return 0
	local file="$PASS_SCRATCH/dropped.json" prev
	prev="$(cat "$file" 2> /dev/null)"
	jq -e 'type == "array"' > /dev/null 2>&1 <<< "$prev" || prev='[]'
	jq -c --argjson prev "$prev" '$prev + [{headline, source, tier} | with_entries(select(.value != null and .value != ""))]' \
		<<< "$1" > "$file.tmp" 2> /dev/null && mv -f "$file.tmp" "$file"
}

# desk_near_misses <reply-json>: the judge reply's `near_misses`, the
# candidates it judged just below the bar, cleaned: at most five, each
# {headline, why_not} as plain one-line text, anything else dropped.
desk_near_misses() {
	jq -c '
		def clean($n): tostring | gsub("[\u0000-\u001f\u007f]"; " ") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | .[0:$n];
		if type == "object" and (.near_misses | type) == "array" then
			[.near_misses[] | objects | select((.headline | type) == "string" and .headline != "")
			 | {headline: (.headline | clean(120)), why_not: ((.why_not // "") | clean(200))}][0:5]
		else [] end' <<< "$1" 2> /dev/null || echo '[]'
}
