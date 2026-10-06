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
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
: > "$MCP_LOG"
prev=""
for a in "\$@"; do
	[ "\$prev" = "--mcp-config" ] && [ -f "\$a" ] && cat "\$a" > "$MCP_LOG"
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

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
