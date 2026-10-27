#!/usr/bin/env bash
# Cleaning the items desk-propose stages: control and ANSI characters, vim
# modelines and the agent mark stripped from their text, and the check that
# an item's quoted `at` line can stand.
set -u

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

# Strips the agent mark (steps.sh's DESK_AGENT_MARK, which a seeded copy of
# the notes puts on taken lines) from $1, so a line quoted from such a copy
# never brings it into the user's file.
desk_strip_agent_marks() {
	local text="$1"
	printf '%s' "${text//${DESK_AGENT_MARK:-  <<agent-suggested>>}/}"
}

# One item's text cleaned: the agent mark stripped from `before` (which
# must keep matching the user's file, so nothing else), and from `after` and
# the headline the agent mark, modelines and control characters. A blank
# line `after` ends with is kept, since it can be the point of an item
# (desk.apply fits it to where it lands); a lone final newline only ends
# the text.
desk_sanitize_item_text() {
	local item_json="$1"
	local before after headline after_tail field val
	before="$(jq -r '.before // ""' <<< "$item_json")"
	after="$(jq -r '.after // ""' <<< "$item_json")"
	after_tail="$(jq -r '.after // "" | if test("[^\n]") then (capture("(?<t>\n*)$").t | length) else 0 end' <<< "$item_json")"
	headline="$(jq -r '.headline // ""' <<< "$item_json")"
	before="$(desk_strip_agent_marks "$before")"
	for field in after headline; do
		val="${!field}"
		val="$(desk_strip_agent_marks "$val")"
		val="$(desk_strip_modelines <<< "$val")"
		val="$(desk_strip_control_chars <<< "$val")"
		if [ "$field" = after ] && [ "${after_tail:-0}" -ge 2 ]; then
			local i
			for ((i = 0; i < ${after_tail:-0}; i++)); do val+=$'\n'; done
		fi
		printf -v "$field" '%s' "$val"
	done
	# A quoted anchor line copied from a marked copy carries the mark too,
	# and would then match no line of the user's file.
	jq -c --arg b "$before" --arg a "$after" --arg h "$headline" --arg mark "${DESK_AGENT_MARK:-  <<agent-suggested>>}" '
		.before = $b | .after = $a | .headline = $h
		| if has("target") then .target |= walk(if type == "string" then split($mark) | join("") else . end) else . end
	' <<< "$item_json"
}

# desk_item_at_problem <item-json>: why the item's quoted `at` line (an
# edit's or removal's target, a move's or merge's first) cannot stand, or
# nothing when it can or there is none. A quoted line is matched as a whole
# line of the notes, so it must be at least three characters, and it must be
# the first line of `before`, since that is where the lines it names start.
desk_item_at_problem() {
	# Compared as desk_line_key compares (common.sh): the mark at the end of
	# the line gone with the whitespace before it, and trailing whitespace
	# trimmed.
	jq -r --arg mark "${DESK_AGENT_MARK:-  <<agent-suggested>>}" '
		($mark | sub("^\\s+"; "")) as $m
		| def unmark: split("\n") | map(
			(rindex($m)) as $i
			| (if $i != null and (.[($i + ($m | length)):] | test("^\\s*$")) then .[:$i] else . end)
			| sub("\\s+$"; "")) | join("\n");
		(.target | if type == "array" then .[0] else . end | if type == "object" then .at else null end) as $at
		| if $at == null then empty
		  elif ($at | type) != "string" then "its at must be a line of text"
		  else ($at | unmark) as $a
		  | ((.before // "") | if type == "string" then . else "" end | unmark | split("\n") | .[0] // "") as $first
		  | if ($a | length) < 3 then "its at line \($a | tojson) is shorter than three characters"
		    elif $a != $first then "its at line \($a | tojson) is not the first line of before (\($first | tojson))"
		    else empty end
		  end' <<< "$1" 2> /dev/null
}
