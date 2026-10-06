#!/usr/bin/env bash
# last_human_message is the timestamp of the latest transcript record that
# is text he typed: not a tool_result, not meta, not a compaction summary,
# not a task notification or a command/bash/system wrapper. Recent tool
# results, status updates and other activity after an old human message
# must not move it. Falls back to the session's start. From-scratch
# fixtures only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$HERE/../session-status.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/config"
export CLAUDE_SESSION_STORE="$TMP/store"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
PROJ="$CLAUDE_CONFIG_DIR/projects/-tmp-fixture"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$PROJ" "$CLAUDE_SESSION_STORE"
mkdir -p "$CLAUDE_SESSION_READER_CACHE"

field() { "$READER" | jq -r --arg id "$1" "select(.id == \$id) | $2"; }
epoch() { date -u -d "$1" +%s 2> /dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s; }
user_text() { jq -cn --arg t "$1" --arg ts "$2" '{type:"user", message:{role:"user", content:$t}, timestamp:$ts}'; }
user_blocks() { jq -cn --arg t "$1" --arg ts "$2" '{type:"user", message:{role:"user", content:[{type:"text", text:$t}]}, timestamp:$ts}'; }
tool_result() { jq -cn --arg ts "$1" '{type:"user", message:{role:"user", content:[{tool_use_id:"t1", type:"tool_result", content:"ok"}]}, timestamp:$ts}'; }
start_event() {
	jq -cn --arg sid "$1" --arg cwd "$PROJ" --arg tp "$2" '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
		| "$HERE/../hooks/session-recorder.sh" start
}

T_HUMAN=2026-09-28T09:00:00.500Z
T_HUMAN_EPOCH=$(epoch 2026-09-28T09:00:00Z)

echo "=== only a typed message counts; later machine activity does not move it ==="
tp="$PROJ/h1.jsonl"
{
	user_text "an older message" 2026-09-27T09:00:00.000Z
	user_text "$T_HUMAN" "$T_HUMAN" | jq -c '.message.content = "the latest real message"'
	tool_result 2026-10-05T10:00:00.000Z
	user_text "<task-notification>done</task-notification>" 2026-10-05T10:01:00.000Z
	user_text "<local-command-stdout>x</local-command-stdout>" 2026-10-05T10:02:00.000Z
	user_text "<command-name>/compact</command-name>" 2026-10-05T10:03:00.000Z
	user_text "<bash-input>ls</bash-input>" 2026-10-05T10:03:30.000Z
	user_text "[Request interrupted by user]" 2026-10-05T10:03:40.000Z
	user_text "a meta record" 2026-10-05T10:04:00.000Z | jq -c '.isMeta = true'
	user_text "This session is being continued from a previous conversation" 2026-10-05T10:05:00.000Z | jq -c '.isCompactSummary = true'
	user_text "from a task" 2026-10-05T10:06:00.000Z | jq -c '.origin = {kind:"task-notification"}'
	printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"timestamp":"2026-10-05T10:07:00.000Z"}\n'
} > "$tp"
start_event h1 "$tp"
assert_eq "the latest real human message" "$T_HUMAN_EPOCH" "$(field h1 .last_human_message)"
assert_eq "last_activity still tracks the file (mtime), so it is not the idle measure" "true" \
	"$([ "$(field h1 .last_activity)" -gt "$T_HUMAN_EPOCH" ] && echo true || echo false)"

echo
echo "=== a message with content blocks counts, and a later one is picked up incrementally ==="
user_blocks "block message" 2026-10-01T12:00:00.000Z >> "$tp"
assert_eq "block-content message" "$(epoch 2026-10-01T12:00:00Z)" "$(field h1 .last_human_message)"
tool_result 2026-10-06T08:00:00.000Z >> "$tp"
assert_eq "a later tool result does not move it" "$(epoch 2026-10-01T12:00:00Z)" "$(field h1 .last_human_message)"
printf '%s' "$(user_text "unfinished" 2026-10-06T09:00:00.000Z)" >> "$tp"
assert_eq "an unterminated line is left for later" "$(epoch 2026-10-01T12:00:00Z)" "$(field h1 .last_human_message)"
printf '\n' >> "$tp"
assert_eq "once complete it counts" "$(epoch 2026-10-06T09:00:00Z)" "$(field h1 .last_human_message)"

echo
echo "=== no human message at all: falls back to the session's start ==="
tp2="$PROJ/h2.jsonl"
tool_result 2026-10-05T10:00:00.000Z > "$tp2"
start_event h2 "$tp2"
start_ev_time="$(jq -r 'select(.event=="start") | .time' "$CLAUDE_SESSION_STORE/h2.jsonl" | head -1)"
got="$(field h2 .last_human_message)"
assert_eq "a value is still present" "true" "$([ -n "$got" ] && [ "$got" != "null" ] && echo true || echo false)"
echo "     (start event time: $start_ev_time, fallback: $got)"

echo
echo "=== many transcripts at once (batch scan) agree with the per-file scan ==="
for i in 1 2 3 4 5 6 7 8; do
	{ user_text "msg $i" "2026-09-2${i}T09:00:00.000Z"; tool_result 2026-10-05T10:00:00.000Z; } > "$PROJ/b$i.jsonl"
	start_event "b$i" "$PROJ/b$i.jsonl"
done
rm -rf "$CLAUDE_SESSION_READER_CACHE"/*
assert_eq "batch: h1" "$(epoch 2026-10-06T09:00:00Z)" "$(field h1 .last_human_message)"
assert_eq "batch: b3" "$(epoch 2026-09-23T09:00:00Z)" "$(field b3 .last_human_message)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
