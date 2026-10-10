#!/usr/bin/env bash
# Every --restricted model call gets an explicit --tools list (only the
# built-ins that step needs, empty when none) and --strict-mcp-config with
# an explicit --mcp-config (an empty-servers file when the step names
# none), so no unlisted built-in or user MCP server is ever loaded. A fake
# `claude` records its own argv; no live call.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
ARGV_LOG="$ROOT/argv.log"
MCP_LOG="$ROOT/mcp-content.log"
SETTINGS_LOG="$ROOT/settings-content.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
: > "$MCP_LOG"
: > "$SETTINGS_LOG"
prev=""
for a in "\$@"; do
	[ "\$prev" = "--mcp-config" ] && [ -f "\$a" ] && cat "\$a" > "$MCP_LOG"
	[ "\$prev" = "--settings" ] && [ -f "\$a" ] && cat "\$a" > "$SETTINGS_LOG"
	prev="\$a"
done
echo '{"type":"result","subtype":"success"}'
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
export CLAUDE_SESSION_STORE="$STATE/session-events"
export CLAUDE_SESSION_RECORDER_LOG="$STATE/session-recorder.log"
mkdir -p "$ROOT/cfg/mcp"
echo '{"mcpServers":{"only-this":{"type":"http","url":"https://example.invalid"}}}' > "$ROOT/cfg/mcp/t.json"
echo '{}' > "$ROOT/cfg/config.json"
export DESK_CONFIG="$ROOT/cfg/config.json"

for f in common status timeout model-call tool-results validate steps; do
	# shellcheck source=/dev/null
	source "$LIB/$f.sh"
done

value_after() { grep -A1 -x -- "$1" "$ARGV_LOG" | tail -1; }
has_flag() { grep -qx -- "$1" "$ARGV_LOG" && echo true || echo false; }

run_step() { # <step-json>
	PASS_SCRATCH="$(mktemp -d)"
	: > "$ARGV_LOG"
	desk_step_model_call testpass "$1" x '{}' "" > /dev/null
	rm -rf "$PASS_SCRATCH"
}

check() { # <label> <step-json> <expected --tools> <mcp content kind: empty|file>
	run_step "$2"
	assert_eq "$1: --restricted" true "$(has_flag --restricted)"
	assert_eq "$1: --tools is exactly the step's built-ins" "$3" "$(value_after --tools)"
	assert_eq "$1: --strict-mcp-config" true "$(has_flag --strict-mcp-config)"
	assert_eq "$1: the prompt follows --, out of reach of any variadic flag" "--" "$(tail -2 "$ARGV_LOG" | head -1)"
	if [ "$4" = empty ]; then
		assert_eq "$1: --mcp-config is an empty server set" '{"mcpServers":{}}' "$(jq -c . "$MCP_LOG")"
	else
		assert_eq "$1: --mcp-config is the step's own file" "only-this" "$(jq -r '.mcpServers|keys[0]' "$MCP_LOG")"
	fi
}

check F-web '{"id":"F-web","kind":"fetch","tools":["WebSearch"],"connector":false,"timeout":30}' WebSearch empty
check T '{"id":"T","kind":"fetch","tools":["mcp__example-tickets__search"],"connector":false,"mcp_config":"mcp/t.json","timeout":30}' "" file
check J '{"id":"J","kind":"judge","tools":["Read"],"connector":false,"timeout":30}' Read empty
check close '{"id":"close","kind":"close","tools":["Read"],"connector":false,"timeout":30}' Read empty

# A pattern loads its tool by name; the pattern itself restricts it, in the
# allowlist and in the deny hook a pattern brings with it.
gh_step='{"id":"F-gh","kind":"fetch","tools":["Bash(gh run list:*)","Bash(gh pr list:*)","WebSearch"],"connector":false,"timeout":30}'
check F-gh "$gh_step" "Bash,WebSearch" empty
assert_eq "F-gh: --allowedTools keeps the patterns" "Bash(gh run list:*),Bash(gh pr list:*),WebSearch" "$(value_after --allowedTools)"
hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS_LOG" 2> /dev/null)"
if [ -n "$hook_cmd" ]; then
	hook_rc() { local rc=0; jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash -c "$hook_cmd" > /dev/null 2>&1 || rc=$?; echo "$rc"; }
	assert_eq "F-gh: the deny hook admits a command a pattern fits" 0 "$(hook_rc 'gh pr list --state open')"
	assert_eq "F-gh: and refuses one none fits" 2 "$(hook_rc 'gh pr merge 1')"
else
	bad "F-gh: a step with a tool pattern gets the deny hook as --settings"
fi
check F-web-again '{"id":"F-web","kind":"fetch","tools":["WebSearch"],"connector":false,"timeout":30}' WebSearch empty
assert_eq "F-web: no pattern, no Read: no --settings" false "$(has_flag --settings)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
