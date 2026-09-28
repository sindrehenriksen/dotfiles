#!/usr/bin/env bash
# D8 fix test (review item #11): desk-run writes the rest of status.json
# after every pass — proposal {state, partial, overflow, counts, queued,
# deferred}, the ledger-classify fields, ticket_cache_age, and this pass's
# own total_cost_usd — none of which the runner ever wrote before (status.
# sh's own header comment: "D8a leaves them at their zero-ish defaults
# where no such step runs" — no step ever did). Drives desk-run itself
# with a judge step whose two ACT-tier items overflow a cap of one, and a
# fake claude that reports a real total_cost_usd on its own stream-json
# result line.
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
cwd="$(basename "$PWD")"
case "$cwd" in
	*-J-*)
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"items\":[{\"id\":\"a1\",\"file\":\"notes.md\",\"kind\":\"new\",\"target\":\"top\",\"before\":\"\",\"after\":\"first\",\"source\":\"notes\",\"headline\":\"h1\",\"tier\":\"act\"},{\"id\":\"a2\",\"file\":\"notes.md\",\"kind\":\"new\",\"target\":\"top\",\"before\":\"\",\"after\":\"second\",\"source\":\"notes\",\"headline\":\"h2\",\"tier\":\"act\"}]}"}]}}'
		echo '{"type":"result","subtype":"success","total_cost_usd":0.0250}'
		exit 0
		;;
esac
echo '{"type":"result","subtype":"success","total_cost_usd":0.0100}'
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
export DESK_BRIEF_DIR="$STATE/briefs"
export DESK_FETCH_CACHE_ROOT="$STATE/fetch-cache"
export DESK_TICKET_CACHE="$STATE/ticket-status.json"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"

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

prompt="$ROOT/prompt.md"
echo "a generic test prompt" > "$prompt"
cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg prompt "$prompt" '{
	notes_repo: $repo,
	files: ["notes.md", "reading.md"],
	caps: { daily: { act: 1, worth_knowing: 3, wildcard: 1 } },
	passes: { testpass: { steps: [
		{ id: "J", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "commit-push", kind: "commit_push" }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?
assert_true "the pass succeeds" "$([ "$rc" -eq 0 ] && echo true || echo false)"

status="$(cat "$DESK_STATUS_FILE")"

echo "=== proposal ==="
assert_eq "state: pending" "pending" "$(jq -r '.proposal.state' <<< "$status")"
assert_eq "partial: false (no failed source this pass)" "false" "$(jq -r '.proposal.partial' <<< "$status")"
assert_eq "overflow.act: 1 (cap of 1, two ACT items)" "1" "$(jq -r '.proposal.overflow.act' <<< "$status")"
assert_eq "counts.by_kind.new includes the overflow-summary item too" "2" "$(jq -r '.proposal.counts.by_kind.new' <<< "$status")"
assert_true "queued is a number" "$(jq -e '.proposal.queued | type == "number"' > /dev/null 2>&1 <<< "$status" && echo true || echo false)"
assert_true "deferred is a number" "$(jq -e '.proposal.deferred | type == "number"' > /dev/null 2>&1 <<< "$status" && echo true || echo false)"

echo
echo "=== ledger-classify fields ==="
assert_true "accepted_by_accident is an array" \
	"$(jq -e '.accepted_by_accident | type == "array"' > /dev/null 2>&1 <<< "$status" && echo true || echo false)"
assert_true "resolved_without_key is an array" \
	"$(jq -e '.resolved_without_key | type == "array"' > /dev/null 2>&1 <<< "$status" && echo true || echo false)"
assert_true "waiting_edits is an array" \
	"$(jq -e '.waiting_edits | type == "array"' > /dev/null 2>&1 <<< "$status" && echo true || echo false)"

echo
echo "=== ticket_cache_age (no T step ran, no cache file: null) ==="
assert_eq "ticket_cache_age is null" "null" "$(jq -c '.ticket_cache_age' <<< "$status")"

echo
echo "=== total_cost_usd: summed across every call this pass made ==="
assert_true "J's own 0.025 is the only call this pass" \
	"$(jq -e '.passes.testpass.total_cost_usd == 0.025' > /dev/null 2>&1 <<< "$status" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
