#!/usr/bin/env bash
# D8 fix test (review item #7): the allowlist deny-hook's fail-open edges.
# A --pinned file that's missing must deny (never silently skip the
# pinning check), and desk_write_deny_hook_settings must build its own
# hook command with proper shell quoting — a scratch dir or pinned-args
# path containing a space must not make the hook exit non-blocking (i.e.
# fail to run as intended) once Claude Code runs it through a shell.
# Also covers desk_step_model_call passing --tools for a connector call,
# so built-ins aren't loaded beyond that call's own list.
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

echo "=== a --pinned file that's missing denies, rather than skipping the check ==="
missing_file="$ROOT/does-not-exist.json"
rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"t1","labelIds":["UNREAD"]}}' \
	| "$HOOK" --pinned "$missing_file" -- mcp__claude_ai_Gmail__unlabel_thread > /dev/null 2>&1 || rc=$?
assert_eq "denied (exit 2), not fail-open" "2" "$rc"

echo
echo "=== --scratch: a judge/close call's own second layer under its scoped Read(...) --allowedTools ==="
scratch_dir="$ROOT/call-scratch"
mkdir -p "$scratch_dir/sub"
printf 'in scope\n' > "$scratch_dir/notes.md"
printf 'in scope, nested\n' > "$scratch_dir/sub/nested.md"
outside_dir="$ROOT/outside"
mkdir -p "$outside_dir"
printf 'out of scope\n' > "$outside_dir/secret.txt"

rc=0
jq -cn --arg fp "$scratch_dir/notes.md" '{tool_name:"Read",tool_input:{file_path:$fp}}' \
	| "$HOOK" --scratch "$scratch_dir" -- Read > /dev/null 2>&1 || rc=$?
assert_eq "a Read inside the scratch dir is allowed" "0" "$rc"

rc=0
jq -cn --arg fp "$scratch_dir/sub/nested.md" '{tool_name:"Read",tool_input:{file_path:$fp}}' \
	| "$HOOK" --scratch "$scratch_dir" -- Read > /dev/null 2>&1 || rc=$?
assert_eq "a Read of a nested file inside the scratch dir is allowed" "0" "$rc"

rc=0
out="$(jq -cn --arg fp "$outside_dir/secret.txt" '{tool_name:"Read",tool_input:{file_path:$fp}}' \
	| "$HOOK" --scratch "$scratch_dir" -- Read 2>&1)" || rc=$?
assert_eq "a Read outside the scratch dir is denied" "2" "$rc"
printf '%s\n' "$out" | grep -q "outside this call's scratch dir" \
	&& ok "the denial names why" || bad "denial message doesn't explain why (got: $out)"

rc=0
jq -cn --arg fp "$scratch_dir/../outside/secret.txt" '{tool_name:"Read",tool_input:{file_path:$fp}}' \
	| "$HOOK" --scratch "$scratch_dir" -- Read > /dev/null 2>&1 || rc=$?
assert_eq "a path only string-prefixed with the scratch dir (../ escape) is still denied" "2" "$rc"

rc=0
jq -cn '{tool_name:"Read",tool_input:{}}' \
	| "$HOOK" --scratch "$scratch_dir" -- Read > /dev/null 2>&1 || rc=$?
assert_eq "a Read with no file_path at all is denied, not silently allowed" "2" "$rc"

rc=0
echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
	| "$HOOK" --scratch "$scratch_dir" -- Read Bash > /dev/null 2>&1 || rc=$?
assert_eq "--scratch never restricts a non-Read tool that's on the allowlist" "0" "$rc"

echo
echo "=== desk_write_deny_hook_settings: a path with a space quotes correctly ==="
export DESK_STATE_DIR="$ROOT/state"
# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"

spacey_dir="$ROOT/a scratch dir"
mkdir -p "$spacey_dir"
pinned_file="$spacey_dir/pinned args.json"
jq -n '[{threadId: "t1", labelIds: ["UNREAD"]}]' > "$pinned_file"

settings_path="$(desk_write_deny_hook_settings "$spacey_dir" "$pinned_file" "" mcp__claude_ai_Gmail__unlabel_thread)"
hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings_path")"

denied_rc=0
echo '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' | bash -c "$hook_cmd" > /dev/null 2>&1 || denied_rc=$?
assert_eq "an unlisted tool is still denied despite the space in the path" "2" "$denied_rc"

allowed_rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"t1","labelIds":["UNREAD"]}}' \
	| bash -c "$hook_cmd" > /dev/null 2>&1 || allowed_rc=$?
assert_eq "the pinned call is still allowed despite the space in the path" "0" "$allowed_rc"

mismatched_rc=0
echo '{"tool_name":"mcp__claude_ai_Gmail__unlabel_thread","tool_input":{"threadId":"other","labelIds":["UNREAD"]}}' \
	| bash -c "$hook_cmd" > /dev/null 2>&1 || mismatched_rc=$?
assert_eq "a tool_input not in the pinned set is still denied despite the space in the path" "2" "$mismatched_rc"

echo
echo "=== desk_write_deny_hook_settings also quotes a spacey --scratch dir correctly ==="
scratch_settings_path="$(desk_write_deny_hook_settings "$spacey_dir" "" "$spacey_dir" Read)"
scratch_hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$scratch_settings_path")"

in_scope_rc=0
jq -cn --arg fp "$spacey_dir/pinned args.json" '{tool_name:"Read",tool_input:{file_path:$fp}}' \
	| bash -c "$scratch_hook_cmd" > /dev/null 2>&1 || in_scope_rc=$?
assert_eq "a Read inside the spacey scratch dir is still allowed" "0" "$in_scope_rc"

outside_file="$ROOT/elsewhere.txt"
printf 'not in the spacey scratch dir\n' > "$outside_file"
out_of_scope_rc=0
jq -cn --arg fp "$outside_file" '{tool_name:"Read",tool_input:{file_path:$fp}}' \
	| bash -c "$scratch_hook_cmd" > /dev/null 2>&1 || out_of_scope_rc=$?
assert_eq "a Read outside the spacey scratch dir is still denied" "2" "$out_of_scope_rc"

echo
echo "=== desk_step_model_call: a connector call passes --tools, not just --allowedTools ==="
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
ARGV_LOG="$ROOT/argv.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"
PASS_SCRATCH="$(desk_scratch_dir "test-pass")"
trap 'rm -rf "$PASS_SCRATCH"' EXIT

step_json='{"id":"W","kind":"write","tools":["mcp__claude_ai_Gmail__unlabel_thread"],"connector":true,"timeout":30}'
desk_step_write "testpass" "$step_json" "null" '{}' > /dev/null
argv="$(cat "$ARGV_LOG" 2> /dev/null || true)"
assert_true "--tools was passed, scoped to this call's own allowlist" \
	"$(printf '%s' "$argv" | grep -A1 -- '^--tools$' | tail -1 | grep -qx 'mcp__claude_ai_Gmail__unlabel_thread' && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
