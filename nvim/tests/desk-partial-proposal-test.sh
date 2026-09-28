#!/usr/bin/env bash
# D8 fix test (review item #3): a fetch (source) step's own failure never
# aborts the pass — desk-run's own step loop records it in failed_sources
# and keeps going, J still runs and stages whatever it can (the pass
# result reads "partial", not "failed" or "ok"), the day is never marked
# done for that source (a later slot retries it), and a source that
# already succeeded is never redundantly re-run on that retry
# (steps.sh's own desk_fetch_cache_*). Exercised through desk-run itself,
# against from-scratch fixtures — no live model call.
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
FAIL_A_MARKER="$ROOT/fail-a"
B_CALLS="$ROOT/b-calls.log"
J_CALLS="$ROOT/j-calls.log"
: > "$FAIL_A_MARKER" # present = F-A fails this invocation
: > "$B_CALLS"
: > "$J_CALLS"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
cwd="\$(basename "\$PWD")"
case "\$cwd" in
	*-F-A-*)
		if [ -f "$FAIL_A_MARKER" ]; then
			echo "F-A failing" >&2
			exit 1
		fi
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{}"}]}}'
		;;
	*-F-B-*)
		echo "F-B ran" >> "$B_CALLS"
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{}"}]}}'
		;;
	*-J-*)
		echo "J ran" >> "$J_CALLS"
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"items\":[]}"}]}}'
		;;
esac
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
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n  detail\n' > "$repo/notes.md"
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
	passes: { testpass: { steps: [
		{ id: "F-A", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "F-B", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "J", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 }
	] } }
}' > "$cfg"

echo "=== first slot: F-A fails, F-B succeeds — the pass keeps going ==="
DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run1.out" 2>&1
rc1=$?
assert_eq "desk-run itself doesn't error out over a source failure" "0" "$rc1"
assert_eq "status reads partial, not failed" "partial" "$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"
assert_eq "F-A is the recorded failed source" '["F-A"]' "$(jq -c '.passes.testpass.failed_sources' "$DESK_STATUS_FILE")"
assert_true "J still ran despite F-A's failure" "$([ -s "$J_CALLS" ] && echo true || echo false)"
assert_true "F-B ran (and succeeded)" "$([ "$(wc -l < "$B_CALLS" | tr -d ' ')" = "1" ] && echo true || echo false)"

echo
echo "=== second slot (same day): F-A retried, F-B never re-run (cached) ==="
: > "$FAIL_A_MARKER" # will be emptied (not removed) just below to let F-A succeed
rm -f "$FAIL_A_MARKER"
: > "$J_CALLS"
DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run2.out" 2>&1
rc2=$?
assert_eq "the retry succeeds fully now" "0" "$rc2"
assert_eq "status reads ok now that every source succeeded" "ok" "$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"
assert_eq "failed_sources is empty" "[]" "$(jq -c '.passes.testpass.failed_sources' "$DESK_STATUS_FILE")"
assert_true "F-B was never re-invoked (still exactly one call, from the first slot)" \
	"$([ "$(wc -l < "$B_CALLS" | tr -d ' ')" = "1" ] && echo true || echo false)"
assert_true "J ran again on the retry" "$([ -s "$J_CALLS" ] && echo true || echo false)"
assert_true "the fetch cache is cleared once nothing is left to retry" \
	"$([ -z "$(find "$DESK_FETCH_CACHE_ROOT" -mindepth 1 2> /dev/null)" ] && echo true || echo false)"

echo
echo "=== W refuses to unlabel when F-private (its own source) failed this pass ==="
rm -rf "$STATE"
: > "$FAIL_A_MARKER" # reuse as "F-private fails" for this config's own step
cfg2="$ROOT/config2.json"
jq -n --arg repo "$repo" --arg prompt "$prompt" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	digest_gmail_label: "Digest",
	passes: { testpass: { steps: [
		{ id: "F-A", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "W", kind: "write", prompt: $prompt, tools: ["mcp__claude_ai_Gmail__unlabel_thread"], connector: true, timeout: 30 }
	] } }
}' > "$cfg2"
# Rename the fake claude's own F-private branch onto F-A for this config
# (desk-run's own W logic reads specifically "F-private"'s own tool-uses/
# results — this test's fake F-A step stands in for it by id only; the
# refusal check below is about F-private specifically, so point the
# config's fetch step at that id instead).
cfg3="$ROOT/config3.json"
jq '.passes.testpass.steps[0].id = "F-private"' "$cfg2" > "$cfg3"
sed -i.bak 's/\*-F-A-\*/*-F-private-*/' "$FAKEBIN/claude" && rm -f "$FAKEBIN/claude.bak"
DESK_CONFIG="$cfg3" "$DESK_RUN" testpass > "$ROOT/run3.out" 2>&1
rc3=$?
assert_true "the pass exits non-zero (W's refusal is a hard failure)" "$([ "$rc3" -ne 0 ] && echo true || echo false)"
assert_true "W's own refusal is logged" "$(grep -q 'F-private.*failed this pass' "$ROOT/run3.out" && echo true || echo false)"
assert_eq "W itself is recorded as the step that failed the pass" "W" "$(jq -r '.passes.testpass.stopped_at' "$DESK_STATUS_FILE")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
