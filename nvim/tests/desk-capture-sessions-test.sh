#!/usr/bin/env bash
# claude/desk-lib/steps.sh's desk_step_capture_sessions: the "running" (live now) and "dropped" (has
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
# directly, no fake) — see tests/lib/git-safety.sh for what this guards
# against and why.
# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

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
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
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

# left_open is what the reader reports for the row; the step takes it as
# given rather than judging the end itself.
sess() { # id name name_source live has_start_event source ended end_reason [any_desk_run] [cwd] [left_open]
	jq -cn --arg id "$1" --arg name "$2" --arg ns "$3" --argjson live "$4" \
		--argjson hse "$5" --arg src "$6" --argjson ended "$7" --arg er "$8" \
		--argjson adr "${9:-false}" --arg cwd "${10:-/home/user/somewhere}" --argjson lo "${11:-false}" '
		{id:$id, name:$name, name_source:$ns, live:$live, has_start_event:$hse,
		 source:$src, any_desk_run_start:$adr, cwd:$cwd,
		 ended:$ended, end_reason:(if $er == "" then null else $er end), left_open:$lo}
	'
}

{
	sess "sess-running" "Running One" "user" true true "startup" false ""
	sess "sess-already-noted" "Already Noted" "user" true true "startup" false ""
	sess "sess-unnamed-running" "Auto Title X" "ai_or_none" true true "startup" false ""
	sess "sess-dropped-never-ended" "Dropped Never Ended" "user" false true "startup" false "" false "" true
	sess "sess-dropped-other" "Dropped Other" "user" false true "startup" true "other" false "" true
	sess "sess-dropped-unknown" "Dropped Unknown" "user" false true "startup" true "some_later_reason" false "" true
	sess "sess-deliberate-end" "Deliberate End" "user" false true "startup" true "prompt_input_exit"
	sess "sess-closed-by-pass" "Closed By Pass" "user" false true "startup" true "closed-by-pass"
	sess "sess-desk-run" "Scheduled Run" "user" true true "desk-run" false "" true
	sess "sess-no-start-event" "No Start Event" "user" true false "startup" false ""
	# The last start event's own source is "resume" (the user opened the follow-up
	# tab and has been using it since) — the recorder's OWN
	# any_desk_run_start still says this session started life under
	# desk-run, so it must be excluded on that alone, never on the (now
	# stale) last-event source.
	sess "sess-desk-run-then-resumed" "Later Resumed" "user" true true "resume" false "" true
	# Excluded on its name alone (the runner's own visible-call naming
	# convention), even with a plain "startup" source and any_desk_run_start
	# unset — a defense-in-depth check, never relied on as the only one.
	sess "sess-desk-named" "desk-morning-2026-09-28-F" "user" true true "startup" false ""
	# Excluded on its cwd alone (under $DESK_RUNS_ROOT), even with a plain
	# name and source — the third, independent defense.
	sess "sess-runs-root-cwd" "Some Call" "user" true true "startup" false "" false "$DESK_RUNS_ROOT/morning-2026-09-28/F"
} > "$SESSION_STATUS_FIXTURE"

PASS_SCRATCH="$(mktemp -d)"
export PASS_SCRATCH

echo "=== a first capture pass ==="
result="$(desk_step_capture_sessions "morning" "$repo" "2026-09-28" "${files[@]}")"
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

assert_true "an end the reader does not count as deliberate (an unknown reason) is captured as dropped" \
	"$([ "$(by_sid sess-dropped-unknown | jq -r '.capture_kind')" = dropped ] && echo true || echo false)"

assert_true "a close step's close is never captured" \
	"$([ -z "$(by_sid sess-closed-by-pass)" ] && echo true || echo false)"

assert_true "a deliberate end (prompt_input_exit) is never captured" \
	"$([ -z "$(by_sid sess-deliberate-end)" ] && echo true || echo false)"

assert_true "source desk-run is excluded even though it's live" \
	"$([ -z "$(by_sid sess-desk-run)" ] && echo true || echo false)"

assert_true "no recorder start event at all is excluded" \
	"$([ -z "$(by_sid sess-no-start-event)" ] && echo true || echo false)"

assert_true "a desk-run session later resumed (last source now 'resume') is still excluded" \
	"$([ -z "$(by_sid sess-desk-run-then-resumed)" ] && echo true || echo false)"

assert_true "a session named like a visible call (desk-...) is excluded on its name alone" \
	"$([ -z "$(by_sid sess-desk-named)" ] && echo true || echo false)"

assert_true "a session whose cwd sits under the runs root is excluded on that alone" \
	"$([ -z "$(by_sid sess-runs-root-cwd)" ] && echo true || echo false)"

echo
echo "=== a second capture pass: already-ledgered captures never duplicate ==="
count_before="$(printf '%s' "$proposal" | jq '.items | length')"
rm -rf "$PASS_SCRATCH"
PASS_SCRATCH="$(mktemp -d)"
export PASS_SCRATCH
result="$(desk_step_capture_sessions "morning" "$repo" "2026-09-28" "${files[@]}")"
assert_eq "the second pass still reports ok" "ok" "$result"
proposal2="$(desk_nvim_cli proposal-read "$repo")"
count_after="$(printf '%s' "$proposal2" | jq '.items | length')"
assert_eq "the item count is unchanged (no duplicate captures)" "$count_before" "$count_after"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
