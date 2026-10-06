#!/usr/bin/env bash
# a fetch/judge/ticket_status step's `mcp_config` field reaches the model call as --mcp-config with --strict-mcp-config,
# resolved relative to $DESK_CONFIG's directory the same as `prompt` is —
# this is what lets T (ticket-status) run headless against the
# ticket tracker's MCP server, alongside (not instead of) --restricted,
# which every non-connector call still keeps. A fake `claude` records its
# own argv instead of making a real call.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok   - %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL - %s\n' "$1"
}
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then
		ok "$desc"
	else
		bad "$desc (got [$cond])"
	fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

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

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"

desk_test_assert_repo_under_root "$ROOT/remote.git" "$ROOT"
git init -q --bare "$ROOT/remote.git"
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
git -C "$repo" remote add origin "$ROOT/remote.git"
git -C "$repo" push -q origin main

mkdir -p "$ROOT/config-dir/mcp"
echo '{"mcpServers":{}}' > "$ROOT/config-dir/mcp/example-tickets.json"
echo "a ticket-status test prompt" > "$ROOT/config-dir/ticket-status.md"

cfg="$ROOT/config-dir/config.json"
jq -n --arg repo "$repo" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	passes: { testpass: { steps: [
		{ id: "commit-push", kind: "commit_push" },
		{ id: "T", kind: "fetch", prompt: "ticket-status.md",
		  tools: ["mcp__example-tickets__search"],
		  connector: false, mcp_config: "mcp/example-tickets.json", timeout: 30 }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?
assert_true "the run succeeds" "$([ "$rc" -eq 0 ] && echo true || echo false)"

argv="$(cat "$ARGV_LOG" 2> /dev/null || true)"
assert_true "--strict-mcp-config was passed" \
	"$(printf '%s' "$argv" | grep -qx -- '--strict-mcp-config' && echo true || echo false)"
assert_true "--mcp-config was resolved to an absolute path beside \$DESK_CONFIG" \
	"$(printf '%s' "$argv" | grep -qx -- "$ROOT/config-dir/mcp/example-tickets.json" && echo true || echo false)"
assert_true "--restricted is still passed (design: T keeps --restricted; only connectors drop it, and an --mcp-config server loads fine under it)" \
	"$(printf '%s' "$argv" | grep -qx -- '--restricted' && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
