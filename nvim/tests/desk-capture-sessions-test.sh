#!/usr/bin/env bash
# claude/desk-lib/steps.sh's desk_step_capture_sessions (design.md §3
# "Capture"): the 16:30 pass's own "running" (live now) and "dropped" (has
# a start event, isn't live, never got a deliberate end) session captures,
# a bare name on top of notes.md — no model call, no transcript read.
# session-status.sh is faked (a fixture file, never a real Claude Code
# session); the notes repo and the ledger writes are real, against a
# throwaway git fixture this test creates and discards.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

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

# Safety: this test drives real git commits (git-ops.sh/steps.sh call git
# directly, no fake). Refuse to run anywhere but under a throwaway temp
# dir, and never let the real dotfiles hookspath (core.hookspath is set
# globally, so an un-overridden `git init` inherits it) or an inherited
# GIT_DIR/GIT_WORK_TREE point this test's git commands at a real repo.
case "$(cd "$ROOT" && pwd -P)" in
	"${TMPDIR:-/nonexistent}"* | /tmp/* | /private/tmp/* | /private/var/folders/* | /var/folders/*) : ;;
	*)
		printf 'refusing to run: ROOT is not under a temp dir: %s\n' "$ROOT" >&2
		exit 1
		;;
esac
unset GIT_DIR GIT_WORK_TREE

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_BRIEF_DIR="$STATE/briefs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"

SESSION_STATUS_FIXTURE="$ROOT/sessions.jsonl"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
cat "$SESSION_STATUS_FIXTURE" 2> /dev/null
FAKE
chmod +x "$FAKEBIN/session-status.sh"
export PATH="$FAKEBIN:$PATH"

repo="$ROOT/notes"
mkdir -p "$repo"
git -C "$repo" init -q
# Override the machine's real global core.hookspath (~/dotfiles/git-hooks)
# so this throwaway repo's commits never run real dotfiles hook scripts.
git -C "$repo" config core.hookspath "$ROOT/no-hooks"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Already Noted: an existing section\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
files=(notes.md reading.md)

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/git-ops.sh
source "$LIB/git-ops.sh"
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/validate.sh
source "$LIB/validate.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

sess() { # id name name_source live has_start_event source ended end_reason
	jq -cn --arg id "$1" --arg name "$2" --arg ns "$3" --argjson live "$4" \
		--argjson hse "$5" --arg src "$6" --argjson ended "$7" --arg er "$8" '
		{id:$id, name:$name, name_source:$ns, live:$live, has_start_event:$hse,
		 source:$src, ended:$ended, end_reason:(if $er == "" then null else $er end)}
	'
}

{
	sess "sess-running" "Running One" "user" true true "startup" false ""
	sess "sess-already-noted" "Already Noted" "user" true true "startup" false ""
	sess "sess-unnamed-running" "Auto Title X" "ai_or_none" true true "startup" false ""
	sess "sess-dropped-never-ended" "Dropped Never Ended" "user" false true "startup" false ""
	sess "sess-dropped-other" "Dropped Other" "user" false true "startup" true "other"
	sess "sess-deliberate-end" "Deliberate End" "user" false true "startup" true "prompt_input_exit"
	sess "sess-desk-run" "Scheduled Run" "user" true true "desk-run" false ""
	sess "sess-no-start-event" "No Start Event" "user" true false "startup" false ""
} > "$SESSION_STATUS_FIXTURE"

PASS_SCRATCH="$(mktemp -d)"
export PASS_SCRATCH

echo "=== a first capture pass ==="
result="$(desk_step_capture_sessions "1630" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"

proposal="$(desk_nvim_cli proposal-read "$repo")"
by_sid() { printf '%s' "$proposal" | jq -c --arg sid "$1" '.items[] | select(.session_id == $sid)'; }

assert_true "a live named session not in the notes is captured as running" \
	"$([ -n "$(by_sid sess-running)" ] && echo true || echo false)"
assert_eq "its headline is the bare name" "Running One" "$(by_sid sess-running | jq -r '.headline')"
assert_eq "its capture_kind is running" "running" "$(by_sid sess-running | jq -r '.capture_kind')"
assert_eq "it lands on top of notes.md" "notes.md" "$(by_sid sess-running | jq -r '.file')"
assert_eq "its target is top" '"top"' "$(by_sid sess-running | jq -c '.target')"

assert_true "a name already in the notes is never captured" \
	"$([ -z "$(by_sid sess-already-noted)" ] && echo true || echo false)"

assert_true "an unnamed live session is captured" \
	"$([ -n "$(by_sid sess-unnamed-running)" ] && echo true || echo false)"
assert_eq "its headline is auto title + short id" "Auto Title X · sess-unn" \
	"$(by_sid sess-unnamed-running | jq -r '.headline')"

assert_true "a never-ended, not-live session is captured as dropped" \
	"$([ -n "$(by_sid sess-dropped-never-ended)" ] && echo true || echo false)"
assert_eq "its capture_kind is dropped" "dropped" "$(by_sid sess-dropped-never-ended | jq -r '.capture_kind')"

assert_true "an end_reason 'other', not-live session is captured as dropped" \
	"$([ -n "$(by_sid sess-dropped-other)" ] && echo true || echo false)"

assert_true "a deliberate end (prompt_input_exit) is never captured" \
	"$([ -z "$(by_sid sess-deliberate-end)" ] && echo true || echo false)"

assert_true "source desk-run is excluded even though it's live" \
	"$([ -z "$(by_sid sess-desk-run)" ] && echo true || echo false)"

assert_true "no recorder start event at all is excluded" \
	"$([ -z "$(by_sid sess-no-start-event)" ] && echo true || echo false)"

echo
echo "=== a second capture pass: already-ledgered captures never duplicate ==="
count_before="$(printf '%s' "$proposal" | jq '.items | length')"
rm -rf "$PASS_SCRATCH"
PASS_SCRATCH="$(mktemp -d)"
export PASS_SCRATCH
result="$(desk_step_capture_sessions "1630" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the second pass still reports ok" "ok" "$result"
proposal2="$(desk_nvim_cli proposal-read "$repo")"
count_after="$(printf '%s' "$proposal2" | jq '.items | length')"
assert_eq "the item count is unchanged (no duplicate captures)" "$count_before" "$count_after"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
