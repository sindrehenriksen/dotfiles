#!/usr/bin/env bash
# The session queue: messages for a Claude Code session that wait on disk
# until a turn starts there, instead of starting one (docs/desk.md, "The
# session queue"). Sourced by claude/desk-queue, the follow pass and
# claude/hooks/session-queue.sh, which runs on every prompt: nothing here
# may depend on common.sh or do work when sourced.
#
#   $DESK_QUEUE_DIR/<session id>/<id>.json   one waiting message:
#                                            {from, from_session, at, text}
#   $DESK_QUEUE_DIR/.delivered/<session id>/ each delivery as the session
#                                            was shown it, kept a week
#
# A message's id is its file's name, which starts with the second it was
# queued, so a directory listing is oldest first.

DESK_QUEUE_DIR="${DESK_QUEUE_DIR:-$HOME/.local/state/claude/session-queue}"
DESK_QUEUE_MARKER="[session-queue]"

# desk_queue_put <session id> <from> <from session id or ""> <text file>
# Prints the new message's id.
desk_queue_put() {
	local sid="$1" from="$2" from_sid="$3" file="$4" dir id tmp
	dir="$DESK_QUEUE_DIR/$sid"
	mkdir -p "$dir" 2> /dev/null || return 1
	id="${DESK_NOW:-$(date +%s)}-$$-$RANDOM"
	# Dotted, so a reader never takes a half-written file for a message.
	tmp="$dir/.tmp.$id"
	if jq -n --arg from "$from" --arg sid "$from_sid" --rawfile text "$file" --argjson at "${id%%-*}" \
		'{from: ($from | gsub("[\\r\\n\\t]+"; " ") | .[0:80]), from_session: (if $sid == "" then null else $sid end), at: $at, text: $text}' \
		> "$tmp" 2> /dev/null && mv -f "$tmp" "$dir/$id.json"; then
		printf '%s\n' "$id"
	else
		rm -f "$tmp"
		return 1
	fi
}

# desk_queue_files <session id>: the waiting messages' paths, oldest first.
desk_queue_files() {
	local f
	for f in "$DESK_QUEUE_DIR/$1"/*.json; do
		[ -f "$f" ] && printf '%s\n' "$f"
	done
	return 0
}

desk_queue_count() {
	desk_queue_files "$1" | wc -l | tr -d ' '
}

# desk_queue_has_from <session id> <from>: whether a message from that
# sender waits there.
desk_queue_has_from() {
	local f
	while IFS= read -r f; do
		jq -e --arg f "$2" '.from == $f' "$f" > /dev/null 2>&1 && return 0
	done < <(desk_queue_files "$1")
	return 1
}

# desk_queue_render <token> <message file>...: the messages as a session is
# shown them, each between two lines carrying <token>, which the text
# around them names: a message cannot end its own quotation without it.
desk_queue_render() {
	local token="$1"
	shift
	jq -rn --arg k "$token" '
		[inputs] | length as $n | to_entries[]
		| (.key + 1) as $i | .value
		| "--- queued message \($i) of \($n) [\($k)], from \(.from | gsub("[\\r\\n\\t]+"; " ") | .[0:80]), queued \(.at | strflocaltime("%a %d %b %H:%M")) ---\n"
		  + (.text | sub("\\s+$"; "")) + "\n--- end of queued message \($i) [\($k)] ---\n"' "$@"
}
