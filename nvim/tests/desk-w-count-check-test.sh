#!/usr/bin/env bash
# D8 fix test (review item #7): claude/desk-run's own post-call check on
# the write (W) step — after a real (non-dry-run) W call, the runner
# compares the thread ids its own tool_use arguments actually named
# against the FULL pinned set (built from F-private's raw results), and
# fails the pass loudly on any mismatch. The deny hook's own --pinned only ever stops W
# from touching something OUTSIDE the pinned set — it can't tell
# "unlabelled all of them" from "unlabelled only some", which is what this
# closes. Same fixture shape as desk-run-morning-integration-test.sh: one
# fake `claude` keyed off its own scratch cwd, no live Gmail call.
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
cwd="$(pwd -P)"
case "$cwd" in
	*-F-private-*)
		# Every scenario but "mismatch" echoes back exactly the
		# digest_query desk-run itself rendered into this call's own
		# prompt (so it's guaranteed to match later) — "mismatch"
		# deliberately answers with some other query instead, standing
		# in for whatever timing/config drift produces a real one live.
		case "$cwd" in
			*/mismatch-*) q="a-deliberately-different-query" ;;
			*) q="$(sed -n 's/^digest_query=//p' prompt.txt)" ;;
		esac
		jq -nc --arg q "$q" '{type:"assistant",message:{content:[{type:"tool_use",id:"u1",name:"mcp__claude_ai_Gmail__search_threads",input:{query:$q}}]}}'
		echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":[{"type":"text","text":"{\"threads\":[{\"id\":\"thread-1\",\"subject\":\"Daily Digest 1\"},{\"id\":\"thread-2\",\"subject\":\"Daily Digest 2\"}]}"}]}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-W-*)
		# Full pins both thread-1 and thread-2; partial pins only thread-1
		# (the mismatch case: the pass name itself carries which).
		case "$cwd" in
			*/full-*) ids='["thread-1","thread-2"]' ;;
			*/partial-*) ids='["thread-1"]' ;;
			*) ids='[]' ;;
		esac
		jq -nc --argjson ids "$ids" '
			$ids[] | {type:"tool_use", id:("u-" + .), name:"mcp__claude_ai_Gmail__unlabel_thread", input:{threadId:., labelIds:["UNREAD"]}}
		' | while IFS= read -r line; do
			printf '{"type":"assistant","message":{"content":[%s]}}\n' "$line"
		done
		echo '{"type":"result","subtype":"success"}'
		;;
	*)
		echo '{"type":"result","subtype":"success"}'
		;;
esac
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
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_LOCK_MAX_WAIT_SECS=2
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

f_private_prompt="$ROOT/f-private-prompt.md"
echo 'digest_query={{digest_query}}' > "$f_private_prompt"
w_prompt="$ROOT/w-prompt.md"
echo "unlabel the pinned threads" > "$w_prompt"

# Two independently-guarded pass names, one per scenario, sharing the same
# steps shape and only differing in what the fake W call actually does
# (read off the pass name itself, above) — dry_run: false, so W really
# calls the model both times.
cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg fpp "$f_private_prompt" --arg wp "$w_prompt" '
def w_steps: {
	steps: [
		{id: "F-private", kind: "fetch", prompt: $fpp, tools: ["mcp__claude_ai_Gmail__search_threads"], connector: true, timeout: 30},
		{id: "W", kind: "write", prompt: $wp, tools: ["mcp__claude_ai_Gmail__unlabel_thread"], connector: true, pinned_label: "UNREAD", timeout: 30}
	]
};
{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	dry_run: false,
	passes: { full: w_steps, partial: w_steps, mismatch: w_steps }
}' > "$cfg"

echo "=== W unlabels every pinned id: the pass succeeds ==="
DESK_CONFIG="$cfg" "$DESK_RUN" full > "$ROOT/full.out" 2>&1
rc_full=$?
assert_eq "the pass exits ok" "0" "$rc_full"
assert_eq "status shows ok" "ok" "$(jq -r '.passes.full.result' "$DESK_STATUS_FILE")"

echo
echo "=== W unlabels only SOME of the pinned ids: the pass fails loudly ==="
DESK_CONFIG="$cfg" "$DESK_RUN" partial > "$ROOT/partial.out" 2>&1
rc_partial=$?
assert_eq "the pass exits non-zero" "1" "$rc_partial"
assert_eq "status shows failed" "failed" "$(jq -r '.passes.partial.result' "$DESK_STATUS_FILE")"
assert_eq "status names W as where it stopped" "W" "$(jq -r '.passes.partial.stopped_at' "$DESK_STATUS_FILE")"
assert_true "the mismatch is named explicitly in the log" \
	"$(grep -q 'W count mismatch' "$ROOT/partial.out" && echo true || echo false)"

echo
echo "=== F-private's own digest query never matches: refused, never treated as \"nothing to unlabel\" ==="
DESK_CONFIG="$cfg" "$DESK_RUN" mismatch > "$ROOT/mismatch.out" 2>&1
rc_mismatch=$?
assert_eq "the pass exits non-zero" "1" "$rc_mismatch"
assert_eq "status shows failed" "failed" "$(jq -r '.passes.mismatch.result' "$DESK_STATUS_FILE")"
assert_eq "status names W as where it stopped" "W" "$(jq -r '.passes.mismatch.stopped_at' "$DESK_STATUS_FILE")"
assert_true "the log says why: the query never matched" \
	"$(grep -q 'the digest query never matched' "$ROOT/mismatch.out" && echo true || echo false)"
assert_true "W's own model call never actually ran (refused before it, not after)" \
	"$(grep -q 'model call: W' "$ROOT/mismatch.out" && echo false || echo true)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
