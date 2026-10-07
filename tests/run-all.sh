#!/usr/bin/env bash
# Runs every test suite in this repo, by explicit name: nvim/tests/*.sh,
# nvim/tests/*.lua (headless, via `nvim -u minimal_init.lua -l <file>`),
# claude/tests/*.sh, git-hooks/test-*.sh. Deliberately never
# nvim/tests/desk-run-canary.sh — it drives a live model call under
# DESK_CANARY_LIVE and is run by hand, never by an automated runner.
#
# Wraps the whole run in the config guard (tests/lib/git-safety.sh):
# snapshots `git config --local --list` for each repo in $DESK_GUARD_REPOS
# (colon-separated; default: this repo's own main checkout) before
# anything runs, and fails loudly if any of it changed by the end — the
# belt to the per-test isolation's suspenders, so a test that slips past
# its own guard still can't corrupt a real repo's config unnoticed.
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

GUARD_DIR="$(mktemp -d)"
trap 'rm -rf "$GUARD_DIR"' EXIT
desk_test_config_guard_snapshot "$GUARD_DIR" before
desk_test_state_guard_snapshot "$GUARD_DIR" before

# Safe, temp-scoped defaults for every suite below (see git-safety.sh's own
# desk_test_safe_env_init): a suite that forgets to override one of these
# itself now falls through to a refusing stub or a throwaway dir, never the
# real ~/.local/state/{claude,desk} or a live `claude` invocation. Exported
# here, once, before the first suite runs; any suite's own explicit export
# still wins inside its own subshell.
desk_test_safe_env_init "$GUARD_DIR/safe-env"

# --- explicit suite lists (never a glob — a new file here doesn't run
# until it's named below, and desk-run-canary.sh is never named at all) --

BASH_SUITES=(
	nvim/tests/desk-capture-sessions-test.sh
	nvim/tests/desk-cli-test.sh
	nvim/tests/desk-cli-tokens-test.sh
	nvim/tests/desk-close-recheck-test.sh
	nvim/tests/desk-close-test.sh
	nvim/tests/desk-deny-hook-test.sh
	nvim/tests/desk-example-instance-test.sh
	nvim/tests/desk-fetch-window-test.sh
	nvim/tests/desk-followup-tab-test.sh
	nvim/tests/desk-followup-summary-test.sh
	nvim/tests/desk-followup-upper-c-test.sh
	nvim/tests/desk-generic-config-test.sh
	nvim/tests/desk-headless-env-test.sh
	nvim/tests/desk-judge-inputs-test.sh
	nvim/tests/desk-judge-invalid-reply-test.sh
	nvim/tests/desk-lock-race-test.sh
	nvim/tests/desk-lock-test.sh
	nvim/tests/desk-max-budget-test.sh
	nvim/tests/desk-notes-diff-test.sh
	nvim/tests/desk-open-tab-test.sh
	nvim/tests/desk-pass-config-test.sh
	nvim/tests/desk-partial-proposal-test.sh
	nvim/tests/desk-push-test.sh
	nvim/tests/desk-render-prompt-test.sh
	nvim/tests/desk-run-at-load-test.sh
	nvim/tests/desk-run-morning-integration-test.sh
	nvim/tests/desk-run-test.sh
	nvim/tests/desk-runner-lock-test.sh
	nvim/tests/desk-restricted-argv-test.sh
	nvim/tests/desk-retention-test.sh
	nvim/tests/desk-safe-env-test.sh
	nvim/tests/desk-scoped-read-test.sh
	nvim/tests/desk-stage-proposal-namespace-test.sh
	nvim/tests/desk-status-fields-test.sh
	nvim/tests/desk-status-sh-test.sh
	nvim/tests/desk-steps-mcp-config-test.sh
	nvim/tests/desk-supersede-test.sh
	nvim/tests/desk-ticket-cache-test.sh
	nvim/tests/desk-timeout-test.sh
	nvim/tests/desk-url-allowlist-test.sh
	nvim/tests/desk-validate-test.sh
	nvim/tests/desk-visible-run-test.sh
	nvim/tests/desk-w-count-check-test.sh
	nvim/tests/desk-watch-test.sh
	nvim/tests/desk-write-pinned-test.sh
	nvim/tests/desk-write-step-kind-test.sh
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
	hammerspoon/tests/tabs-live-check-selftest.sh
	git-hooks/test-desk-denylist.sh
)

LUA_SUITES=(
	nvim/tests/desk-annotate-test.lua
	nvim/tests/desk-apply-test.lua
	nvim/tests/desk-hotkey-test.lua
	nvim/tests/desk-ledger-test.lua
	nvim/tests/desk-proposal-test.lua
	nvim/tests/desk-review-test.lua
	nvim/tests/desk-status-test.lua
	nvim/tests/desk-tokens-test.lua
)

# Plain-Lua suites: run with the system `lua`, never nvim/Hammerspoon (each
# file's own header says so) — hammerspoon/tests/tab-function-test.lua
# loads hammerspoon/init.lua against a minimal hs.* stub.
PLAIN_LUA_SUITES=(
	hammerspoon/tests/tab-function-test.lua
)

pass_suites=0
fail_suites=0
failed_names=()

run_suite() { # relative_path, run_cmd...
	local rel="$1"
	shift
	printf '\n=== %s ===\n' "$rel"
	if ( cd "$REPO_ROOT" && "$@" ); then
		pass_suites=$((pass_suites + 1))
	else
		fail_suites=$((fail_suites + 1))
		failed_names+=("$rel")
	fi
}

for rel in "${BASH_SUITES[@]}"; do
	run_suite "$rel" bash "$rel"
done

for rel in "${LUA_SUITES[@]}"; do
	run_suite "$rel" nvim --headless -u nvim/tests/minimal_init.lua -l "$rel"
done

for rel in "${PLAIN_LUA_SUITES[@]}"; do
	run_suite "$rel" lua "$rel"
done

desk_test_config_guard_snapshot "$GUARD_DIR" after
desk_test_state_guard_snapshot "$GUARD_DIR" after

echo
echo "=== run-all summary: $pass_suites suite(s) passed, $fail_suites failed ==="
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
