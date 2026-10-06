#!/usr/bin/env bash
# D8 fix test (review item #6): claude/desk-lib/git-ops.sh's push behavior
# — config's own `push_enabled` (default false: commit every day, never
# push), a missing refs/desk/ledger never blocking main's own push — and
# claude/desk-run's own weekday split: commit-and-push runs every day,
# including a weekend, while a weekday-only pass's model steps are
# skipped on one. No live model call; the weekend is decided by the slot's
# scheduled date, so each case pins its pass to a Saturday or a Wednesday slot.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"
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
FETCH_CALLS="$ROOT/fetch-calls.log"
: > "$FETCH_CALLS"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
echo "\$(basename "\$PWD")" >> "$FETCH_CALLS"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{}"}]}}'
echo '{"type":"result","subtype":"success"}'
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

new_notes_repo() {
	local dir="$1"
	local repo="$dir/notes"
	local remote="$dir/remote.git"
	desk_test_assert_repo_under_root "$dir" "$ROOT"
	git init -q --bare "$remote"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name "Desk Test"
	printf 'Section A\n' > "$repo/notes.md"
	: > "$repo/reading.md"
	git -C "$repo" add notes.md reading.md
	git -C "$repo" commit -q -m initial
	git -C "$repo" branch -M main
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -q origin main
	echo "$repo"
}

echo "=== push_enabled default (false): commits every time, never pushes ==="
repo1="$(new_notes_repo "$ROOT/case1")"
cfg1="$ROOT/case1/config.json"
jq -n --arg repo "$repo1" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	passes: { testpass: { steps: [ { id: "commit-push", kind: "commit_push" } ] } }
}' > "$cfg1"
printf 'Section A\n  a local change\n' > "$repo1/notes.md"
remote_head_before="$(git -C "$ROOT/case1/remote.git" rev-parse main)"
DESK_CONFIG="$cfg1" "$DESK_RUN" testpass > "$ROOT/case1.out" 2>&1
rc1=$?
assert_eq "the run still succeeds" "0" "$rc1"
assert_eq "status.push reads disabled (config never turned it on)" "disabled" "$(jq -r '.push' "$DESK_STATUS_FILE")"
assert_true "a real commit still happened locally" \
	"$([ "$(git -C "$repo1" rev-list --count HEAD)" -gt 1 ] && echo true || echo false)"
remote_head_after="$(git -C "$ROOT/case1/remote.git" rev-parse main)"
assert_eq "the remote was never touched" "$remote_head_before" "$remote_head_after"

echo
echo "=== push_enabled: true, but refs/desk/ledger doesn't exist locally: main still pushes ==="
rm -rf "$STATE"
repo2="$(new_notes_repo "$ROOT/case2")"
cfg2="$ROOT/case2/config.json"
jq -n --arg repo "$repo2" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	push_enabled: true,
	files: ["notes.md", "reading.md"],
	passes: { testpass: { steps: [ { id: "commit-push", kind: "commit_push" } ] } }
}' > "$cfg2"
printf 'Section A\n  another local change\n' > "$repo2/notes.md"
assert_true "refs/desk/ledger genuinely doesn't exist yet" \
	"$(git -C "$repo2" show-ref --verify --quiet refs/desk/ledger && echo false || echo true)"
DESK_CONFIG="$cfg2" "$DESK_RUN" testpass > "$ROOT/case2.out" 2>&1
rc2=$?
assert_eq "the run succeeds" "0" "$rc2"
assert_eq "status.push reads ok" "ok" "$(jq -r '.push' "$DESK_STATUS_FILE")"
remote_main="$(git -C "$ROOT/case2/remote.git" rev-parse main)"
local_main="$(git -C "$repo2" rev-parse main)"
assert_eq "the remote's own main now matches the local commit" "$local_main" "$remote_main"

echo
echo "=== weekday-only pass on a weekend: commit_push still runs, the fetch step doesn't ==="
rm -rf "$STATE"
repo3="$(new_notes_repo "$ROOT/case3")"
cfg3="$ROOT/case3/config.json"
prompt="$ROOT/prompt.md"
echo "a generic test prompt" > "$prompt"
jq -n --arg repo "$repo3" --arg prompt "$prompt" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	push_enabled: true,
	files: ["notes.md", "reading.md"],
	passes: { morning: { trigger: { start_calendar_interval: [{ hour: 0, minute: 0, weekday: 6 }] }, steps: [
		{ id: "commit-push", kind: "commit_push" },
		{ id: "F-test", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 }
	] } }
}' > "$cfg3"
printf 'Section A\n  weekend text\n' > "$repo3/notes.md"

DESK_CONFIG="$cfg3" "$DESK_RUN" morning > "$ROOT/case3.out" 2>&1
rc3=$?
assert_eq "the run still succeeds on a weekend" "0" "$rc3"
assert_true "a real commit happened (commit_push ran on the weekend)" \
	"$([ "$(git -C "$repo3" rev-list --count HEAD)" -gt 1 ] && echo true || echo false)"
assert_true "the fetch step never ran (model steps are weekdays-only)" "$([ ! -s "$FETCH_CALLS" ] && echo true || echo false)"
assert_true "the skip is logged" "$(grep -q 'F-test.*skipped (weekend' "$ROOT/case3.out" && echo true || echo false)"

echo
echo "=== the same weekday-only pass on an actual weekday: both steps run ==="
rm -rf "$STATE"
: > "$FETCH_CALLS"
jq '.passes.morning.trigger.start_calendar_interval[0].weekday = 3' "$cfg3" > "$cfg3.wed" && mv "$cfg3.wed" "$cfg3"
printf 'Section A\n  weekday text\n' > "$repo3/notes.md"
DESK_CONFIG="$cfg3" "$DESK_RUN" morning > "$ROOT/case3b.out" 2>&1
rc3b=$?
assert_eq "the run succeeds" "0" "$rc3b"
assert_true "the fetch step ran this time" "$([ -s "$FETCH_CALLS" ] && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
