#!/usr/bin/env bash
# Run from one work seat, the reader lists the sessions of every seat: one
# entry per session, live over not live, each naming the config dir it is on,
# and `resolve` finds a name on the other seat. From-scratch fixtures only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"
READER="$HERE/../session-status.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

TMP=$(mktemp -d)
live_pid=""
cleanup() {
	[ -n "$live_pid" ] && { kill "$live_pid" 2> /dev/null; wait "$live_pid" 2> /dev/null; }
	rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
S1="$HOME/.claude-work"
S2="$HOME/.claude-work-2"
export CLAUDE_SESSION_STORE="$TMP/store"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
mkdir -p "$S1/sessions" "$S2/sessions" "$S1/projects/-p" "$S2/projects/-p" "$CLAUDE_SESSION_STORE" "$TMP/bin" "$HOME/.claude/projects"

A=aaaaaaaa-0000-4000-8000-000000000001 # live on seat 2, named
B=bbbbbbbb-0000-4000-8000-000000000002 # stopped, transcript on seat 2
C=cccccccc-0000-4000-8000-000000000003 # stopped, transcript on seat 1
title() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$2"; }
start_event() { # sid transcript
	jq -cn --arg sid "$1" --arg cwd /tmp --arg tp "$2" '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
		| "$HERE/../hooks/session-recorder.sh" start
}
title "On Seat Two" $A > "$S2/projects/-p/$A.jsonl"
title "Stopped Two" $B > "$S2/projects/-p/$B.jsonl"
title "Stopped One" $C > "$S1/projects/-p/$C.jsonl"
start_event $A "$S2/projects/-p/$A.jsonl"
start_event $B "$S2/projects/-p/$B.jsonl"
start_event $C "$S1/projects/-p/$C.jsonl"

start_claude_stand_in "$TMP/bin" 60
live_pid=$!
now=$(date +%s)
jq -n --arg pid "$live_pid" --arg sid $A --arg ps "$(proc_start_of "$live_pid")" --argjson u "$((now * 1000))" \
	'{pid:($pid|tonumber), sessionId:$sid, cwd:"/tmp", startedAt:$u, procStart:$ps, name:"On Seat Two", nameSource:"user", status:"idle", updatedAt:$u}' \
	> "$S2/sessions/$live_pid.json"

field() { jq -r --arg id "$2" 'select(.id == $id) | .'"$3" <<< "$1"; }

for from in "$S1" "$S2"; do
	echo "=== read from ${from##*/} ==="
	out=$(CLAUDE_CONFIG_DIR="$from" "$READER")
	assert_eq "one entry per session" "3" "$(jq -s 'length' <<< "$out")"
	assert_eq "the session live on seat 2 is live and named" "true On Seat Two $S2" \
		"$(field "$out" $A live) $(field "$out" $A name) $(field "$out" $A config_dir)"
	assert_eq "a stopped session on seat 2 names it" "$S2 Stopped Two" "$(field "$out" $B config_dir) $(field "$out" $B name)"
	assert_eq "a stopped session on seat 1 names it" "$S1 Stopped One" "$(field "$out" $C config_dir) $(field "$out" $C name)"
	assert_eq "no merge field leaks out" "0" "$(jq -s '[.[] | keys[] | select(startswith("_"))] | length' <<< "$out")"
	assert_eq "resolve by name finds the other seat's session" "$A" "$(CLAUDE_CONFIG_DIR="$from" "$READER" resolve "On Seat Two" | jq -r .id)"
done

echo "=== the personal dir stays alone ==="
assert_eq "no work seat's session is listed" "0" "$(CLAUDE_CONFIG_DIR="$HOME/.claude" "$READER" | jq -s 'map(select(.id == "'$A'")) | length')"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
