#!/usr/bin/env bash
# D8 fix test (review item #3): claude/desk-lib/steps.sh's
# desk_open_follow_up_tab —
#   - a resolved session that's already LIVE is focused by tty (D7's own
#     mechanism) instead of a second `claude --resume` process being
#     opened against it; a failed focus, or no recorded tty, means it
#     skips entirely rather than resuming;
#   - at most one follow-up tab is ever opened (or focus attempted) per
#     (pass, scheduled_date) — a later call for the same pass/date is a
#     no-op, guarded by a stamp file, never a second tab on top of one
#     already opened.
# No live model call, Hammerspoon, or session-status.sh: a fake
# session-status.sh resolves by name from a hand-written fixture, and
# desk-open-tab.sh/desk-focus-tab.sh are both faked to just log their argv.
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

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"

SESSIONS_FIXTURE="$ROOT/sessions-by-name.jsonl"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = "resolve" ]; then
	match="\$(grep -F "\"id\":\"\${2:-}\"" "$SESSIONS_FIXTURE" 2> /dev/null | tail -n1)"
	[ -n "\$match" ] || exit 1
	printf '%s\n' "\$match"
	exit 0
fi
cat "$SESSIONS_FIXTURE" 2> /dev/null
FAKE
chmod +x "$FAKEBIN/session-status.sh"

OPEN_TAB_LOG="$ROOT/open-tab-calls.log"
: > "$OPEN_TAB_LOG"
cat > "$FAKEBIN/desk-open-tab-fake.sh" <<FAKE
#!/usr/bin/env bash
printf 'CMD=%s\nSID=%s\nCWD=%s\n===\n' "\$1" "\${2:-}" "\${3:-}" >> "$OPEN_TAB_LOG"
exit 0
FAKE
chmod +x "$FAKEBIN/desk-open-tab-fake.sh"
export DESK_OPEN_TAB_BIN="$FAKEBIN/desk-open-tab-fake.sh"

FOCUS_TAB_LOG="$ROOT/focus-tab-calls.log"
FOCUS_TAB_RESULT_FILE="$ROOT/focus-result"
echo "0" > "$FOCUS_TAB_RESULT_FILE"
: > "$FOCUS_TAB_LOG"
cat > "$FAKEBIN/desk-focus-tab-fake.sh" <<FAKE
#!/usr/bin/env bash
printf 'TTY=%s\n===\n' "\$1" >> "$FOCUS_TAB_LOG"
exit "\$(cat "$FOCUS_TAB_RESULT_FILE")"
FAKE
chmod +x "$FAKEBIN/desk-focus-tab-fake.sh"
export DESK_FOCUS_TAB_BIN="$FAKEBIN/desk-focus-tab-fake.sh"

export PATH="$FAKEBIN:$PATH"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

scheduled_date="2026-09-28"
run_dir="$DESK_RUNS_ROOT/testpass-$scheduled_date/J"
mkdir -p "$run_dir"
echo sess-live-1 > "$run_dir.session-id"

echo "=== a live resolved session: focused by tty, never a second process ==="
jq -cn --arg name "desk-testpass-$scheduled_date-J" '
	{name:$name, id:"sess-live-1", cwd:"/some/cwd", last_activity:1, live:true, tty:"ttys004"}
' > "$SESSIONS_FIXTURE"
result="$(desk_open_follow_up_tab testpass "$scheduled_date" J)"
assert_eq "reports ok" "ok" "$result"
assert_eq "the open-tab helper was never invoked" "0" "$(grep -c '^CMD=' "$OPEN_TAB_LOG" 2> /dev/null)"
assert_eq "the focus helper was invoked exactly once, with the session's own tty" \
	"TTY=ttys004" "$(grep '^TTY=' "$FOCUS_TAB_LOG")"
assert_true "the guard stamp was written (focusing counts as 'opened')" \
	"$([ -f "$DESK_GUARD_DIR/followup-testpass-$scheduled_date" ] && echo true || echo false)"

echo
echo "=== a later call for the SAME pass/date: guarded, no second tab or focus attempt ==="
: > "$FOCUS_TAB_LOG"
: > "$OPEN_TAB_LOG"
result="$(desk_open_follow_up_tab testpass "$scheduled_date" J)"
assert_eq "still reports ok" "ok" "$result"
assert_eq "focus was never attempted again" "0" "$(wc -l < "$FOCUS_TAB_LOG" | tr -d ' ')"
assert_eq "open-tab was never attempted either" "0" "$(grep -c '^CMD=' "$OPEN_TAB_LOG" 2> /dev/null)"

echo
echo "=== a live session with no recorded tty: skips entirely, never resumes ==="
rm -rf "$DESK_GUARD_DIR"
mkdir -p "$DESK_GUARD_DIR"
jq -cn --arg name "desk-testpass2-$scheduled_date-J" '
	{name:$name, id:"sess-live-2", cwd:"/some/cwd", last_activity:1, live:true, tty:null}
' > "$SESSIONS_FIXTURE"
run_dir2="$DESK_RUNS_ROOT/testpass2-$scheduled_date/J"
mkdir -p "$run_dir2"
echo sess-live-2 > "$run_dir2.session-id"
: > "$FOCUS_TAB_LOG"
: > "$OPEN_TAB_LOG"
result="$(desk_open_follow_up_tab testpass2 "$scheduled_date" J)"
assert_eq "reports ok (not an error — just nothing safe to do)" "ok" "$result"
assert_eq "focus was never attempted (no tty to focus)" "0" "$(wc -l < "$FOCUS_TAB_LOG" | tr -d ' ')"
assert_eq "open-tab (resume) was never attempted either" "0" "$(grep -c '^CMD=' "$OPEN_TAB_LOG" 2> /dev/null)"
assert_true "no guard stamp: nothing was actually opened, so a later retry may still try" \
	"$([ ! -f "$DESK_GUARD_DIR/followup-testpass2-$scheduled_date" ] && echo true || echo false)"

echo
echo "=== a live session whose focus attempt itself fails: skips, never resumes ==="
jq -cn --arg name "desk-testpass3-$scheduled_date-J" '
	{name:$name, id:"sess-live-3", cwd:"/some/cwd", last_activity:1, live:true, tty:"ttys009"}
' > "$SESSIONS_FIXTURE"
run_dir3="$DESK_RUNS_ROOT/testpass3-$scheduled_date/J"
mkdir -p "$run_dir3"
echo sess-live-3 > "$run_dir3.session-id"
echo "1" > "$FOCUS_TAB_RESULT_FILE"
: > "$FOCUS_TAB_LOG"
: > "$OPEN_TAB_LOG"
result="$(desk_open_follow_up_tab testpass3 "$scheduled_date" J)"
assert_eq "reports ok (a failed focus is never a step failure)" "ok" "$result"
assert_eq "the focus helper was invoked" "TTY=ttys009" "$(grep '^TTY=' "$FOCUS_TAB_LOG")"
assert_eq "open-tab (resume) was never attempted (would risk a second process)" \
	"0" "$(grep -c '^CMD=' "$OPEN_TAB_LOG" 2> /dev/null)"
assert_true "no guard stamp: focusing failed, so a later retry may still try" \
	"$([ ! -f "$DESK_GUARD_DIR/followup-testpass3-$scheduled_date" ] && echo true || echo false)"
echo "0" > "$FOCUS_TAB_RESULT_FILE"

echo
echo "=== a NOT-live resolved session: opens a fresh resume tab as before, and stamps the guard ==="
jq -cn --arg name "desk-testpass4-$scheduled_date-J" '
	{name:$name, id:"sess-not-live", cwd:"/some/other/cwd", last_activity:1, live:false}
' > "$SESSIONS_FIXTURE"
run_dir4="$DESK_RUNS_ROOT/testpass4-$scheduled_date/J"
mkdir -p "$run_dir4"
echo sess-not-live > "$run_dir4.session-id"
: > "$FOCUS_TAB_LOG"
: > "$OPEN_TAB_LOG"
result="$(desk_open_follow_up_tab testpass4 "$scheduled_date" J)"
assert_eq "reports ok" "ok" "$result"
assert_eq "focus was never attempted (not live)" "0" "$(wc -l < "$FOCUS_TAB_LOG" | tr -d ' ')"
assert_true "open-tab (resume) was invoked" "$(grep -q "CMD=claude --resume 'sess-not-live'" "$OPEN_TAB_LOG" && echo true || echo false)"
assert_true "the guard stamp was written" \
	"$([ -f "$DESK_GUARD_DIR/followup-testpass4-$scheduled_date" ] && echo true || echo false)"

echo
echo "=== a session that merely shares the display name is never opened ==="
rm -rf "$DESK_GUARD_DIR"
mkdir -p "$DESK_GUARD_DIR"
run_dir5="$DESK_RUNS_ROOT/testpass5-$scheduled_date/J"
mkdir -p "$run_dir5"
echo sess-ours > "$run_dir5.session-id"
jq -cn --arg name "desk-testpass5-$scheduled_date-J" '
	{name:$name, id:"sess-stranger", cwd:"/stranger/cwd", last_activity:9, live:false}
' > "$SESSIONS_FIXTURE"
: > "$OPEN_TAB_LOG"
result="$(desk_open_follow_up_tab testpass5 "$scheduled_date" J)"
assert_eq "reports ok (nothing of ours to open)" "ok" "$result"
assert_eq "no tab was opened for the same-named stranger" "0" "$(grep -c '^CMD=' "$OPEN_TAB_LOG" 2> /dev/null)"
jq -cn --arg name "desk-testpass5-$scheduled_date-J" '
	{name:$name, id:"sess-ours", cwd:"/our/cwd", last_activity:1, live:false}
' >> "$SESSIONS_FIXTURE"
result="$(desk_open_follow_up_tab testpass5 "$scheduled_date" J)"
assert_true "the session whose id the runner generated is the one opened" \
	"$(grep -q "CMD=claude --resume 'sess-ours'" "$OPEN_TAB_LOG" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
