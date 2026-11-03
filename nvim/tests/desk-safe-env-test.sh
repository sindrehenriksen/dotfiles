#!/usr/bin/env bash
# tests/lib/git-safety.sh: desk_test_safe_env_init leaves a test that forgot
# an override with nothing real to reach (reader cache, tab focus, reader),
# and the real-state guard notices a file rewritten in place, not only one
# added or removed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

(
	export HOME="$ROOT/home"
	mkdir -p "$HOME/.local/state/claude" "$HOME/.local/state/desk"
	unset CLAUDE_SESSION_READER_CACHE DESK_FOCUS_TAB_BIN DESK_CLOSE_TAB_BIN DESK_WINDOW_BIN DESK_READER DESK_INHIBIT_BIN
	# shellcheck source=../../tests/lib/git-safety.sh
	source "$HERE/../../tests/lib/git-safety.sh"
	desk_test_safe_env_init "$ROOT/safe"

	under() { case "$1" in "$ROOT/safe"/*) echo true ;; *) echo false ;; esac; }
	assert_true "the reader cache is scoped to the temp dir" "$(under "${CLAUDE_SESSION_READER_CACHE:-}")"
	assert_true "the focus-tab helper is a stub under the temp dir" "$(under "${DESK_FOCUS_TAB_BIN:-}")"
	assert_true "the focus-tab stub refuses" "$("$DESK_FOCUS_TAB_BIN" /dev/ttys000 > /dev/null 2>&1 && echo false || echo true)"
	assert_true "the window helper is a stub under the temp dir" "$(under "${DESK_WINDOW_BIN:-}")"
	assert_true "the window stub refuses" "$("$DESK_WINDOW_BIN" tall > /dev/null 2>&1 && echo false || echo true)"
	assert_true "the close-tab helper is a stub under the temp dir" "$(under "${DESK_CLOSE_TAB_BIN:-}")"
	assert_true "the close-tab stub refuses" "$("$DESK_CLOSE_TAB_BIN" close T1 > /dev/null 2>&1 && echo false || echo true)"
	assert_true "the sleep inhibitor is a stub under the temp dir" "$(under "${DESK_INHIBIT_BIN:-}")"
	assert_true "the sleep-inhibitor stub refuses" "$("$DESK_INHIBIT_BIN" --mode=block true > /dev/null 2>&1 && echo false || echo true)"
	assert_true "the reader stub is under the temp dir" "$(under "${DESK_READER:-}")"
	assert_true "the reader stub sees no sessions" "$([ -z "$("$DESK_READER")" ] && echo true || echo false)"

	f="$HOME/.local/state/claude/cache.json"
	echo one > "$f"
	desk_test_state_guard_snapshot "$ROOT/guard" before
	echo two > "$f"
	desk_test_state_guard_snapshot "$ROOT/guard" after
	assert_true "an in-place rewrite of a real state file trips the guard" \
		"$(desk_test_state_guard_check "$ROOT/guard" before after > /dev/null 2>&1 && echo false || echo true)"
	mkdir -p "$HOME/.local/state/claude/locks" "$HOME/.local/state/claude/session-events"
	echo v1 > "$HOME/.local/state/claude/session-events/live.jsonl"
	desk_test_state_guard_snapshot "$ROOT/guard" live1
	echo v1 > "$HOME/.local/state/claude/locks/2.1.0.lock"
	echo v2 >> "$HOME/.local/state/claude/session-events/live.jsonl"
	desk_test_state_guard_snapshot "$ROOT/guard" live2
	assert_true "a live session appending to its event file, or a version lock appearing, is not a test touching state" \
		"$(desk_test_state_guard_check "$ROOT/guard" live1 live2 > /dev/null 2>&1 && echo true || echo false)"
	echo extra > "$HOME/.local/state/claude/session-events/fake.jsonl"
	desk_test_state_guard_snapshot "$ROOT/guard" live3
	assert_true "a new event file does trip it" \
		"$(desk_test_state_guard_check "$ROOT/guard" live2 live3 > /dev/null 2>&1 && echo false || echo true)"
	# A session that started mid-run: its event file counts only with a real transcript.
	export DESK_TEST_REAL_CONFIG_DIR="$ROOT/real-config"
	mkdir -p "$DESK_TEST_REAL_CONFIG_DIR/projects/-some-project"
	: > "$DESK_TEST_REAL_CONFIG_DIR/projects/-some-project/real-sess.jsonl"
	echo start > "$HOME/.local/state/claude/session-events/real-sess.jsonl"
	desk_test_state_guard_snapshot "$ROOT/guard" real1
	assert_true "a new event file whose session has a real transcript passes" \
		"$(desk_test_state_guard_check "$ROOT/guard" live3 real1 > /dev/null 2>&1 && echo true || echo false)"
	rm -f "$HOME/.local/state/claude/session-events/fake.jsonl"
	desk_test_state_guard_snapshot "$ROOT/guard" real2
	assert_true "...and with the fabricated one gone, only that real session was added: passes" \
		"$(desk_test_state_guard_check "$ROOT/guard" live2 real2 > /dev/null 2>&1 && echo true || echo false)"
	echo fab > "$HOME/.local/state/claude/session-events/fabricated.jsonl"
	desk_test_state_guard_snapshot "$ROOT/guard" real3
	assert_true "a test-written event file with no transcript still trips it" \
		"$(desk_test_state_guard_check "$ROOT/guard" real2 real3 > /dev/null 2>&1 && echo false || echo true)"
	desk_test_state_guard_snapshot "$ROOT/guard" again
	assert_true "an unchanged state passes the guard" \
		"$(desk_test_state_guard_check "$ROOT/guard" real3 again > /dev/null 2>&1 && echo true || echo false)"
	echo 1 > "$HOME/.local/state/claude/input-bell-real-sess"
	desk_test_state_guard_snapshot "$ROOT/guard" bell1
	assert_true "a live session ringing for the first time passes the guard" \
		"$(desk_test_state_guard_check "$ROOT/guard" again bell1 > /dev/null 2>&1 && echo true || echo false)"
	echo 2 > "$HOME/.local/state/claude/input-bell-real-sess"
	desk_test_state_guard_snapshot "$ROOT/guard" bell2
	assert_true "and rewriting its bell file passes too" \
		"$(desk_test_state_guard_check "$ROOT/guard" bell1 bell2 > /dev/null 2>&1 && echo true || echo false)"
	echo 1 > "$HOME/.local/state/claude/input-bell-fabricated"
	desk_test_state_guard_snapshot "$ROOT/guard" bell3
	assert_true "a bell file for a session with no transcript trips it" \
		"$(desk_test_state_guard_check "$ROOT/guard" bell2 bell3 > /dev/null 2>&1 && echo false || echo true)"

	# A live scheduled pass, as launchd starts one: the real defaults under
	# $HOME, its stderr appended to its log, and none of this shell's fds, since
	# launchd starts it. Under its lock it writes its state
	# file (the follow pass's follow-state.json, a scheduled pass's status
	# file), as the real passes do; denied it, it logs that it is skipping.
	live_pass() { # pass max_wait_secs [hold_secs]
		env -u DESK_STATE_DIR -u DESK_LOCK_ROOT -u DESK_STATUS_FILE bash -c '
			source "$1/claude/desk-lib/common.sh"
			source "$1/claude/desk-lib/lock.sh"
			state="$DESK_STATUS_FILE"
			if [ "$2" = follow ]; then
				DESK_LOCK_NAME="$DESK_FOLLOW_LOCK_NAME"
				state="$DESK_STATE_DIR/follow-state.json"
			fi
			if DESK_LOCK_MAX_WAIT_SECS="$3" DESK_LOCK_POLL_SECS=1 desk_lock_acquire; then
				date +%s.$RANDOM > "$state"
				sleep "${4:-0}"
			else
				desk_log "$2" "another run holds the lock — skipping"
			fi' _ "$HERE/../.." "$@" 2>> "$HOME/.local/state/desk/logs/$1.err.log" 7>&- 8>&-
	}
	desk_dir="$HOME/.local/state/desk"
	mkdir -p "$desk_dir/logs"
	live_pass follow 0
	live_pass morning 0
	desk_test_state_guard_snapshot "$ROOT/guard" lv1
	live_pass follow 0
	desk_test_state_guard_snapshot "$ROOT/guard" lv2
	assert_true "unheld, a live follow pass rewriting its state trips the guard" \
		"$(desk_test_state_guard_check "$ROOT/guard" lv1 lv2 > /dev/null 2>&1 && echo false || echo true)"

	desk_test_live_locks_hold 0 1
	assert_true "the suite takes the live passes' locks" "$([ $? -eq 0 ] && echo true || echo false)"
	desk_test_state_guard_snapshot "$ROOT/guard" lv3
	follow_log_before="$(wc -l < "$desk_dir/logs/follow.err.log")"
	live_pass follow 1
	status_before="$(cat "$desk_dir/status.json")"
	(desk_test_live_locks_release && live_pass morning 30) &
	morning_pid=$!
	sleep 2
	desk_test_state_guard_snapshot "$ROOT/guard" lv4
	assert_true "held, a follow pass firing meanwhile skips and only logs that it did" \
		"$([ "$(wc -l < "$desk_dir/logs/follow.err.log")" -gt "$follow_log_before" ] && echo true || echo false)"
	assert_true "held, the live passes firing meanwhile leave the guard quiet" \
		"$(desk_test_state_guard_check "$ROOT/guard" lv3 lv4 > /dev/null 2>&1 && echo true || echo false)"
	date +%s.$RANDOM > "$desk_dir/follow-state.json"
	desk_test_state_guard_snapshot "$ROOT/guard" lv5
	assert_true "held, a test writing the follow state itself still trips it" \
		"$(desk_test_state_guard_check "$ROOT/guard" lv4 lv5 > /dev/null 2>&1 && echo false || echo true)"
	echo leaked > "$desk_dir/logs/test.log"
	desk_test_state_guard_snapshot "$ROOT/guard" lv6
	assert_true "held, a new file under the log directory still trips it" \
		"$(desk_test_state_guard_check "$ROOT/guard" lv5 lv6 > /dev/null 2>&1 && echo false || echo true)"

	# What a suite leaves running inherits nothing once its subshell drops the fds.
	(desk_test_live_locks_release && exec sleep 30) &
	leftover_pid=$!
	desk_test_live_locks_release
	wait "$morning_pid"
	assert_true "a morning pass that waited out the suite runs once it ends, a test's leftover process notwithstanding" \
		"$([ "$(cat "$desk_dir/status.json")" != "$status_before" ] && echo true || echo false)"
	kill "$leftover_pid" 2> /dev/null

	live_pass follow 0 3 &
	holder_pid=$!
	sleep 1
	desk_test_live_locks_hold 0 1
	assert_true "while a live pass holds its lock, the suite can't take them" "$([ $? -ne 0 ] && echo true || echo false)"
	status_before="$(cat "$desk_dir/status.json")"
	live_pass morning 0
	assert_true "...and having given up holds neither" \
		"$([ "$(cat "$desk_dir/status.json")" != "$status_before" ] && echo true || echo false)"
	desk_test_live_locks_hold 10 1
	assert_true "...but waiting, takes them once that pass ends" "$([ $? -eq 0 ] && echo true || echo false)"
	desk_test_live_locks_release
	wait "$holder_pid"
) | tee "$ROOT/out"
grep -q FAIL "$ROOT/out" && fail=1 || fail=0
echo
echo "=== summary: $(grep -c '^ok' "$ROOT/out") passed, $(grep -c '^FAIL' "$ROOT/out") failed ==="
[ "$fail" -eq 0 ]
