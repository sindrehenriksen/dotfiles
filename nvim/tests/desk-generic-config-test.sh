#!/usr/bin/env bash
# claude/desk-run no longer hardcodes this
# machine's tool names, timezone, or the step ids it special-cases for
# ticket status and mail — timezone, ticket_search_tool, mail_search_tool,
# ticket_status_step_id and mail_fetch_step_id are all required
# $DESK_CONFIG fields, with no work-specific default shipped in this
# (public) repo. Each is checked missing in turn; desk-run must fail
# loudly (a clear message, never a silent fallback to a literal) rather
# than run with a guessed default.
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

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"

# A real (if empty) repo — desk-run's own notes_repo validation now
# requires an absolute path that's actually some repo's own toplevel, even
# for a pass with no steps to ever touch it (see nvim/tests/desk-run-test.sh
# for that validation's own dedicated cases; this file stays focused on
# the generic-config checks its own name promises).
repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q

# A config that's otherwise complete (a bare commit_push-only pass, no
# model call needed) except for whichever one field this case omits.
full_config() {
	jq -n --arg repo "$repo" '{
		notes_repo: $repo,
		files: ["notes.md"],
		timezone: "UTC",
		ticket_search_tool: "mcp__example-tickets__search",
		mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
		ticket_status_step_id: "T",
		mail_fetch_step_id: "F-private",
		passes: { testpass: { steps: [] } }
	}'
}

for field in timezone ticket_search_tool mail_search_tool ticket_status_step_id mail_fetch_step_id; do
	cfg="$ROOT/config-missing-$field.json"
	full_config | jq "del(.$field)" > "$cfg"
	out="$(DESK_CONFIG="$cfg" "$DESK_RUN" testpass 2>&1)"
	rc=$?
	assert_true "missing \"$field\": exits non-zero" "$([ "$rc" -ne 0 ] && echo true || echo false)"
	assert_true "missing \"$field\": names the exact field in the failure" \
		"$(grep -qF "\"$field\"" <<< "$out" && echo true || echo false)"
done

echo
echo "=== every field present: the same pass runs fine ==="
cfg_ok="$ROOT/config-ok.json"
full_config > "$cfg_ok"
DESK_CONFIG="$cfg_ok" "$DESK_RUN" testpass > /dev/null 2>&1
assert_eq "runs to completion (no steps, nothing to fail on)" "0" "$?"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
