#!/usr/bin/env bash
# D8 fix test (review item #2, first half): claude/desk-run's own judge
# branch treats an unparseable or schema-invalid J reply (not the pinned
# {"items": [...]} shape) as a loud pass failure — before this fix it only
# logged a line and left `result` "ok", so the step after J (W) still ran,
# and the pass was marked done even though nothing was actually staged,
# which meant a retry slot never got another chance at it.
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
WCALL_LOG="$ROOT/w-calls.log"
: > "$WCALL_LOG"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
# Which step this call is for is encoded in its own scratch cwd's name
# (desk_scratch_dir's own "<pass>-<id>-..." label).
cwd="\$(basename "\$PWD")"
case "\$cwd" in
	*-J-*)
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"not valid items json {"}]}}'
		;;
	*-W-*)
		echo "W ran" >> "$WCALL_LOG"
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
	files: ["notes.md", "reading.md"],
	passes: { testpass: { steps: [
		{ id: "J", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "W", kind: "write", prompt: $prompt, tools: ["mcp__claude_ai_Gmail__unlabel_thread"], connector: true, timeout: 30 }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?

assert_true "the pass exits non-zero (a loud failure, not a silent 'ok')" "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_eq "status shows the pass failed" "failed" "$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"
assert_eq "status names J as the step it stopped at" "J" "$(jq -r '.passes.testpass.stopped_at' "$DESK_STATUS_FILE")"
assert_true "W never ran after J's invalid reply" "$([ ! -s "$WCALL_LOG" ] && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
