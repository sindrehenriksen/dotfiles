#!/usr/bin/env bash
# A session's name is the latest custom-title record in its transcript
# (file order; Claude Code re-appends titles in rename order), whether or
# not it was live when the reader first cached the transcript. From-scratch
# fixtures only, never real Claude Code state.
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
live_pid=""
cleanup() {
	[ -n "$live_pid" ] && { kill "$live_pid" 2> /dev/null; wait "$live_pid" 2> /dev/null; }
	rm -rf "$TMP"
}
trap cleanup EXIT

export CLAUDE_CONFIG_DIR="$TMP/config"
export CLAUDE_SESSION_STORE="$TMP/store"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
PROJ="$CLAUDE_CONFIG_DIR/projects/-tmp-fixture"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$PROJ" "$CLAUDE_SESSION_STORE" "$CLAUDE_SESSION_READER_CACHE" "$TMP/bin"
ln -sf /bin/sleep "$TMP/bin/claude"

name_of() { "$READER" | jq -r --arg id "$1" 'select(.id == $id) | .name'; }
older_of() { "$READER" | jq -c --arg id "$1" 'select(.id == $id) | .older_names'; }
title_rec() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$2"; }

start_event() { # sid transcript
	jq -cn --arg sid "$1" --arg cwd "$PROJ" --arg tp "$2" '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
		| "$HERE/../hooks/session-recorder.sh" start
}

echo "=== live under a pid-file name, then stopped ==="
tp="$PROJ/s1.jsonl"
{
	printf '{"type":"ai-title","aiTitle":"Auto Title","sessionId":"s1"}\n'
	printf '{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-10-01T10:00:00.000Z"}\n'
	title_rec "Pid File Name" s1
} > "$tp"
start_event s1 "$tp"
"$TMP/bin/claude" 60 > /dev/null 2>&1 &
live_pid=$!
sleep 0.15
lstart=$(ps -o lstart= -p "$live_pid" | awk '{$1=$1; print}')
if [ -r /proc/stat ]; then
	lepoch=$(date -d "$lstart" +%s); procstart=$(date -u -d "@$lepoch" +"%a %b %d %T %Y")
else
	lepoch=$(date -j -f "%a %b %d %T %Y" "$lstart" +%s); procstart=$(date -u -r "$lepoch" +"%a %b %d %T %Y")
fi
now=$(date +%s)
jq -n --arg pid "$live_pid" --arg sid s1 --arg cwd "$PROJ" --arg ps "$procstart" --argjson u "$((now * 1000))" \
	'{pid:($pid|tonumber), sessionId:$sid, cwd:$cwd, startedAt:$u, procStart:$ps, name:"Pid File Name", nameSource:"user", status:"idle", updatedAt:$u}' \
	> "$CLAUDE_CONFIG_DIR/sessions/$live_pid.json"

assert_eq "live: the name resolves" "Pid File Name" "$(name_of s1)"
rm -f "$CLAUDE_CONFIG_DIR/sessions/$live_pid.json"
kill "$live_pid" 2> /dev/null; wait "$live_pid" 2> /dev/null; live_pid=""
assert_eq "stopped: still the latest custom title, not the ai title" "Pid File Name" "$(name_of s1)"
assert_eq "stopped, read a third time from cache: same" "Pid File Name" "$(name_of s1)"

echo
echo "=== several custom-title records resolve in rename order ==="
tp2="$PROJ/s2.jsonl"
{
	title_rec "First" s2
	printf '{"type":"user","message":{"role":"user","content":"x"},"timestamp":"2026-10-01T10:00:00.000Z"}\n'
	title_rec "Second" s2
	title_rec "Third" s2
} > "$tp2"
start_event s2 "$tp2"
assert_eq "last record wins" "Third" "$(name_of s2)"
assert_eq "earlier titles are the older names, in order" '["First","Second"]' "$(older_of s2)"
title_rec "Fourth" s2 >> "$tp2"
assert_eq "a title appended later (as the file's last line) is picked up" "Fourth" "$(name_of s2)"
printf '%s' "$(title_rec "Fifth" s2)" >> "$tp2"
assert_eq "an unterminated trailing line is not consumed yet" "Fourth" "$(name_of s2)"
printf '\n' >> "$tp2"
assert_eq "once terminated it is" "Fifth" "$(name_of s2)"

echo
echo "=== a cache entry written by an older reader (unchanged, no titles) is rescanned ==="
tp3="$PROJ/s3.jsonl"
{ printf '{"type":"ai-title","aiTitle":"Auto","sessionId":"s3"}\n'; title_rec "Real Name" s3; } > "$tp3"
start_event s3 "$tp3"
if [ -r /proc/stat ]; then sz=$(stat -c %s "$tp3"); mt=$(stat -c %Y "$tp3"); else sz=$(stat -f %z "$tp3"); mt=$(stat -f %m "$tp3"); fi
jq -c --arg p "$tp3" --argjson sz "$sz" --argjson mt "$mt" '. + {($p): {custom_titles: [], ai_title: "Auto", size: $sz, mtime: $mt, offset: 0}}' \
	"$CLAUDE_SESSION_READER_CACHE/transcripts.json" > "$TMP/c.json" && mv "$TMP/c.json" "$CLAUDE_SESSION_READER_CACHE/transcripts.json"
assert_eq "the stale entry does not hide the title" "Real Name" "$(name_of s3)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
