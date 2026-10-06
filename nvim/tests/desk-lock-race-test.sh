#!/usr/bin/env bash
# D8 fix test (review item #4): claude/desk-lib/lock.sh's desk_lock_acquire/
# desk_lock_release, rewritten so meta.json is built in a temp dir under the
# lock's own parent and moved into place right after `mkdir` wins the race
# (never written into the lock dir as a second, separate step), a waiter
# that sees a lock dir with no meta.json yet treats it as held for a short
# grace period rather than as dead, a recorded owner's start time is
# compared against the same pid's current one (pid reuse), and a release
# only ever removes a lock this process itself owns.
#
# Deterministic by construction, never a real two-process race: every case
# here pre-seeds the lock directory's own on-disk state by hand (a lock dir
# with no meta.json yet, a meta.json naming a live-but-wrong-start-time pid,
# a meta.json naming a different owner) and drives desk_lock_acquire/
# desk_lock_release against it directly, with tiny overridden grace/poll
# windows — this is what the old mkdir-then-separately-write-meta version
# could only be exercised against via two real racing processes, which is
# exactly what made a "dead lock owner" test here flaky (a waiter could
# observe the winner's lock dir microseconds before its meta.json landed).
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
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_LOCK_MAX_WAIT_SECS=6
export DESK_LOCK_POLL_SECS=1
export DESK_LOCK_NO_META_GRACE_SECS=2

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"

lockdir="$DESK_LOCK_DIR/runner.lock"

echo "=== a fresh acquire builds meta.json via a temp dir under the lock parent ==="
got="$(desk_lock_acquire testpass)"
assert_eq "prints the lock dir" "$lockdir" "$got"
assert_true "meta.json exists" "$([ -f "$lockdir/meta.json" ] && echo true || echo false)"
assert_eq "meta.json's own pid is this process" "$$" "$(jq -r '.pid' "$lockdir/meta.json")"
assert_true "owner_start was recorded" \
	"$([ "$(jq -r '.owner_start' "$lockdir/meta.json")" != "null" ] && echo true || echo false)"
assert_true "no leftover .tmp-lock.* staging dir" \
	"$([ -z "$(find "$DESK_LOCK_DIR" -maxdepth 1 -name '.tmp-lock.*' 2> /dev/null)" ] && echo true || echo false)"
desk_lock_release
assert_true "release removes the lock this process owns" "$([ ! -d "$lockdir" ] && echo true || echo false)"

echo
echo "=== a lock dir with no meta.json yet: held for a grace period, never as dead ==="
mkdir -p "$lockdir"
t0=$(date +%s)
got="$(desk_lock_acquire testpass)"
t1=$(date +%s)
assert_eq "acquires it once the grace period elapses" "$lockdir" "$got"
assert_true "it actually waited roughly the grace period, not zero" \
	"$([ $((t1 - t0)) -ge "$DESK_LOCK_NO_META_GRACE_SECS" ] && echo true || echo false)"
assert_true "it did not wait the full max-wait budget either" \
	"$([ $((t1 - t0)) -lt "$DESK_LOCK_MAX_WAIT_SECS" ] && echo true || echo false)"
desk_lock_release

echo
echo "=== a live pid whose start time no longer matches the recorded one (reuse): broken immediately ==="
mkdir -p "$lockdir"
# $$ is genuinely alive (this very shell), but a start_epoch far from its
# real one — the same shape a dead owner's pid, reused by an unrelated
# later process, would produce.
jq -n --arg pass testpass --argjson pid "$$" --argjson started_at 1 --argjson owner_start 1 \
	'{pass: $pass, pid: $pid, started_at: $started_at, owner_start: $owner_start}' \
	> "$lockdir/meta.json"
t0=$(date +%s)
got="$(desk_lock_acquire testpass)"
t1=$(date +%s)
assert_eq "acquires it" "$lockdir" "$got"
assert_true "broke it immediately rather than waiting out the grace/poll windows" \
	"$([ $((t1 - t0)) -lt "$DESK_LOCK_NO_META_GRACE_SECS" ] && echo true || echo false)"
assert_eq "meta.json now records this process as owner" "$$" "$(jq -r '.pid' "$lockdir/meta.json")"
desk_lock_release

echo
echo "=== a live owner with a matching start time: waited out, never broken ==="
mkdir -p "$lockdir"
my_start="$(desk_pid_start_epoch "$$")"
jq -n --arg pass otherpass --argjson pid "$$" --argjson started_at 1 --argjson owner_start "$my_start" \
	'{pass: $pass, pid: $pid, started_at: $started_at, owner_start: $owner_start}' \
	> "$lockdir/meta.json"
got="$(desk_lock_acquire testpass)"
rc_after_wait=$?
assert_true "gives up waiting rather than breaking a lock a genuinely live, matching owner holds" \
	"$([ -z "$got" ] && [ "$rc_after_wait" -ne 0 ] && echo true || echo false)"
rm -rf "$lockdir"

echo
echo "=== release only ever removes a lock this process owns ==="
mkdir -p "$lockdir"
jq -n --arg pass otherpass --argjson pid 999999 --argjson started_at 1 --argjson owner_start 1 \
	'{pass: $pass, pid: $pid, started_at: $started_at, owner_start: $owner_start}' \
	> "$lockdir/meta.json"
desk_lock_release
assert_true "a lock owned by a different pid is left alone" "$([ -d "$lockdir" ] && echo true || echo false)"
rm -rf "$lockdir"

echo
echo "=== two waiters see the same dead owner: only one breaks it, never the lock the other then takes ==="
mkdir -p "$lockdir"
dead_pid=999999
while kill -0 "$dead_pid" 2> /dev/null; do dead_pid=$((dead_pid + 1)); done
jq -n --arg pass otherpass --argjson pid "$dead_pid" --argjson started_at 1 --argjson owner_start 1 \
	'{pass: $pass, pid: $pid, started_at: $started_at, owner_start: $owner_start}' \
	> "$lockdir/meta.json"
rm -f "$ROOT/b-judged" "$ROOT/a-holds" "$ROOT/b-result"
wait_for_file() { local n=0; while [ ! -e "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done; }
# Waiter B has judged the owner dead and is held just before it acts, while
# waiter A breaks the lock, takes it and holds it.
(
	desk_lock_pre_break() { : > "$ROOT/b-judged"; wait_for_file "$ROOT/a-holds"; sleep 0.3; }
	DESK_LOCK_MAX_WAIT_SECS=0
	got_b="$(desk_lock_acquire waiter-b)"
	echo "${got_b:-none}" > "$ROOT/b-result"
) &
b_pid=$!
wait_for_file "$ROOT/b-judged"
(
	got_a="$(desk_lock_acquire waiter-a)"
	if [ -n "$got_a" ]; then
		: > "$ROOT/a-holds"
		sleep 1
		if [ "$(jq -r '.pass' "$got_a/meta.json" 2> /dev/null)" = "waiter-a" ]; then
			echo intact > "$ROOT/a-result"
		else
			echo destroyed > "$ROOT/a-result"
		fi
		desk_lock_release
	fi
) &
a_pid=$!
wait "$a_pid" "$b_pid" 2> /dev/null
assert_eq "the lock A took was still its own after B acted on its stale judgement" "intact" "$(cat "$ROOT/a-result" 2> /dev/null)"
assert_eq "B never got the lock A held" "none" "$(cat "$ROOT/b-result" 2> /dev/null)"
assert_true "no stale or guard dir is left behind" \
	"$([ -z "$(find "$DESK_LOCK_DIR" -maxdepth 1 \( -name '*.stale.*' -o -name '*.break' \) 2> /dev/null)" ] && echo true || echo false)"
rm -rf "$lockdir"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
