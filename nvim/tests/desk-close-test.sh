#!/usr/bin/env bash
# claude/desk-lib/steps.sh's desk_step_close. Covers the
# away_days safety valve, log_only queuing a "would_close" capture without
# ever signaling, a real close of a throwaway process this test spawns
# itself, an invalid turn citation dropping the capture, and the
# max_closes cap. session-status.sh and session-recorder.sh are both
# faked; the only process ever signaled is one this script starts and
# owns — never a real Claude Code session.
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
export DESK_KILL_GRACE_SECS=3
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

# session-status.sh is looked up bare on PATH (desk_close_candidates); this
# fake reads its candidate list from $SESSION_STATUS_FIXTURE, which each
# case below writes before calling desk_step_close, and re-reads it live
# for the close step's own "just before" re-check.
SESSION_STATUS_FIXTURE="$ROOT/sessions.jsonl"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
cat "$SESSION_STATUS_FIXTURE" 2> /dev/null
FAKE
chmod +x "$FAKEBIN/session-status.sh"

FAKE_CLAUDE_ITEMS_FILE="$ROOT/fake-claude-items.json"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
echo call >> "$FAKE_CLAUDE_CALLS"
cat "$FAKE_CLAUDE_ITEMS_FILE"
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude
FAKE_CLAUDE_CALLS="$ROOT/fake-claude-calls.log"
: > "$FAKE_CLAUDE_CALLS"
export FAKE_CLAUDE_ITEMS_FILE FAKE_CLAUDE_CALLS

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

step_json='{"id":"close","kind":"close","tools":["Read"],"connector":false,"cap":50,"timeout":30}'
config_json_base='{"close_after_working_days": 3, "keep_open": [], "max_closes": 3, "away_days": 5}'

write_items_reply() {
	# $1 = the exact turn-mark to embed (or "" for none)
	local mark="$1"
	jq -cn --arg after "closure notes${mark:+ $mark}" '
		{type:"assistant",message:{content:[{type:"text",text:({items:[{id:"c1",file:"notes.md",kind:"new",target:"top",before:"",after:$after,source:"session:sess-1",headline:"h"}]} | tojson)}]}}
	' > "$FAKE_CLAUDE_ITEMS_FILE"
}

spawn_throwaway() {
	# A harmless sleep this test owns end-to-end — never a real session.
	# stdin/stdout/stderr are all redirected away from /dev/null explicitly:
	# left inherited, the background job would hold this function's own
	# stdout pipe open, and $(spawn_throwaway) (a command substitution)
	# would then block reading it until the 300s sleep actually exits,
	# rather than returning as soon as this function does.
	sleep 300 < /dev/null > /dev/null 2>&1 &
	disown
	echo $!
}

spawn_immortal() {
	# A throwaway process that ignores SIGTERM outright (an ignored
	# disposition survives exec, unlike a caught one) — the one survivor
	# desk_close_session's own grace period never revives, so the close
	# step's own "close-failed" follow-up event actually gets exercised.
	( trap '' TERM; exec sleep 300 ) < /dev/null > /dev/null 2>&1 &
	disown
	echo $!
}

echo "=== a real close: staged, recorded, SIGTERM'd, and confirmed dead ==="
PASS_SCRATCH="$(mktemp -d)"
pid1="$(spawn_throwaway)"
transcript1="$ROOT/transcript1.jsonl"
printf '{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","type":"assistant"}\n' > "$transcript1"
jq -n --argjson pid "$pid1" --arg tp "$transcript1" \
	'{id:"sess-1", name:"a-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:$tp}' \
	> "$SESSION_STATUS_FIXTURE"
write_items_reply "[turn aaaaaaaa]"
no_log_only_config="$(jq -c '. + {log_only: false}' <<< "$config_json_base")"
result="$(desk_step_close "testpass" "$step_json" "$no_log_only_config" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
sleep 1
assert_true "the throwaway process is dead" "$(kill -0 "$pid1" 2> /dev/null && echo false || echo true)"
assert_true "session-recorder was told to close sess-1" "$(grep -q 'close sess-1' "$RECORDER_LOG" && echo true || echo false)"
assert_eq "status.closes was bumped" "1" "$(jq -r '.closes // 0' "$DESK_STATUS_FILE")"
assert_eq "status.closed_names names the closed session" "a-session" "$(jq -r '(.closed_names // []) | join(",")' "$DESK_STATUS_FILE")"
proposal_blob="$(git -C "$repo" show refs/desk/proposal:proposal.json 2> /dev/null)"
# Staging namespaces every item's own model-assigned id (desk_stage_and_
# write_proposal, via cli.lua's namespace-ids), so "c1" survives only as
# an "-c1" suffix on the real, ledger-unique id.
assert_true "the closure note landed in the proposal" \
	"$(jq -e '.items[] | select(.id | endswith("-c1"))' > /dev/null 2>&1 <<< "$proposal_blob" && echo true || echo false)"
assert_true "the turn-citation marker was stripped from the note text" \
	"$(jq -r '.items[] | select(.id | endswith("-c1")) | .after' <<< "$proposal_blob" | grep -q '\[turn' && echo false || echo true)"
assert_true "a real close leaves no note on how the step ran" "$([ ! -s "$PASS_SCRATCH/run-notes.txt" ] && echo true || echo false)"
rm -rf "$PASS_SCRATCH"

echo
echo "=== log_only (default true): queues a would_close capture, never signals ==="
rm -rf "$STATE"
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid2="$(spawn_throwaway)"
jq -n --argjson pid "$pid2" \
	'{id:"sess-2", name:"b-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:""}' \
	> "$SESSION_STATUS_FIXTURE"
write_items_reply ""
log_only_config="$(jq -c '. + {log_only: true}' <<< "$config_json_base")"
result="$(desk_step_close "testpass" "$step_json" "$log_only_config" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "the throwaway process is still alive (never signaled)" "$(kill -0 "$pid2" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never called" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
assert_true "the run status will say the close was only log-only" \
	"$(grep -qF 'ran log-only, so it closed no session: its closure note for 1 session(s) says what it would close, and each session is still open.' "$PASS_SCRATCH/run-notes.txt" 2> /dev/null && echo true || echo false)"
assert_eq "the staged note is marked as a would-close" "would_close" \
	"$(git -C "$repo" show refs/desk/proposal:proposal.json 2> /dev/null | jq -r '[.items[] | select(.session_id == "sess-2") | .capture_kind] | first // empty')"
kill "$pid2" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== log_only: a session already ledgered for its kind costs no second call or note ==="
: > "$FAKE_CLAUDE_CALLS"
PASS_SCRATCH="$(mktemp -d)"
pid2b="$(spawn_throwaway)"
jq -n --argjson pid "$pid2b" \
	'{id:"sess-2", name:"b-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:""}' \
	> "$SESSION_STATUS_FIXTURE"
result="$(desk_step_close "testpass" "$step_json" "$log_only_config" "$repo" "2026-09-29" "${files[@]}")"
assert_eq "the repeat pass reports ok" "ok" "$result"
assert_eq "no model call was made for the already-captured session" "0" "$(wc -l < "$FAKE_CLAUDE_CALLS" | tr -d ' ')"
assert_eq "still exactly one would_close note" "1" "$(git -C "$repo" show refs/desk/proposal:proposal.json | jq '[.items[] | select(.session_id == "sess-2")] | length')"
kill "$pid2b" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== away_days: the first pass after a long gap closes nothing ==="
rm -rf "$STATE"
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
long_ago=$(( $(desk_now) - 20 * 86400 ))
desk_status_set_result "testpass" "ok" "" "[]" "" > /dev/null
# desk_step_close's away-days check reads the last run that finished,
# whatever its result (status.sh's `last_done_run`); every field a real run
# that long ago would have left is backdated here.
jq --argjson t "$long_ago" '.passes.testpass |= (.last_run = $t | .last_ok_run = $t | .last_done_run = $t)' \
	"$DESK_STATUS_FILE" > "$DESK_STATUS_FILE.tmp" && mv "$DESK_STATUS_FILE.tmp" "$DESK_STATUS_FILE"
pid3="$(spawn_throwaway)"
jq -n --argjson pid "$pid3" \
	'{id:"sess-3", name:"c-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:""}' \
	> "$SESSION_STATUS_FIXTURE"
write_items_reply ""
no_log_only_config="$(jq -c '. + {log_only: false}' <<< "$config_json_base")"
result="$(desk_step_close "testpass" "$step_json" "$no_log_only_config" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "nothing was signaled after a long away gap" "$(kill -0 "$pid3" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never called" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
kill "$pid3" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== away_days: passes that finished partial since the last ok one are not an absence ==="
rm -rf "$STATE"
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
desk_status_set_result "testpass" "ok" "" "[]" "" > /dev/null
jq --argjson t "$long_ago" '.passes.testpass |= (.last_run = $t | .last_ok_run = $t)' \
	"$DESK_STATUS_FILE" > "$DESK_STATUS_FILE.tmp" && mv "$DESK_STATUS_FILE.tmp" "$DESK_STATUS_FILE"
desk_status_set_running "testpass" > /dev/null
desk_status_set_result "testpass" "partial" "" '["F-web"]' "" > /dev/null
pid3b="$(spawn_throwaway)"
jq -n --argjson pid "$pid3b" \
	'{id:"sess-3b", name:"d-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:""}' \
	> "$SESSION_STATUS_FIXTURE"
write_items_reply ""
result="$(desk_step_close "testpass" "$step_json" "$no_log_only_config" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "the idle session was closed" "$(grep -q 'close sess-3b' "$RECORDER_LOG" && echo true || echo false)"
kill "$pid3b" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== an invalid turn citation drops the capture entirely ==="
rm -rf "$STATE"
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid4="$(spawn_throwaway)"
transcript4="$ROOT/transcript4.jsonl"
printf '{"uuid":"bbbbbbbb-0000-0000-0000-000000000000","type":"assistant"}\n' > "$transcript4"
jq -n --argjson pid "$pid4" --arg tp "$transcript4" \
	'{id:"sess-4", name:"d-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:$tp}' \
	> "$SESSION_STATUS_FIXTURE"
write_items_reply "[turn fabricate]"
result="$(desk_step_close "testpass" "$step_json" "$no_log_only_config" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step still reports ok" "ok" "$result"
assert_true "the session is never signaled (nothing durable was staged)" "$(kill -0 "$pid4" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never called" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
kill "$pid4" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== a survivor: SIGTERM'd but still alive — counted, and recorded as such ==="
rm -rf "$STATE"
: > "$RECORDER_LOG"
PASS_SCRATCH="$(mktemp -d)"
pid5="$(spawn_immortal)"
transcript5="$ROOT/transcript5.jsonl"
printf '{"uuid":"cccccccc-0000-0000-0000-000000000000","type":"assistant"}\n' > "$transcript5"
jq -n --argjson pid "$pid5" --arg tp "$transcript5" \
	'{id:"sess-5", name:"e-session", live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:$tp}' \
	> "$SESSION_STATUS_FIXTURE"
write_items_reply "[turn cccccccc]"
result="$(desk_step_close "testpass" "$step_json" "$no_log_only_config" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step still reports ok (a survivor is counted, never a step failure)" "ok" "$result"
sleep 1
assert_true "the immortal process is still alive (SIGTERM alone never used SIGKILL)" \
	"$(kill -0 "$pid5" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was told to close sess-5" "$(grep -q 'close sess-5' "$RECORDER_LOG" && echo true || echo false)"
assert_true "session-recorder was also told close-failed sess-5" \
	"$(grep -q 'close-failed sess-5' "$RECORDER_LOG" && echo true || echo false)"
assert_eq "status.failed_closes was bumped" "1" "$(jq -r '.failed_closes // 0' "$DESK_STATUS_FILE")"
assert_eq "status.closes was never bumped for this one" "0" "$(jq -r '.closes // 0' "$DESK_STATUS_FILE")"
kill -KILL "$pid5" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
