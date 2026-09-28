#!/usr/bin/env bash
# D8 fix test (review item #1): claude/desk-lib/status.sh's `last_ok_run`
# field survives a fresh desk_status_set_running — before this fix,
# desk_status_set_running replaced the whole per-pass record, so
# desk_status_last_ok_run (keyed on "the current record's own result ==
# ok") went blind the moment the next run started, including for a caller
# *inside that same pass* (the close step's away-days valve, and the
# Gmail-window lookback, both of which call it mid-run).
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

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"

echo "=== a successful run's own last_run becomes last_ok_run ==="
desk_status_set_running "morning"
run1_last_run="$(jq -r '.passes.morning.last_run' "$DESK_STATUS_FILE")"
desk_status_set_result "morning" "ok" "" "[]" "2026-01-05"
assert_eq "last_ok_run equals this run's own last_run" "$run1_last_run" \
	"$(jq -r '.passes.morning.last_ok_run' "$DESK_STATUS_FILE")"

echo
echo "=== a fresh desk_status_set_running does NOT wipe last_ok_run ==="
sleep 1
desk_status_set_running "morning"
assert_eq "the current record now reads 'running'" "running" "$(jq -r '.passes.morning.result' "$DESK_STATUS_FILE")"
assert_eq "last_ok_run still holds the previous successful run's last_run" "$run1_last_run" \
	"$(jq -r '.passes.morning.last_ok_run' "$DESK_STATUS_FILE")"
assert_true "desk_status_last_ok_run answers correctly mid-run (result == running right now)" \
	"$([ "$(desk_status_last_ok_run "morning")" = "$run1_last_run" ] && echo true || echo false)"

echo
echo "=== a failed run leaves last_ok_run exactly as it was ==="
desk_status_set_result "morning" "failed" "F-test" "[\"F-test\"]" "2026-01-06"
assert_eq "result is failed" "failed" "$(jq -r '.passes.morning.result' "$DESK_STATUS_FILE")"
assert_eq "last_ok_run is unchanged by the failed run" "$run1_last_run" \
	"$(jq -r '.passes.morning.last_ok_run' "$DESK_STATUS_FILE")"

echo
echo "=== a pass that's never succeeded reports no last_ok_run at all ==="
desk_status_set_running "neverok"
desk_status_set_result "neverok" "failed" "F-test" "[]" "2026-01-05"
assert_eq "desk_status_last_ok_run is empty" "" "$(desk_status_last_ok_run "neverok")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
