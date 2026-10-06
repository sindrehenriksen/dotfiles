#!/usr/bin/env bash
# D8b test: the write step's pinned-args deny hook. Two layers:
# deny-unlisted-tool.sh itself, exercised directly with crafted PreToolUse
# JSON on stdin (its actual enforcement, not a simulation of it); and
# desk_step_write/desk_step_model_call, checked to actually build the
# pinned-args file the hook reads, via a fake `claude` that copies its own
# scratch cwd's settings/pinned files out before desk-run cleans them up.
# No live model call anywhere.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"
HOOK="$LIB/deny-unlisted-tool.sh"

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

echo "=== deny-unlisted-tool.sh: tool name alone (no --pinned) ==="
out="$(echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"t1","labelIds":["UNREAD"]}}' \
	| "$HOOK" mcp__claude_ai_Gmail__unlabel_thread)"
rc=$?
assert_eq "an allowed tool name with no pinned file: allowed" "0" "$rc"

out2_rc=0
echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' | "$HOOK" mcp__claude_ai_Gmail__unlabel_thread > /dev/null 2>&1 || out2_rc=$?
assert_eq "an unlisted tool name: denied" "2" "$out2_rc"

echo
echo "=== deny-unlisted-tool.sh: --pinned enforces exact tool_input too ==="
pinned_file="$ROOT/pinned.json"
jq -n '[{threadId: "t1", labelIds: ["UNREAD"]}, {threadId: "t2", labelIds: ["UNREAD"]}]' > "$pinned_file"

rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"t1","labelIds":["UNREAD"]}}' \
	| "$HOOK" --pinned "$pinned_file" -- mcp__claude_ai_Gmail__unlabel_thread > /dev/null 2>&1 || rc=$?
assert_eq "a pinned (threadId, labelIds) pair: allowed" "0" "$rc"

rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"t1","labelIds":["INBOX"]}}' \
	| "$HOOK" --pinned "$pinned_file" -- mcp__claude_ai_Gmail__unlabel_thread > /dev/null 2>&1 || rc=$?
assert_eq "the right thread id but a different label: denied" "2" "$rc"

rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"t3-not-pinned","labelIds":["UNREAD"]}}' \
	| "$HOOK" --pinned "$pinned_file" -- mcp__claude_ai_Gmail__unlabel_thread > /dev/null 2>&1 || rc=$?
assert_eq "a thread id never pinned: denied" "2" "$rc"

rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"labelIds":["UNREAD"],"threadId":"t2"}}' \
	| "$HOOK" --pinned "$pinned_file" -- mcp__claude_ai_Gmail__unlabel_thread > /dev/null 2>&1 || rc=$?
assert_eq "key order in tool_input doesn't matter" "0" "$rc"

echo
echo "=== desk_step_write actually builds the pinned-args file the hook reads ==="
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
CAPTURE_DIR="$ROOT/capture"
mkdir -p "$CAPTURE_DIR"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
# Copy this call's own scratch-dir artifacts out before desk-run's cleanup
# removes them, so the test can inspect what desk_step_write actually
# wrote — desk_call_model cd's into the scratch dir before exec'ing this.
cp deny-hook-settings.json "$CAPTURE_DIR/settings.json" 2> /dev/null
cp pinned-args.json "$CAPTURE_DIR/pinned-args.json" 2> /dev/null
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
export DESK_CONFIG="$ROOT/config.json" # only desk_prompt_path needs this to resolve
echo '{}' > "$DESK_CONFIG"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

PASS_SCRATCH="$(desk_scratch_dir "test-pass")"
trap 'rm -rf "$PASS_SCRATCH"' EXIT

step_json='{"id":"W","kind":"write","tools":["mcp__claude_ai_Gmail__unlabel_thread"],"connector":true,"timeout":30}'
pinned='[{"threadId":"t1","labelIds":["UNREAD"]},{"threadId":"t2","labelIds":["UNREAD"]}]'
result="$(desk_step_write "testpass" "$step_json" "$pinned" '{}')"
assert_eq "the call reports ok" "ok" "$result"

assert_true "the settings file's hook command names --pinned" \
	"$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CAPTURE_DIR/settings.json" 2> /dev/null | grep -q -- '--pinned' && echo true || echo false)"
assert_true "the pinned-args file holds exactly the array desk_step_write was given" \
	"$(diff <(jq -cS . "$CAPTURE_DIR/pinned-args.json") <(jq -cS . <<< "$pinned") > /dev/null 2>&1 && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
