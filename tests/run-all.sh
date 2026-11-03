#!/usr/bin/env bash
# Runs every test suite in this repo, by explicit name: nvim/tests/*.sh,
# nvim/tests/*.lua (headless, via `nvim -u minimal_init.lua -l <file>`),
# claude/tests/*.sh, git-hooks/test-*.sh. Never
# nvim/tests/desk-run-canary-restricted.sh, which makes a live model call
# under DESK_CANARY_LIVE and is run by hand. Independent suites run side by
# side, $DESK_TEST_JOBS at a time (default half the cores); those on
# SERIAL_SUITES, which time something, run one at a time after them.
#
# Wraps the whole run in the config guard (tests/lib/git-safety.sh):
# snapshots `git config --local --list` for each repo in $DESK_GUARD_REPOS
# (colon-separated; default: this repo's own main checkout) before
# anything runs, and fails loudly if any of it changed by the end — the
# belt to the per-test isolation's suspenders, so a test that slips past
# its own guard still can't corrupt a real repo's config unnoticed. The
# state guard does the same for real ~/.local/state/{claude,desk}, with the
# live desk passes' locks held throughout so a scheduled pass can't trip it.
#
# Usage: tests/run-all.sh (from anywhere; run-all.sh finds its own repo)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=lib/git-safety.sh
source "$HERE/lib/git-safety.sh"

if ! desk_test_config_guard_resolve_repos "$REPO_ROOT"; then
	echo "run-all: couldn't resolve a guard repo for $REPO_ROOT (and \$DESK_GUARD_REPOS is unset) — refusing to run" >&2
	exit 1
fi

# The live desk passes' locks, held from before the first snapshot to after
# the last (git-safety.sh, desk_test_live_locks_hold): a scheduled pass never
# writes real state mid-suite, so the state guard sees only what tests did.
if ! desk_test_live_locks_hold 0; then
	echo "run-all: a live desk pass holds its lock — waiting for it to finish (up to ${DESK_TEST_LIVE_LOCK_WAIT_SECS:-1800}s)" >&2
	if ! desk_test_live_locks_hold "${DESK_TEST_LIVE_LOCK_WAIT_SECS:-1800}"; then
		echo "run-all: gave up waiting for the live desk pass — refusing to run" >&2
		exit 1
	fi
fi

GUARD_DIR="$(mktemp -d)"
trap 'rm -rf "$GUARD_DIR"' EXIT
desk_test_config_guard_snapshot "$GUARD_DIR" before
desk_test_state_guard_snapshot "$GUARD_DIR" before

# --- explicit suite lists (never a glob — a new file here doesn't run
# until it's named below, and the canary is never named at all) --

BASH_SUITES=(
	nvim/tests/desk-brief-test.sh
	nvim/tests/desk-close-test.sh
	nvim/tests/desk-deny-hook-test.sh
	nvim/tests/desk-line-key-test.sh
	nvim/tests/desk-lock-test.sh
	nvim/tests/desk-max-budget-test.sh
	nvim/tests/desk-notes-diff-test.sh
	nvim/tests/desk-propose-test.sh
	nvim/tests/desk-push-test.sh
	nvim/tests/desk-render-prompt-test.sh
	nvim/tests/desk-run-at-load-test.sh
	nvim/tests/desk-run-test.sh
	nvim/tests/desk-runner-lock-test.sh
	nvim/tests/desk-restricted-argv-test.sh
	nvim/tests/desk-safe-env-test.sh
	nvim/tests/desk-sleep-inhibit-test.sh
	nvim/tests/desk-status-sh-test.sh
	nvim/tests/desk-supersede-test.sh
	nvim/tests/desk-ticket-cache-test.sh
	nvim/tests/desk-timeout-test.sh
	nvim/tests/desk-validate-test.sh
	nvim/tests/desk-follow-test.sh
	claude/tests/close-session-test.sh
	claude/tests/compact-handoff-test.sh
	claude/tests/input-bell-test.sh
	claude/tests/reopen-sessions-test.sh
	claude/tests/session-recorder-test.sh
	claude/tests/session-status-resolve-test.sh
	claude/tests/session-status-human-test.sh
	claude/tests/session-status-title-test.sh
	claude/tests/session-two-process-test.sh
	claude/tests/session-end-kind-test.sh
	git-hooks/test-commit-msg.sh
	hammerspoon/tests/hs-timeout-test.sh
	linux/desk/tests/tabs-test.sh
	git-hooks/test-desk-denylist.sh
	tests/shellrc-desk-switch-test.sh
)

LUA_SUITES=(
	nvim/tests/desk-annotate-test.lua
	nvim/tests/desk-apply-test.lua
	nvim/tests/desk-autosave-test.lua
	nvim/tests/desk-conceal-test.lua
	nvim/tests/desk-hotkey-test.lua
	nvim/tests/desk-inline-test.lua
	nvim/tests/desk-ledger-test.lua
	nvim/tests/desk-proposal-test.lua
	nvim/tests/desk-review-test.lua
	nvim/tests/desk-status-test.lua
	nvim/tests/desk-tokens-test.lua
	nvim/tests/diskmerge-test.lua
	nvim/tests/mdlink-test.lua
)

# Plain-Lua suites: run with the system `lua`, never nvim/Hammerspoon (each
# file's own header says so) — hammerspoon/tests/tab-function-test.lua
# loads hammerspoon/init.lua against a minimal hs.* stub.
PLAIN_LUA_SUITES=(
	hammerspoon/tests/tab-function-test.lua
)

# Suites that hold something to the wall clock (a short timeout or grace
# period, a lock wait that must run out or must not, an elapsed-time
# assertion) run one at a time after the rest, with the machine otherwise
# idle: under load they fail for the machine's sake, not the code's. A wait
# for a condition with seconds to spare, or a vim.wait that only drains
# queued events (desk's Lua starts no timers), is not that. Every other
# suite runs alongside others, $DESK_TEST_JOBS at a time. They can, because
# each has its own mktemp root, its own throwaway repos (so its own stash
# list), no port and no fixed path it writes, and each gets its own safe
# defaults below. A new suite that times anything belongs on this list.
SERIAL_SUITES=(
	nvim/tests/desk-close-test.sh
	nvim/tests/desk-run-test.sh
	nvim/tests/desk-runner-lock-test.sh
	nvim/tests/desk-safe-env-test.sh
	nvim/tests/desk-sleep-inhibit-test.sh
	nvim/tests/desk-timeout-test.sh
	claude/tests/close-session-test.sh
	claude/tests/compact-handoff-test.sh
	claude/tests/input-bell-test.sh
	claude/tests/reopen-sessions-test.sh
	hammerspoon/tests/hs-timeout-test.sh
	linux/desk/tests/tabs-test.sh
	nvim/tests/desk-hotkey-test.lua
)

if [ -z "${DESK_TEST_JOBS:-}" ]; then
	DESK_TEST_JOBS="$( (sysctl -n hw.ncpu || nproc) 2> /dev/null)"
	DESK_TEST_JOBS=$(((${DESK_TEST_JOBS:-2} + 1) / 2))
fi

JOBS_DIR="$GUARD_DIR/jobs"
mkdir -p "$JOBS_DIR"
pass_suites=0
fail_suites=0
failed_names=()
suite_rel=()
suite_cmd=()

suite_add() { # relative_path, runner (bash | nvim | lua)
	suite_rel+=("$1")
	suite_cmd+=("$2")
}

is_serial() {
	local s
	for s in "${SERIAL_SUITES[@]}"; do [ "$s" = "$1" ] && return 0; done
	return 1
}

# Runs suite $1 (an index) in the background. Its output goes to its own
# file, printed whole once it ends, so suites running side by side never
# interleave. It drops the parent's live-lock fds first and gets its own
# safe, temp-scoped defaults (git-safety.sh, desk_test_safe_env_init): a
# suite that forgets an override falls through to a refusing stub or a
# throwaway dir of its own, never real state, a live `claude`, or another
# suite's files. A suite's own explicit export still wins.
suite_start() {
	local i="$1" rel="${suite_rel[$1]}" d="$JOBS_DIR/$1"
	mkdir -p "$d"
	(
		desk_test_live_locks_release
		desk_test_safe_env_init "$d/safe-env"
		cd "$REPO_ROOT" || exit 1
		t0=$SECONDS
		case "${suite_cmd[$i]}" in
			bash) bash "$rel" ;;
			nvim) nvim --headless -u nvim/tests/minimal_init.lua -l "$rel" ;;
			lua) lua "$rel" ;;
		esac > "$d/out" 2>&1 < /dev/null
		rc=$?
		echo "$rc $((SECONDS - t0))" > "$d/rc.tmp"
		mv "$d/rc.tmp" "$d/rc"
	) &
}

suite_report() { # index
	local i="$1" rel="${suite_rel[$1]}" d="$JOBS_DIR/$1" rc secs
	read -r rc secs < "$d/rc"
	if [ "$rc" -eq 0 ]; then
		printf '\n=== %s (%ss) ===\n' "$rel" "$secs"
		pass_suites=$((pass_suites + 1))
	else
		printf '\n=== %s (%ss) FAILED, exit %s ===\n' "$rel" "$secs" "$rc"
		fail_suites=$((fail_suites + 1))
		failed_names+=("$rel")
	fi
	cat "$d/out"
}

# Runs the suites named by index in $@, up to $DESK_TEST_JOBS at a time,
# reporting each as it ends.
run_pool() {
	local queue=("$@") running=() still i
	while [ "${#queue[@]}" -gt 0 ] || [ "${#running[@]}" -gt 0 ]; do
		while [ "${#queue[@]}" -gt 0 ] && [ "${#running[@]}" -lt "$DESK_TEST_JOBS" ]; do
			suite_start "${queue[0]}"
			running+=("${queue[0]}")
			queue=("${queue[@]:1}")
		done
		still=()
		for i in "${running[@]}"; do
			if [ -f "$JOBS_DIR/$i/rc" ]; then suite_report "$i"; else still+=("$i"); fi
		done
		running=("${still[@]}")
		[ "${#running[@]}" -gt 0 ] && sleep 0.2
	done
	wait
}

for rel in "${BASH_SUITES[@]}"; do suite_add "$rel" bash; done
for rel in "${LUA_SUITES[@]}"; do suite_add "$rel" nvim; done
for rel in "${PLAIN_LUA_SUITES[@]}"; do suite_add "$rel" lua; done

parallel=()
serial=()
for i in "${!suite_rel[@]}"; do
	if is_serial "${suite_rel[$i]}"; then serial+=("$i"); else parallel+=("$i"); fi
done
for s in "${SERIAL_SUITES[@]}"; do
	found=""
	for rel in "${suite_rel[@]}"; do [ "$rel" = "$s" ] && found=1; done
	[ -n "$found" ] || echo "run-all: $s is on SERIAL_SUITES but not in any suite list" >&2
done

run_started=$SECONDS
echo "run-all: ${#parallel[@]} suite(s) $DESK_TEST_JOBS at a time, then ${#serial[@]} one at a time"
run_pool "${parallel[@]}"
DESK_TEST_JOBS=1 run_pool "${serial[@]}"

desk_test_config_guard_snapshot "$GUARD_DIR" after
desk_test_state_guard_snapshot "$GUARD_DIR" after
desk_test_live_locks_release

echo
echo "=== run-all summary: $pass_suites suite(s) passed, $fail_suites failed, in $((SECONDS - run_started))s ==="
if [ "$fail_suites" -gt 0 ]; then
	printf 'Failed: %s\n' "${failed_names[@]}"
fi

guard_status=0
if ! desk_test_config_guard_check "$GUARD_DIR" before after; then
	guard_status=1
	echo "=== run-all: CONFIG GUARD TRIPPED — a test changed a guarded repo's local git config ===" >&2
fi
if ! desk_test_state_guard_check "$GUARD_DIR" before after; then
	guard_status=1
	echo "=== run-all: STATE GUARD TRIPPED — a test touched real ~/.local/state/claude or ~/.local/state/desk ===" >&2
fi

[ "$fail_suites" -eq 0 ] && [ "$guard_status" -eq 0 ]
