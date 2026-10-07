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
	unset CLAUDE_SESSION_READER_CACHE DESK_FOCUS_TAB_BIN DESK_READER
	# shellcheck source=../../tests/lib/git-safety.sh
	source "$HERE/../../tests/lib/git-safety.sh"
	desk_test_safe_env_init "$ROOT/safe"

	under() { case "$1" in "$ROOT/safe"/*) echo true ;; *) echo false ;; esac; }
	assert_true "the reader cache is scoped to the temp dir" "$(under "${CLAUDE_SESSION_READER_CACHE:-}")"
	assert_true "the focus-tab helper is a stub under the temp dir" "$(under "${DESK_FOCUS_TAB_BIN:-}")"
	assert_true "the focus-tab stub refuses" "$("$DESK_FOCUS_TAB_BIN" /dev/ttys000 > /dev/null 2>&1 && echo false || echo true)"
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
) | tee "$ROOT/out"
grep -q FAIL "$ROOT/out" && fail=1 || fail=0
echo
echo "=== summary: $(grep -c '^ok' "$ROOT/out") passed, $(grep -c '^FAIL' "$ROOT/out") failed ==="
[ "$fail" -eq 0 ]
