#!/usr/bin/env bash
# claude/desk-lib/steps.sh's desk_step_close
# re-checks IDLE, not just LIVE, immediately before SIGTERM — a session
# that was idle when the candidate list was built (possibly minutes
# earlier, other candidates' own model calls in between) may be active
# again by the time this one's own capture has staged, and it must never
# be the one that gets signaled just because it was idle earlier. Also
# covers refusing to signal when two live pid files claim the same
# session id on that re-check — never guessing which one is "really" it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_BRIEF_DIR="$STATE/briefs"
export DESK_KILL_GRACE_SECS=2
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"

RECORDER_LOG="$ROOT/recorder-calls.log"
: > "$RECORDER_LOG"
cat > "$FAKEBIN/session-recorder-fake.sh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$RECORDER_LOG"
FAKE
chmod +x "$FAKEBIN/session-recorder-fake.sh"
export DESK_SESSION_RECORDER_BIN="$FAKEBIN/session-recorder-fake.sh"

FAKE_CLAUDE_ITEMS_FILE="$ROOT/fake-claude-items.json"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
cat "$FAKE_CLAUDE_ITEMS_FILE"
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude
export FAKE_CLAUDE_ITEMS_FILE

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
files=(notes.md reading.md)

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"
# shellcheck source=../../claude/desk-lib/git-ops.sh
source "$LIB/git-ops.sh"
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/validate.sh
source "$LIB/validate.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

step_json='{"id":"1630-close","kind":"close","tools":["Read"],"connector":false,"cap":50,"timeout":30}'
config_json='{"close_after_working_days": 3, "keep_open": [], "max_closes": 3, "away_days": 5, "log_only": false}'

write_items_reply() {
	jq -cn --arg after "closure notes [turn aaaaaaaa]" '
		{type:"assistant",message:{content:[{type:"text",text:({items:[{id:"c1",file:"notes.md",kind:"new",target:"top",before:"",after:$after,source:"session:sess-1",headline:"h"}]} | tojson)}]}}
	' > "$FAKE_CLAUDE_ITEMS_FILE"
}

spawn_throwaway() {
	sleep 300 < /dev/null > /dev/null 2>&1 &
	disown
	echo $!
}

echo "=== active again on re-check: idle when listed, active by the time of signaling ==="
PASS_SCRATCH="$(mktemp -d)"
pid1="$(spawn_throwaway)"
transcript1="$ROOT/transcript1.jsonl"
printf '{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","type":"assistant"}\n' > "$transcript1"
# The candidate-list read: idle since epoch 0 (well past the 3-working-day
# threshold). The RE-CHECK read (session-status.sh called a second time)
# reports last_activity = now instead — "the user is using it again right now".
CALL_COUNT_FILE="$ROOT/call-count"
echo 0 > "$CALL_COUNT_FILE"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
n=\$(cat "$CALL_COUNT_FILE")
n=\$((n + 1))
echo "\$n" > "$CALL_COUNT_FILE"
if [ "\$n" -ge 2 ]; then
	jq -nc --argjson pid "$pid1" --arg tp "$transcript1" --argjson now "\$(date +%s)" \
		'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:\$now, pid:\$pid, transcript_path:\$tp}'
else
	jq -nc --argjson pid "$pid1" --arg tp "$transcript1" \
		'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:0, pid:\$pid, transcript_path:\$tp}'
fi
FAKE
chmod +x "$FAKEBIN/session-status.sh"

write_items_reply
result="$(desk_step_close "testpass" "$step_json" "$config_json" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
sleep 1
assert_true "the session was never signaled (active again on re-check)" \
	"$(kill -0 "$pid1" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never told to close it" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
kill "$pid1" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== two pid files sharing a session id on re-check: refused, never guessed ==="
rm -rf "$STATE"
git -C "$repo" update-ref -d refs/desk/proposal 2> /dev/null
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid2="$(spawn_throwaway)"
pid2b="$(spawn_throwaway)"
transcript2="$ROOT/transcript2.jsonl"
printf '{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","type":"assistant"}\n' > "$transcript2"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
jq -nc --argjson pid "$pid2" --arg tp "$transcript2" \
	'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:0, pid:\$pid, transcript_path:\$tp}'
jq -nc --argjson pid "$pid2b" --arg tp "$transcript2" \
	'{id:"sess-1", name:"a-session-dup", live:true, has_start_event:true, last_activity:0, pid:\$pid, transcript_path:\$tp}'
FAKE
chmod +x "$FAKEBIN/session-status.sh"

write_items_reply
close_log="$ROOT/close2.log"
result="$(desk_step_close "testpass" "$step_json" "$config_json" "$repo" "2026-09-28" "${files[@]}" 2> "$close_log")"
assert_eq "the step still reports ok" "ok" "$result"
sleep 1
assert_true "neither process was signaled" \
	"$(kill -0 "$pid2" 2> /dev/null && kill -0 "$pid2b" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never told to close anything" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
assert_true "the collision is named explicitly (2 pid files sharing session id)" \
	"$(grep -q '2 pid files share session id sess-1' "$close_log" && echo true || echo false)"
kill "$pid2" "$pid2b" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== duplicate_pids appears only by re-check time: refused, never guessed ==="
rm -rf "$STATE"
git -C "$repo" update-ref -d refs/desk/proposal 2> /dev/null
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid3="$(spawn_throwaway)"
transcript3="$ROOT/transcript3.jsonl"
printf '{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","type":"assistant"}\n' > "$transcript3"
# The candidate-list read: a clean single entry (so it isn't filtered out
# by desk_close_candidates's own duplicate_pids guard before ever reaching
# the model call). The RE-CHECK read reports duplicate_pids:true instead —
# a second pid file for this same session id showed up in the meantime
# (e.g. the user resumed it themselves between the listing and the SIGTERM).
CALL_COUNT_FILE3="$ROOT/call-count-3"
echo 0 > "$CALL_COUNT_FILE3"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
n=\$(cat "$CALL_COUNT_FILE3")
n=\$((n + 1))
echo "\$n" > "$CALL_COUNT_FILE3"
if [ "\$n" -ge 2 ]; then
	jq -nc --argjson pid "$pid3" --arg tp "$transcript3" \
		'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:0, pid:\$pid, transcript_path:\$tp, duplicate_pids:true}'
else
	jq -nc --argjson pid "$pid3" --arg tp "$transcript3" \
		'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:0, pid:\$pid, transcript_path:\$tp}'
fi
FAKE
chmod +x "$FAKEBIN/session-status.sh"

write_items_reply
close_log3="$ROOT/close3.log"
result="$(desk_step_close "testpass" "$step_json" "$config_json" "$repo" "2026-09-28" "${files[@]}" 2> "$close_log3")"
assert_eq "the step still reports ok" "ok" "$result"
sleep 1
assert_true "the process was never signaled" "$(kill -0 "$pid3" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never told to close it" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
assert_true "the refusal is named explicitly" \
	"$(grep -q 'more than one pid file on re-check' "$close_log3" && echo true || echo false)"
kill "$pid3" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== idle is measured by the user's last human message, not by other activity ==="
status_fake() { # <pid> <last_activity> <last_human_message>
	cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
jq -nc --argjson pid "$1" --arg tp "$ROOT/transcript4.jsonl" --argjson la "$2" --argjson lh "$3" \
	'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:\$la, last_human_message:\$lh, pid:\$pid, transcript_path:\$tp}'
FAKE
	chmod +x "$FAKEBIN/session-status.sh"
}
printf '{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","type":"assistant"}\n' > "$ROOT/transcript4.jsonl"

rm -rf "$STATE"
git -C "$repo" update-ref -d refs/desk/proposal 2> /dev/null
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid4="$(spawn_throwaway)"
status_fake "$pid4" "$(date +%s)" 0
write_items_reply
result="$(desk_step_close "testpass" "$step_json" "$config_json" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
sleep 1
assert_true "recent status updates and tool results do not hold it open: signaled" \
	"$(kill -0 "$pid4" 2> /dev/null && echo false || echo true)"
assert_true "session-recorder was told to close it" "$([ -s "$RECORDER_LOG" ] && echo true || echo false)"
kill "$pid4" 2> /dev/null
rm -rf "$PASS_SCRATCH"

rm -rf "$STATE"
git -C "$repo" update-ref -d refs/desk/proposal 2> /dev/null
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid5="$(spawn_throwaway)"
status_fake "$pid5" 0 "$(date +%s)"
write_items_reply
result="$(desk_step_close "testpass" "$step_json" "$config_json" "$repo" "2026-09-28" "${files[@]}")"
sleep 1
assert_true "a recent human message keeps it open even with old other activity" \
	"$(kill -0 "$pid5" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never told to close it" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
kill "$pid5" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
