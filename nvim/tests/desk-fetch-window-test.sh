#!/usr/bin/env bash
# claude/desk-run's own Gmail/Slack fetch
# window is floored on a dedicated `last_fetch_ok` (claude/desk-lib/
# status.sh), advanced only when a fetch step of THIS pass actually ran
# and none failed — never on `last_ok_run`, which a weekend commit-only
# invocation of a weekdays_only pass (the weekday_only_pass guard skips every
# model-calling step, fetch included, but commit_push still runs and can
# still finish the pass "ok") would otherwise advance too, silently
# narrowing the next weekday's own lookback past mail the weekend itself
# never fetched.
#
# Drives claude/desk-run itself (a fake `claude`, a throwaway notes repo +
# bare remote — same fixture shape as desk-run-test.sh). The weekend skip
# follows the slot's scheduled date, so each pass is pinned to a Wednesday or
# a Saturday slot instead of depending on which day this suite runs.
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

cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
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

repo="$ROOT/notes"
remote="$ROOT/remote.git"
desk_test_assert_repo_under_root "$ROOT" "$ROOT"
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

prompt="$ROOT/prompt.md"
echo "a generic test prompt" > "$prompt"

# One config, two independently-guarded weekdays_only passes, pinned
# to a Wednesday and a Saturday slot, since the weekend skip follows the
# slot's scheduled date, not the date this suite happens to run on, so
# each case below runs its own pass exactly once, never tripping the
# once-a-day guard against the other's own result.
cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg prompt "$prompt" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	push_enabled: false,
	files: ["notes.md", "reading.md"],
	passes: {
		morning: { trigger: { start_calendar_interval: [{ hour: 0, minute: 0, weekday: 3 }] }, steps: [
			{ id: "commit-push", kind: "commit_push" },
			{ id: "F-test", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 }
		] },
		evening: { weekdays_only: true, trigger: { start_calendar_interval: [{ hour: 0, minute: 0, weekday: 6 }] }, steps: [
			{ id: "commit-push", kind: "commit_push" },
			{ id: "F-test", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 }
		] },
		failtest: { steps: [
			{ id: "commit-push", kind: "commit_push" },
			{ id: "F-fail-then", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
			{ id: "J-always-fail", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 }
		] },
		cachehit: { steps: [
			{ id: "commit-push", kind: "commit_push" },
			{ id: "F-private", kind: "fetch", prompt: $prompt, tools: ["mcp__claude_ai_Gmail__search_threads"], connector: true, timeout: 30 },
			{ id: "W", kind: "write", prompt: $prompt, tools: ["mcp__claude_ai_Gmail__unlabel_thread"], connector: true, pinned_label: "UNREAD", timeout: 30 }
		] }
	}
}' > "$cfg"

echo "=== a weekday run: its fetch step ran and succeeded, so last_fetch_ok advances ==="
t0="$(date +%s)"
DESK_CONFIG="$cfg" "$DESK_RUN" morning > "$ROOT/weekday.out" 2>&1
rc=$?
t1="$(date +%s)"
assert_eq "the run succeeds" "0" "$rc"
last_fetch_ok="$(jq -r '.passes.morning.last_fetch_ok // empty' "$DESK_STATUS_FILE")"
assert_true "last_fetch_ok was recorded" "$([ -n "$last_fetch_ok" ] && echo true || echo false)"
assert_true "last_fetch_ok falls within this run's own window (start of run through end)" \
	"$([ "$last_fetch_ok" -ge "$t0" ] && [ "$last_fetch_ok" -le "$t1" ] && echo true || echo false)"

echo
echo "=== a weekend run of a DIFFERENT weekday_only_pass: fetch never ran, last_fetch_ok is never touched ==="
DESK_CONFIG="$cfg" "$DESK_RUN" evening > "$ROOT/weekend.out" 2>&1
rc=$?
assert_eq "the run still succeeds (commit_push alone)" "0" "$rc"
assert_true "the fetch step itself was skipped (weekend, model steps only run weekdays)" \
	"$(grep -q 'F-test.*skipped (weekend' "$ROOT/weekend.out" && echo true || echo false)"
fetch_ok_evening="$(jq -r 'has("passes") and (.passes | has("evening")) and (.passes.evening | has("last_fetch_ok"))' "$DESK_STATUS_FILE")"
assert_eq "evening's own last_fetch_ok field was never even created" "false" "$fetch_ok_evening"
assert_eq "morning's own last_fetch_ok (a different pass) is untouched by evening's run" \
	"$last_fetch_ok" "$(jq -r '.passes.morning.last_fetch_ok' "$DESK_STATUS_FILE")"

echo
echo "=== a later step's own hard failure never advances last_fetch_ok or clears the fetch cache, even though the fetch itself succeeded ==="
DESK_CONFIG="$cfg" "$DESK_RUN" failtest > "$ROOT/failtest.out" 2>&1
rc_failtest=$?
assert_eq "the pass exits non-zero (a later step hard-failed)" "1" "$rc_failtest"
assert_eq "status shows failed" "failed" "$(jq -r '.passes.failtest.result' "$DESK_STATUS_FILE")"
failtest_has_fetch_ok="$(jq -r 'has("passes") and (.passes | has("failtest")) and (.passes.failtest | has("last_fetch_ok"))' "$DESK_STATUS_FILE")"
assert_eq "failtest's own last_fetch_ok was never set" "false" "$failtest_has_fetch_ok"
failtest_scheduled_date="$(date +%F)"
assert_true "the fetch cache for the fetch step that DID succeed is still there (cleared only once the whole pass is ok)" \
	"$([ -f "$STATE/fetch-cache/failtest-$failtest_scheduled_date-F-fail-then/done" ] && echo true || echo false)"

echo
echo "=== a retry that restores a cached fetch uses THAT source's own cached digest_query, never a freshly recomputed one ==="
cachehit_scheduled_date="$(date +%F)"
cache_dir="$STATE/fetch-cache/cachehit-$cachehit_scheduled_date-F-private"
mkdir -p "$cache_dir"
: > "$cache_dir/done"
# Deliberately not JQL/query-shaped at all — a freshly computed digest_query
# (label:"..." after:N before:N) could never coincidentally equal this, so
# W only ever matches it if desk-run actually substituted the CACHED value
# back in for this run, rather than using its own freshly computed one.
printf 'a-fixed-cached-query-never-recomputed' > "$cache_dir/digest_query"
cat > "$cache_dir/F-private-tool-uses.jsonl" << 'JSONL'
{"type":"tool_use","id":"u1","name":"mcp__claude_ai_Gmail__search_threads","input":{"query":"a-fixed-cached-query-never-recomputed"}}
JSONL
cat > "$cache_dir/F-private-tool-results.jsonl" << 'JSONL'
{"type":"tool_result","tool_use_id":"u1","content":[{"type":"text","text":"{\"threads\":[{\"id\":\"cached-thread-1\",\"subject\":\"Cached Digest\"}]}"}]}
JSONL
DESK_CONFIG="$cfg" "$DESK_RUN" cachehit > "$ROOT/cachehit.out" 2>&1
rc_cachehit=$?
assert_eq "the pass exits ok" "0" "$rc_cachehit"
assert_eq "status shows ok" "ok" "$(jq -r '.passes.cachehit.result' "$DESK_STATUS_FILE")"
assert_true "F-private was reused from cache, never re-run" \
	"$(grep -q 'F-private: already fetched today (cached)' "$ROOT/cachehit.out" && echo true || echo false)"
assert_true "W's own match found the cached thread (proving digest_query tracked the cached call, not a fresh one)" \
	"$(grep -q 'would unlabel cached-thread-1' "$ROOT/cachehit.out" && echo true || echo false)"
assert_true "never logged as a query mismatch" \
	"$(grep -q 'digest search query doesn.t match' "$ROOT/cachehit.out" && echo false || echo true)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
