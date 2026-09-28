#!/usr/bin/env bash
# D8 fix test (review item #7): desk-run's own write-branch logic (the
# F-private-dependency check and the Gmail thread-id pinning derivation)
# applies to any step of kind "write", never gated on its own `id`
# happening to be the literal string "W" — an instantiation is free to
# name that step whatever it likes. This drives the exact same "F-private
# failed this pass" scenario desk-partial-proposal-test.sh covers, but
# with the write step named something else entirely, to prove the
# behavior isn't secretly keyed on the id.
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

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
cwd="$(basename "$PWD")"
case "$cwd" in
	*-F-private-*) exit 1 ;; # the source this write step depends on fails
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
	digest_gmail_label: "Digest",
	passes: { testpass: { steps: [
		{ id: "F-private", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 },
		{ id: "gmail-unlabel-digest", kind: "write", prompt: $prompt,
		  tools: ["mcp__claude_ai_Gmail__unlabel_thread"], connector: true, timeout: 30 }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?

assert_true "the pass fails (the write step still refuses)" "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_true "the refusal is logged under this step's own (renamed) id" \
	"$(grep -q 'gmail-unlabel-digest: F-private.*failed this pass' "$ROOT/run.out" && echo true || echo false)"
assert_eq "status names the renamed step, not a literal 'W', as the one that stopped the pass" \
	"gmail-unlabel-digest" "$(jq -r '.passes.testpass.stopped_at' "$DESK_STATUS_FILE")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
