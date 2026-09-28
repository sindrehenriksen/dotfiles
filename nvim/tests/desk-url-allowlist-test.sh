#!/usr/bin/env bash
# D8 fix test (review item #8): desk-run's own judge branch builds the
# allowed-URL set (desk_allowed_urls, the "an item's source must appear in
# a real fetch's own raw tool_results" check) only from this pass's FETCH
# steps' own tool-results files — never from J's own (a judge call's own
# tool use, e.g. reading a seeded scratch file, can surface quoted text or
# the model's own prose carrying a URL that no real fetch ever retrieved).
# Drives desk-run itself: a fetch step's raw result carries one real URL,
# J's own tool call surfaces a different, fabricated one, and J's final
# reply cites both.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
cwd="$(basename "$PWD")"
case "$cwd" in
	*-F-*)
		# A real fetch: one tool_use/tool_result pair whose raw result
		# carries the ONLY genuinely-fetched URL.
		echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_f","name":"Read","input":{}}]}}'
		echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_f","content":[{"type":"text","text":"see https://example.invalid/real for the real thing"}]}]}}'
		;;
	*-J-*)
		# J's own tool call surfaces a DIFFERENT URL in its own raw
		# tool_result — this must never become part of the allowed set.
		echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_j","name":"Read","input":{}}]}}'
		echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_j","content":[{"type":"text","text":"unrelated file content mentioning https://example.invalid/fabricated somewhere"}]}]}}'
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"i1\",\"file\":\"notes.md\",\"kind\":\"new\",\"target\":\"top\",\"before\":\"\",\"after\":\"real item\",\"source\":\"https://example.invalid/real\",\"headline\":\"h1\"},{\"id\":\"i2\",\"file\":\"notes.md\",\"kind\":\"new\",\"target\":\"top\",\"before\":\"\",\"after\":\"fabricated item\",\"source\":\"https://example.invalid/fabricated\",\"headline\":\"h2\"}]}"}]}}'
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
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main
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
		{ id: "F", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "J", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?
assert_true "the pass succeeds" "$([ "$rc" -eq 0 ] && echo true || echo false)"

proposal_blob="$(git -C "$repo" show refs/desk/proposal:proposal.json 2> /dev/null)"
# Staging namespaces every item's own model-assigned id (desk_stage_and_
# write_proposal, via cli.lua's namespace-ids), so "i1"/"i2" survive only
# as an "-i1"/"-i2" suffix on the real, ledger-unique id.
assert_true "the item citing a real fetch result survives" \
	"$(jq -e '.items[] | select(.id | endswith("-i1"))' > /dev/null 2>&1 <<< "$proposal_blob" && echo true || echo false)"
assert_true "the item citing only J's own tool-result URL is dropped" \
	"$(jq -e '.items[] | select(.id | endswith("-i2"))' > /dev/null 2>&1 <<< "$proposal_blob" && echo false || echo true)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
