#!/usr/bin/env bash
# What reaches the follow-up prompts from a pass's own files:
# desk_follow_up_placeholders carries the chat notes and the scheduled
# date; desk_failed_source_reason says why a
# fetch failed from how its call ended. No model call, no repo.
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

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export DESK_STATE_DIR="$ROOT/state"
export DESK_STATUS_FILE="$ROOT/state/status.json"
export DESK_CONFIG="$ROOT/config.json"
echo '{"passes":{"morning":{"steps":[{"id":"F-web","kind":"fetch"},{"id":"close","kind":"close"},{"id":"J","kind":"judge"}]}}}' > "$DESK_CONFIG"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

PASS_SCRATCH="$ROOT/pass"
mkdir -p "$PASS_SCRATCH"

echo "=== desk_failed_source_reason ==="
assert_eq "no call ending recorded: the call never ran" "its call never ran" "$(desk_failed_source_reason F-a failed)"
assert_eq "a timeout" "its call ran out of time" "$(desk_failed_source_reason F-a timeout)"
echo "error_max_budget_usd, 34s" > "$PASS_SCRATCH/F-b.call-end"
assert_eq "an ending other than success" "its call ended error_max_budget_usd, 34s" "$(desk_failed_source_reason F-b failed)"
echo "success, 12s" > "$PASS_SCRATCH/F-c.call-end"
assert_eq "a successful call whose result was unusable" \
	"its call ran, but its result could not be used (the log says why)" "$(desk_failed_source_reason F-c failed)"

echo
echo "=== desk_follow_up_placeholders: chat notes and scheduled date ==="
printf '%s\n' '[{"text":"Model X in preview","source":"https://example.com/x","home":"a models section"}]' > "$PASS_SCRATCH/chat-notes.json"
desk_status_set_result morning partial "" '["close"]' 2026-10-09 > /dev/null
ph="$(desk_follow_up_placeholders morning 2026-10-09 "")"
assert_eq "the close step leaves the follow-up prompts nothing to offer" "false" "$(jq 'has("close_offer")' <<< "$ph")"
assert_eq "the chat notes reach them" "Model X in preview|a models section" "$(jq -r '.chat_notes | fromjson | .[0] | "\(.text)|\(.home)"' <<< "$ph")"
assert_eq "and the scheduled date, not today's" "2026-10-09" "$(jq -r '.scheduled_date' <<< "$ph")"
assert_eq "the run status names the failed step and the close step's job" "true" \
	"$(jq -r '.run_status | (contains("these steps failed, and nothing reruns them on its own: close") and contains("close (listing idle sessions to offer for closing)"))' <<< "$ph")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
