#!/usr/bin/env bash
# claude/desk-lib/steps.sh's desk_step_close, which only lists: an idle
# session gets close/<id>/ in the run directory with its reader entry and a
# readable copy of its whole transcript, and a line in candidates.json;
# no call is made and nothing is signaled, recorded or staged. A followed
# session is listed like any other, its follow state with it; keep_open,
# the central session, a pass with no brief and the away_days valve each
# keep a session out. session-status.sh, session-recorder.sh and the tab
# helper are faked; the sessions are sleeps this script starts and owns, run
# under the name `claude`, and none may be signaled.
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
unset CLAUDE_CODE_SESSION_ID

# close-session.sh only signals a process named claude, so the throwaway
# sessions run sleep under that name.
PROCBIN="$ROOT/procbin"
mkdir -p "$PROCBIN"
ln -s "$(command -v sleep)" "$PROCBIN/claude"

# The tab helper: `find` names terminal T-<pid>; `close` logs and succeeds.
TAB_LOG="$ROOT/tab.log"
cat > "$FAKEBIN/desk-close-tab-fake.sh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >> "$TAB_LOG"
[ "\$1" = find ] && echo "T-\$3"
exit 0
FAKE
chmod +x "$FAKEBIN/desk-close-tab-fake.sh"
export DESK_CLOSE_TAB_BIN="$FAKEBIN/desk-close-tab-fake.sh"

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
# case below writes before calling desk_step_close.
SESSION_STATUS_FIXTURE="$ROOT/sessions.jsonl"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
# Live as long as the fixture's pid is, as the real reader reports it.
while IFS= read -r line; do
	pid="\$(jq -r '.pid // empty' <<< "\$line")"
	live=false
	[ -n "\$pid" ] && kill -0 "\$pid" 2> /dev/null && live=true
	jq -c --argjson live "\$live" '.live = \$live' <<< "\$line"
done < <(jq -c . "$SESSION_STATUS_FIXTURE" 2> /dev/null)
FAKE
chmod +x "$FAKEBIN/session-status.sh"
# close-session.sh reads sessions through $DESK_READER: the same fake.
export DESK_READER="$FAKEBIN/session-status.sh"

FAKE_CLAUDE_ITEMS_FILE="$ROOT/fake-claude-items.json"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
echo call >> "$FAKE_CLAUDE_CALLS"
# The rendered prompt is the last argument.
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" > "$FAKE_CLAUDE_CALLS.prompt"
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
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

step_json='{"id":"close","kind":"close"}'
CENTRAL=99999999-9999-4999-8999-999999999999
config_json="$(jq -cn --arg c "$CENTRAL" '{close_after_working_days: 3, keep_open: ["kept-session"], away_days: 5,
	central_session: $c, passes: {testpass: {brief: {instructions: ["x.md"]}}}}')"

spawn_throwaway() {
	# Redirected away from the caller's stdout, so $(spawn_throwaway)
	# returns at once rather than when the sleep exits.
	"$PROCBIN/claude" 300 < /dev/null > /dev/null 2>&1 &
	disown
	echo $!
}

# A long transcript, its first entry multi-line, then a long tool result
# and a long user message.
transcript="$ROOT/transcript.jsonl"
{
	printf '{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","type":"user","message":{"role":"user","content":"start the work\\nplease"}}\n'
	long="$(printf 'x%.0s' $(seq 1 5000))"
	printf '{"uuid":"cccccccc-0000-0000-0000-000000000000","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"%s"}]}}\n' "$long"
	printf '{"uuid":"dddddddd-0000-0000-0000-000000000000","type":"user","message":{"role":"user","content":"%s"}}\n' "$long"
	for k in $(seq 1 497); do
		printf '{"uuid":"%08d-0000-0000-0000-000000000000","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"step %d"}]}}\n' "$k" "$k"
	done
} > "$transcript"
session_line() { # <id> <name> <pid>
	jq -cn --arg id "$1" --arg name "$2" --argjson pid "$3" --arg tp "$transcript" \
		'{id:$id, name:$name, live:true, has_start_event:true, last_activity:0, pid:$pid, transcript_path:$tp}'
}
listed() { jq -c "$1" "$DESK_RUNS_ROOT/testpass-$2/close/candidates.json" 2> /dev/null; }

echo "=== an idle session is listed with its transcript, and nothing is done to it ==="
rm -rf "$STATE"
mkdir -p "$STATE"
: > "$RECORDER_LOG"
: > "$FAKE_CLAUDE_CALLS"
PASS_SCRATCH="$(mktemp -d)"
pid1="$(spawn_throwaway)"
pid_kept="$(spawn_throwaway)"
pid_central="$(spawn_throwaway)"
{ session_line 11111111-1111-4111-8111-111111111111 a-session "$pid1"
  session_line 12121212-1212-4121-8121-121212121212 kept-session "$pid_kept"
  session_line "$CENTRAL" central "$pid_central"; } > "$SESSION_STATUS_FIXTURE"
result="$(desk_step_close "testpass" "$config_json" "2026-09-28")"
assert_eq "the step reports ok" "ok" "$result"
sleep 1
assert_true "the session is still alive" "$(kill -0 "$pid1" 2> /dev/null && echo true || echo false)"
assert_true "session-recorder was never called" "$([ ! -s "$RECORDER_LOG" ] && echo true || echo false)"
assert_true "nothing was staged" "$(git -C "$repo" rev-parse -q --verify refs/desk/proposal > /dev/null && echo false || echo true)"
assert_eq "no model call was made" "0" "$(wc -l < "$FAKE_CLAUDE_CALLS" | tr -d ' ')"
assert_eq "only the idle session is listed: not keep_open, not the central session" '["a-session"]' "$(listed '[.[].name]' 2026-09-28)"
dir="$DESK_RUNS_ROOT/testpass-2026-09-28/close/11111111-1111-4111-8111-111111111111"
assert_eq "its line names its directory, line count and idle days" "[\"$dir\",500,true]" \
	"$(listed '[.[0].dir, .[0].transcript_lines, (.[0].idle_working_days >= 3)]' 2026-09-28)"
assert_eq "its directory holds the reader entry" "a-session" "$(jq -r '.name' "$dir/session.json" 2> /dev/null)"
readable="$dir/transcript.txt"
assert_eq "and a readable copy of the whole transcript" "500" "$(wc -l < "$readable" | tr -d ' ')"
assert_eq "its first entry, uuid first, newlines flattened" "aaaaaaaa  user: start the work please" "$(head -n 1 "$readable")"
assert_true "a long tool result is cut, so a read of many lines stays readable" \
	"$(sed -n 2p "$readable" | awk '{ exit !(length < 1000) }' && sed -n 2p "$readable" | grep -q '\[cut\]$' && echo true || echo false)"
assert_true "what the user wrote is kept whole" "$(sed -n 3p "$readable" | awk '{ exit !(length > 5000) }' && echo true || echo false)"
kill "$pid1" 2> /dev/null
result="$(desk_step_close "testpass" "$config_json" "2026-09-28")"
assert_eq "a run again that day starts from a clean list" "[]" "$(listed '.' 2026-09-28)"
assert_true "and the old directory is gone" "$([ ! -d "$dir" ] && echo true || echo false)"
kill "$pid_kept" "$pid_central" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== a followed session is listed like any other, its follow state with it ==="
rm -rf "$STATE"
mkdir -p "$STATE"
PASS_SCRATCH="$(mktemp -d)"
pid2="$(spawn_throwaway)"
pid3="$(spawn_throwaway)"
jq -n '{entries: {
	"22222222-2222-4222-8222-222222222222": {label: "open epic", keys: ["ABC-1"], related: [], added_at: 0},
	"33333333-3333-4333-8333-333333333333": {label: "done epic", keys: ["ABC-2"], related: [], added_at: 0}}}' > "$STATE/follow.json"
jq -n '{all_closed: {"33333333-3333-4333-8333-333333333333": 1791100000}}' > "$STATE/follow-state.json"
{ session_line 22222222-2222-4222-8222-222222222222 followed-open "$pid2"
  session_line 33333333-3333-4333-8333-333333333333 followed-done "$pid3"; } > "$SESSION_STATUS_FIXTURE"
result="$(desk_step_close "testpass" "$config_json" "2026-09-29")"
assert_eq "the step reports ok" "ok" "$result"
assert_eq "both are listed with their follow" '[["followed-open","open epic",null],["followed-done","done epic",1791100000]]' \
	"$(listed '[.[] | [.name, .followed.label, .followed.all_closed_since]]' 2026-09-29)"
assert_eq "the session's own entry carries it too" "1791100000" \
	"$(jq -r '.followed.all_closed_since' "$DESK_RUNS_ROOT/testpass-2026-09-29/close/33333333-3333-4333-8333-333333333333/session.json" 2> /dev/null)"
kill "$pid2" "$pid3" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== a pass with no brief lists nobody ==="
rm -rf "$STATE"
mkdir -p "$STATE"
PASS_SCRATCH="$(mktemp -d)"
pid4="$(spawn_throwaway)"
session_line 44444444-4444-4444-8444-444444444444 d-session "$pid4" > "$SESSION_STATUS_FIXTURE"
result="$(desk_step_close "otherpass" "$config_json" "2026-09-30")"
assert_eq "the step still reports ok" "ok" "$result"
assert_true "and writes no list" "$([ ! -e "$DESK_RUNS_ROOT/otherpass-2026-09-30/close" ] && echo true || echo false)"
kill "$pid4" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== away_days: the first pass after a long gap lists nobody ==="
rm -rf "$STATE"
mkdir -p "$STATE"
PASS_SCRATCH="$(mktemp -d)"
long_ago=$(( $(desk_now) - 20 * 86400 ))
desk_status_set_result "testpass" "ok" "" "[]" "" > /dev/null
jq --argjson t "$long_ago" '.passes.testpass |= (.last_run = $t | .last_ok_run = $t | .last_done_run = $t)' \
	"$DESK_STATUS_FILE" > "$DESK_STATUS_FILE.tmp" && mv -f "$DESK_STATUS_FILE.tmp" "$DESK_STATUS_FILE"
pid5="$(spawn_throwaway)"
session_line 55555555-5555-4555-8555-555555555555 e-session "$pid5" > "$SESSION_STATUS_FIXTURE"
result="$(desk_step_close "testpass" "$config_json" "2026-10-01")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "nothing is listed" "$([ ! -e "$DESK_RUNS_ROOT/testpass-2026-10-01/close/candidates.json" ] && echo true || echo false)"
kill "$pid5" 2> /dev/null
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
