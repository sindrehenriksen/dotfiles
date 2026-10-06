#!/usr/bin/env bash
# End-to-end test: a full desk-run pass (F-private, T, J, W steps)
# itself (not each lib function in isolation) — T's ticket cache, J's
# validated proposal landing in the ledger, and W's dry-run pinning and
# logging, all wired together the way desk-run's own step loop actually
# does it. One fake `claude` plays every call, keyed off its own scratch
# cwd (which desk_call_model names after pass-step, e.g. "...-T-..."), so
# each step gets the right canned tool_use/tool_result/final-text reply.
# No live model call, no live Jira/Slack/Gmail — every raw result here is
# a fixture this test wrote itself.
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
W_LOG="$ROOT/w-calls.log"
: > "$W_LOG"
# J is a judge step with a "Read" tool, so it gets the deny hook's own
# --scratch backstop wired in (steps.sh's hook_scratch) — its own
# --settings file's `command` is captured here, while the fake claude is
# still running and nothing has been cleaned up yet, to check desk-run's
# own pass-start copy (claude/desk-run's own DESK_DENY_HOOK_SCRIPT): it
# must be a real, non-empty file distinct from the repo's own live
# deny-unlisted-tool.sh, living under this pass's own scratch tree.
J_HOOK_SCRIPT_PATH_LOG="$ROOT/j-hook-script-path.log"
J_HOOK_SCRIPT_COPY="$ROOT/j-hook-script-copy.sh"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
# \$W_LOG/\$J_HOOK_SCRIPT_PATH_LOG/\$J_HOOK_SCRIPT_COPY are baked in below
# (fixed paths in \$ROOT), the rest reads only its own scratch cwd
# (prompt.txt) — nothing here depends on shell expansion at write-time
# except those paths.
W_LOG="$W_LOG"
J_HOOK_SCRIPT_PATH_LOG="$J_HOOK_SCRIPT_PATH_LOG"
J_HOOK_SCRIPT_COPY="$J_HOOK_SCRIPT_COPY"
FAKE
cat >> "$FAKEBIN/claude" <<'FAKE'
cwd="$(pwd -P)"
case "$cwd" in
	*-F-private-*)
		q="$(sed -n 's/^digest_query=//p' prompt.txt)"
		jq -nc --arg q "$q" '{type:"assistant",message:{content:[{type:"tool_use",id:"u1",name:"mcp__claude_ai_Gmail__search_threads",input:{query:$q}}]}}'
		echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":[{"type":"text","text":"{\"threads\":[{\"id\":\"thread-1\",\"subject\":\"Daily Digest\"}]}"}]}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-T-*)
		echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u2","name":"mcp__example-tickets__search","input":{"jql":"key in (\"DESK-NONE-0\")"}}]}}'
		echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u2","content":[{"type":"text","text":"{\"issues\":[]}"}]}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-J-*)
		settings_path=""
		prev=""
		for a in "$@"; do
			[ "$prev" = "--settings" ] && settings_path="$a"
			prev="$a"
		done
		if [ -n "$settings_path" ] && [ -f "$settings_path" ]; then
			hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings_path" 2> /dev/null)"
			hook_script_path="$(printf '%s' "$hook_cmd" | sed -n "s/^'\([^']*\)'.*/\1/p")"
			printf '%s\n' "$hook_script_path" > "$J_HOOK_SCRIPT_PATH_LOG"
			[ -f "$hook_script_path" ] && cp "$hook_script_path" "$J_HOOK_SCRIPT_COPY" 2> /dev/null
		fi
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"j1\",\"file\":\"notes.md\",\"kind\":\"new\",\"target\":\"top\",\"before\":\"\",\"after\":\"a validated item\",\"source\":\"notes\",\"headline\":\"h1\",\"tier\":\"act\"}]}"}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-W-*)
		printf '%s\n' "$@" >> "$W_LOG"
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
export DESK_TICKET_CACHE="$STATE/ticket-status.json"
export DESK_BRIEF_DIR="$STATE/briefs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_LOCK_MAX_WAIT_SECS=2
export DESK_LOCK_POLL_SECS=1

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
# F-private's own prompt echoes back the runner-rendered digest_query
# placeholder as a plain "key=value" line, so the fake claude (which only
# sees this rendered prompt.txt in its own scratch cwd, never desk-run's
# shell variables) can read back exactly what the runner actually
# computed and told it to search with.
f_private_prompt="$ROOT/f-private-prompt.md"
echo 'digest_query={{digest_query}}' > "$f_private_prompt"

cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg prompt "$prompt" --arg fpp "$f_private_prompt" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	caps: {daily: {act: 3, worth_knowing: 3, wildcard: 1}, weekly: {act: 5, worth_knowing: 8, wildcard: 1}},
	tokens: [{pattern: "^TICKET-([0-9]+)$", case_insensitive: true, handler: "url"}],
	dry_run: true,
	passes: {
		testpass: {
			steps: [
				{id: "commit-push", kind: "commit_push"},
				{id: "F-private", kind: "fetch", prompt: $fpp, tools: ["mcp__claude_ai_Gmail__search_threads"], connector: true, timeout: 30},
				{id: "T", kind: "fetch", prompt: $prompt, tools: ["mcp__example-tickets__search"], connector: false, timeout: 30},
				{id: "J", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30},
				{id: "W", kind: "write", prompt: $prompt, tools: ["mcp__claude_ai_Gmail__unlabel_thread"], connector: true, pinned_label: "UNREAD", timeout: 30}
			]
		}
	}
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?
cat "$ROOT/run.out" | sed 's/^/    /'
assert_eq "the pass exits ok" "0" "$rc"

echo
echo "=== T's ticket cache ==="
assert_true "the ticket cache was written (empty issues is still an ok result)" \
	"$([ -f "$DESK_TICKET_CACHE" ] && echo true || echo false)"
assert_eq "checked_at is a number" "true" "$(jq -e '.checked_at | type == "number"' > /dev/null 2>&1 "$DESK_TICKET_CACHE" && echo true || echo false)"

echo
echo "=== J's validated item landed in the ledger/proposal ==="
proposal_sha="$(git -C "$repo" rev-parse refs/desk/proposal 2> /dev/null || true)"
assert_true "a proposal ref was written" "$([ -n "$proposal_sha" ] && echo true || echo false)"
proposal_tree_blob="$(git -C "$repo" show refs/desk/proposal:proposal.json 2> /dev/null || true)"
# Staging namespaces every item's own model-assigned id (desk_stage_and_
# write_proposal, via cli.lua's namespace-ids), so "j1" survives only as
# an "-j1" suffix on the real, ledger-unique id.
assert_true "the proposal holds J's item" \
	"$(jq -e '.items[] | select(.id | endswith("-j1"))' > /dev/null 2>&1 <<< "$proposal_tree_blob" && echo true || echo false)"
ledger_ref="$(git -C "$repo" rev-parse refs/desk/ledger 2> /dev/null || true)"
assert_true "the ledger ref was written too" "$([ -n "$ledger_ref" ] && echo true || echo false)"

echo
echo "=== W ran dry (logged, never actually called) ==="
assert_true "W never made a model call" "$([ ! -s "$W_LOG" ] && echo true || echo false)"
assert_true "the log names the thread id and subject" \
	"$(grep -q 'thread-1' "$ROOT/run.out" && grep -q 'Daily Digest' "$ROOT/run.out" && echo true || echo false)"

echo
echo "=== J's deny hook was copied into this pass's own scratch, never pointed at the live repo file ==="
j_hook_script_path="$(cat "$J_HOOK_SCRIPT_PATH_LOG" 2> /dev/null)"
real_hook_script="$HERE/../../claude/desk-lib/deny-unlisted-tool.sh"
assert_true "a hook script path was actually captured" "$([ -n "$j_hook_script_path" ] && echo true || echo false)"
assert_true "it's under this pass's own scratch tree (\$DESK_SCRATCH_ROOT), not the repo" \
	"$([[ "$j_hook_script_path" == "$STATE/scratch"/* ]] && echo true || echo false)"
assert_true "it's distinct from the repo's own live deny-unlisted-tool.sh" \
	"$([ "$j_hook_script_path" != "$real_hook_script" ] && echo true || echo false)"
assert_true "the copy is a real, non-empty file (captured while it still existed)" \
	"$([ -s "$J_HOOK_SCRIPT_COPY" ] && echo true || echo false)"
assert_eq "the copy's own content matches the real script exactly" \
	"$(cat "$real_hook_script")" "$(cat "$J_HOOK_SCRIPT_COPY" 2> /dev/null)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
