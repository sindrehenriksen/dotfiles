#!/usr/bin/env bash
# D8b test: claude/desk-lib/lock.sh's guard, keyed on the slot's *scheduled*
# date rather than the date desk-run happens to be invoked on.
# Covers desk_scheduled_date_for directly (the wake-next-morning case, and its symmetric "same evening" case) plus
# desk_guard_already_ok_today against a hand-written status file — never
# through desk-run itself, so this suite isolates the date arithmetic from
# the runner's own guard-call wiring (already covered by desk-run-test.sh's
# "later slot" cases).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

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
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then
		ok "$desc"
	else
		bad "$desc (expected [$expected], got [$actual])"
	fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/lock.sh"
source "$LIB/lock.sh"

epoch_at() { desk_epoch_at "$1" "$2" "$3"; }

echo "=== desk_scheduled_date_for: no trigger configured falls back to \$2's own date ==="
now="$(epoch_at 2026-01-05 10 00)"
assert_eq "empty slot list -> now's own calendar date" "2026-01-05" \
	"$(desk_scheduled_date_for '[]' "$now")"
assert_eq "missing arg (default \"[]\") does the same" "2026-01-05" \
	"$(desk_scheduled_date_for "" "$now")"

echo
echo "=== desk_scheduled_date_for: the wake-next-morning case (Interfaces brief) ==="
slots='[{"hour":16,"minute":30}]'
# Day 1's 16:30 slot never actually ran (machine asleep); the pass instead
# runs on Day 2's morning wake, well before Day 2's own 16:30.
now="$(epoch_at 2026-01-06 08 00)"
assert_eq "a next-morning wake still reads as yesterday evening's slot" "2026-01-05" \
	"$(desk_scheduled_date_for "$slots" "$now")"

echo
echo "=== desk_scheduled_date_for: symmetric case — the same evening's real slot is not a repeat ==="
now="$(epoch_at 2026-01-06 16 30)"
assert_eq "today's own 16:30 firing on time reads as today's own slot" "2026-01-06" \
	"$(desk_scheduled_date_for "$slots" "$now")"
now="$(epoch_at 2026-01-06 16 45)"
assert_eq "a few minutes after the slot still reads as today's" "2026-01-06" \
	"$(desk_scheduled_date_for "$slots" "$now")"
now="$(epoch_at 2026-01-06 16 29)"
assert_eq "a minute before the slot still reads as yesterday's (slot hasn't fired yet)" "2026-01-05" \
	"$(desk_scheduled_date_for "$slots" "$now")"

echo
echo "=== desk_scheduled_date_for: a weekly slot (weekday-pinned) skips other days ==="
# Wednesday-only slot at 09:00. Thursday morning's own scheduled date is
# still Wednesday's, not Thursday's (no Thursday slot exists).
weekly='[{"hour":9,"minute":0,"weekday":3}]'
now="$(epoch_at 2026-01-08 10 00)" # Thursday 2026-01-08
assert_eq "a weekday-pinned slot: Thursday morning reads back to Wednesday's slot" "2026-01-07" \
	"$(desk_scheduled_date_for "$weekly" "$now")"

echo
echo "=== desk_guard_already_ok_today: keyed on scheduled_date, not last_run's date ==="
desk_status_set_result "testpass" "ok" "" "[]" "2026-01-05"
assert_eq "the same scheduled date reads as already done" "true" \
	"$(desk_guard_already_ok_today "testpass" "2026-01-05" && echo true || echo false)"
assert_eq "a later slot's own (different) scheduled date is not a repeat" "false" \
	"$(desk_guard_already_ok_today "testpass" "2026-01-06" && echo true || echo false)"

echo "--- a failed pass is never treated as already-done, whatever the scheduled date ---"
desk_status_set_result "otherpass" "failed" "some-step" "[]" "2026-01-05"
assert_eq "a failed result never counts as already-ok" "false" \
	"$(desk_guard_already_ok_today "otherpass" "2026-01-05" && echo true || echo false)"

echo
echo "=== desk_working_days_since: an exact Mon-Fri walk ==="
# 2026-01-05 is a Monday.
since="$(epoch_at 2026-01-05 09 00)"
same_day="$(epoch_at 2026-01-05 17 00)"
assert_eq "same calendar date: 0 working days" "0" "$(desk_working_days_since "$since" "$same_day")"
next_day="$(epoch_at 2026-01-06 09 00)" # Tuesday
assert_eq "the next weekday: 1 working day" "1" "$(desk_working_days_since "$since" "$next_day")"
across_weekend="$(epoch_at 2026-01-09 09 00)" # Friday
assert_eq "Mon to Fri (same week): 4 working days" "4" "$(desk_working_days_since "$since" "$across_weekend")"
past_weekend="$(epoch_at 2026-01-12 09 00)" # the following Monday
assert_eq "Mon to the next Mon: 5 working days (the weekend doesn't count)" "5" \
	"$(desk_working_days_since "$since" "$past_weekend")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
