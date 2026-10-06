#!/usr/bin/env bash
# a single lock shared across every pass
# (claude/desk-lib/lock.sh's own DESK_LOCK_NAME), taken before the once-
# a-day guard check and before any status.json write. Before this fix the
# lock was keyed per pass name, so "morning" and "1630" — invoked
# concurrently, as their own launchd slots genuinely can be — never
# contended for the same lock at all and could run at once against the
# same notes repo/ledger/status.json. This drives desk-run itself, twice,
# overlapping in time, and checks the second literally never starts its
# own model call until the first's has finished.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"

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
LOG="$ROOT/timeline.log"
: > "$LOG"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
cwd="\$(basename "\$PWD")"
echo "\$cwd start \$(date +%s)" >> "$LOG"
case "\$cwd" in
	morning-*) sleep 3 ;;
esac
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{}"}]}}'
echo '{"type":"result","subtype":"success"}'
echo "\$cwd end \$(date +%s)" >> "$LOG"
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_FETCH_CACHE_ROOT="$STATE/fetch-cache"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_LOCK_MAX_WAIT_SECS=15
export DESK_LOCK_POLL_SECS=1

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
git -C "$repo" branch -M main
desk_test_assert_repo_under_root "$ROOT/remote.git" "$ROOT"
git init -q --bare "$ROOT/remote.git"
git -C "$repo" remote add origin "$ROOT/remote.git"
git -C "$repo" push -q origin main

prompt="$ROOT/prompt.md"
echo "a generic test prompt" > "$prompt"
cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg prompt "$prompt" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	passes: {
		morning: { steps: [ { id: "F", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 } ] },
		"1630": { steps: [ { id: "F", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 } ] }
	}
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" morning > "$ROOT/morning.out" 2>&1 &
morning_bg=$!
# Give "morning" a head start so it's the one holding the lock when
# "1630" tries to acquire it — not a race between the two.
sleep 1
DESK_CONFIG="$cfg" "$DESK_RUN" 1630 > "$ROOT/1630.out" 2>&1
rc_1630=$?
wait "$morning_bg"
rc_morning=$?

assert_eq "morning succeeds" "0" "$rc_morning"
assert_eq "1630 succeeds (waited, never raced)" "0" "$rc_1630"

morning_end="$(grep -m1 '^morning-F-.* end ' "$LOG" | awk '{print $3}')"
sixteen_start="$(grep -m1 '^1630-F-.* start ' "$LOG" | awk '{print $3}')"
assert_true "morning's own call recorded an end time" "$([ -n "$morning_end" ] && echo true || echo false)"
assert_true "1630's own call recorded a start time" "$([ -n "$sixteen_start" ] && echo true || echo false)"
assert_true "1630's call never started before morning's finished (serialized, not concurrent)" \
	"$([ "$sixteen_start" -ge "$morning_end" ] && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
