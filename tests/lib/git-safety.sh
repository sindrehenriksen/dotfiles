# Shared safety net for every bash test in this repo that runs real git
# commands against a throwaway repo (nvim/tests/*.sh, claude/tests/*.sh,
# git-hooks/test-*.sh). Sourced, never executed.
#
# Why this exists: git-hooks/pre-commit runs these test-*.sh files FROM
# INSIDE a real `git commit`, which leaves GIT_DIR/GIT_WORK_TREE/etc
# pointing at the real repo in this process's own environment — an
# explicit GIT_DIR wins over `-C`/cwd for repo discovery, so a test that
# forgets a `-C`, or that runs `git config` instead of
# `git -C "$repo" config`, silently operates on the real repo instead of
# its own throwaway one. Separately, an un-overridden global/system git
# config is this machine's real ~/.gitconfig / /etc/gitconfig — a test
# that runs `git config --global` (rather than scoping to its own repo)
# writes into those instead of a fixture. Both are exactly how a prior
# build test wrote `user.name`/`user.email`/`desk.denylist` into the real
# ~/dotfiles/.git/config: see git log for the incident this hardens
# against.
#
# Usage, right after creating a throwaway root and before the first git
# command:
#   ROOT="$(mktemp -d)"
#   trap 'rm -rf "$ROOT"' EXIT
#   source "$HERE/../../tests/lib/git-safety.sh"
#   desk_test_git_safety_init "$ROOT"
#   ... git -C "$ROOT/whatever" ... is now safe to run ...
#
# A test that must run a git command before its own root exists yet (e.g.
# to compute this real repo's own toplevel for a guard, before creating
# anything throwaway) can call desk_test_git_env_isolate and
# desk_test_git_guard_toplevel_init directly — desk_test_git_safety_init
# calls both itself, so most tests never need them.
#
# desk_test_git_safety_init <root>:
# - refuses to continue (exit 1) unless <root> resolves (cd -P) under a
#   recognized temp dir (TMPDIR, /tmp, /private/tmp,
#   /private/var/folders, /var/folders)
# - unsets GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY,
#   GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_CEILING_DIRECTORIES, GIT_PREFIX
#   — whatever an outer real `git commit` left in this process's
#   environment
# - points GIT_CONFIG_GLOBAL at a fresh file under <root> (never
#   ~/.gitconfig) and sets GIT_CONFIG_NOSYSTEM=1 (never /etc/gitconfig);
#   that file sets core.hookspath to an empty dir under <root> (so every
#   repo this test creates — including a bare remote it never configures
#   directly — gets no hooks) and a throwaway user.email/user.name (so a
#   repo that skips its own `git config user.*` still gets to commit)
# - exports DESK_TEST_GIT_GUARD_REAL_TOPLEVEL, this real repo's own
#   toplevel, for desk_test_guard_not_real_repo / desk_test_assert_repo_under_root
#
# desk_test_assert_repo_under_root <repo> <root>: call before the first
# git command against each repo a test creates (the notes repo, a bare
# remote, ...) — refuses (exit 1) unless <repo> resolves under <root>.
#
# desk_test_guard_not_real_repo <dir>: second line of defense — aborts
# (exit 1) if <dir> resolves (git rev-parse --show-toplevel) to this real
# repo, in case the isolation above ever breaks anyway (a future call
# site forgets -C, an inherited GIT_DIR survives some other way, etc).

desk_test_git_env_isolate() {
	unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
		GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_PREFIX
}

desk_test_git_guard_toplevel_init() {
	if [ -z "${DESK_TEST_GIT_GUARD_REAL_TOPLEVEL+x}" ]; then
		local helper_dir
		helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		DESK_TEST_GIT_GUARD_REAL_TOPLEVEL="$(git -C "$helper_dir" rev-parse --show-toplevel 2> /dev/null || true)"
		export DESK_TEST_GIT_GUARD_REAL_TOPLEVEL
	fi
}

desk_test_git_safety_init() {
	local root="$1"
	if [ -z "$root" ] || [ ! -d "$root" ]; then
		printf 'desk_test_git_safety_init: not a directory: %s\n' "$root" >&2
		exit 1
	fi
	case "$(cd "$root" && pwd -P)" in
		"${TMPDIR:-/nonexistent}"* | /tmp/* | /private/tmp/* | /private/var/folders/* | /var/folders/*) : ;;
		*)
			printf 'refusing to run: root is not under a temp dir: %s\n' "$root" >&2
			exit 1
			;;
	esac

	desk_test_git_env_isolate

	local hooks_dir="$root/.desk-test-no-hooks"
	mkdir -p "$hooks_dir"
	local global_config="$root/.desk-test-gitconfig-global"
	{
		printf '[core]\n\thookspath = %s\n' "$hooks_dir"
		printf '[user]\n\temail = test@example.invalid\n\tname = Desk Test\n'
		printf '[init]\n\tdefaultBranch = main\n'
	} > "$global_config"
	export GIT_CONFIG_GLOBAL="$global_config"
	export GIT_CONFIG_NOSYSTEM=1

	desk_test_git_guard_toplevel_init
}

desk_test_assert_repo_under_root() {
	local repo="$1" root="$2"
	if [ -z "$repo" ] || [ -z "$root" ]; then
		printf 'desk_test_assert_repo_under_root: usage: <repo> <root>\n' >&2
		exit 1
	fi
	local repo_real root_real
	root_real="$(cd "$root" && pwd -P)" || exit 1
	mkdir -p "$repo"
	repo_real="$(cd "$repo" && pwd -P)" || exit 1
	case "$repo_real" in
		"$root_real" | "$root_real"/*) : ;;
		*)
			printf 'refusing to run: repo %s is not under root %s\n' "$repo" "$root" >&2
			exit 1
			;;
	esac
}

#
# Config guard (used by tests/run-all.sh and git-hooks/pre-commit — the
# belt to the rest of this file's suspenders): snapshots each of
# $DESK_GUARD_REPOS' (colon-separated repo paths) own `git config --local
# --list` before a test run and fails loudly if any changed by the end,
# regardless of which individual test caused it.
#
# desk_test_config_guard_resolve_repos <from_repo>: sets the array
# DESK_TEST_GUARD_REPOS from $DESK_GUARD_REPOS, or — if that's unset — the
# one default: <from_repo>'s main checkout (a worktree's own
# `git rev-parse --git-common-dir` always points at the main checkout's
# .git, so this resolves correctly whether <from_repo> is the main
# checkout or one of its worktrees).
desk_test_config_guard_resolve_repos() {
	local from_repo="${1:-.}"
	DESK_TEST_GUARD_REPOS=()
	if [ -n "${DESK_GUARD_REPOS:-}" ]; then
		local IFS=':'
		read -r -a DESK_TEST_GUARD_REPOS <<< "$DESK_GUARD_REPOS"
		return 0
	fi
	local common_dir
	common_dir="$(git -C "$from_repo" rev-parse --git-common-dir 2> /dev/null)" || return 1
	case "$common_dir" in
		/*) : ;;
		*) common_dir="$(cd "$from_repo" && pwd)/$common_dir" ;;
	esac
	DESK_TEST_GUARD_REPOS=("${common_dir%/.git}")
}

# desk_test_config_guard_snapshot <dest_dir> <suffix>: writes each guard
# repo's `git config --local --list` to <dest_dir>/<n>.<suffix>. Call
# once before a test run and once after, with two different suffixes.
desk_test_config_guard_snapshot() {
	local dest="$1" suffix="$2" i=0 repo
	mkdir -p "$dest"
	for repo in "${DESK_TEST_GUARD_REPOS[@]}"; do
		git -C "$repo" config --local --list > "$dest/$i.$suffix" 2> /dev/null || : > "$dest/$i.$suffix"
		i=$((i + 1))
	done
}

# desk_test_config_guard_check <dest_dir> <before_suffix> <after_suffix>:
# compares each guard repo's before/after snapshot, printing a diff for
# and naming any repo that changed. Returns non-zero if anything did.
desk_test_config_guard_check() {
	local dest="$1" before_suffix="$2" after_suffix="$3" i=0 repo changed=0
	for repo in "${DESK_TEST_GUARD_REPOS[@]}"; do
		if ! diff -u "$dest/$i.$before_suffix" "$dest/$i.$after_suffix" > "$dest/$i.diff" 2>&1; then
			printf 'GUARD FAILED: local git config changed for %s\n' "$repo" >&2
			cat "$dest/$i.diff" >&2
			changed=1
		fi
		i=$((i + 1))
	done
	return "$changed"
}

desk_test_guard_not_real_repo() {
	local dir="$1" toplevel
	toplevel="$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null || true)"
	if [ -n "$toplevel" ] && [ -n "${DESK_TEST_GIT_GUARD_REAL_TOPLEVEL:-}" ] && [ "$toplevel" = "$DESK_TEST_GIT_GUARD_REAL_TOPLEVEL" ]; then
		printf "ABORT: '%s' resolves to this repo (%s) instead of a throwaway one — refusing to continue\n" "$dir" "$toplevel" >&2
		exit 1
	fi
}

#
# Real state guard (used by tests/run-all.sh and git-hooks/pre-commit,
# alongside the config guard above): every desk-lib/*.sh path (DESK_STATE_DIR,
# CLAUDE_SESSION_STORE, DESK_TICKET_CACHE, ...) already resolves through an
# env var override first, so a well-behaved test never touches real state at
# all — but a test that forgets one still silently falls through to the real
# $HOME-based default, exactly how a prior desk-scoped-read-test.sh run wrote
# a fake session record into the real ~/.local/state/claude/session-events/
# and left empty dirs under ~/.local/state/desk/ (both cleaned up by hand).
# desk_test_safe_env_init below is the actual fix (safe, temp-scoped
# defaults so forgetting an override is harmless); this is only the
# belt-and-suspenders check that nothing slipped past it regardless — same
# relationship the config guard has to each test's own isolation.
#
# Each file's path AND content hash is the comparison basis, so a test that
# rewrites an existing file in place (a reader cache, a ledger, a status
# file) is caught as well as one that adds or removes files. Directory
# mtimes are deliberately not part of it.
# Some real state changes during any test run on a machine in use: Claude
# Code's per-version lock files (`locks/`, skipped), the recorder hook's
# event files and log, which every live session appends to, and the
# reader's cache, which the nvim marks, the status line and any `resolve`
# rewrite in place. Those are compared by path only. The reader cache is
# keyed by config dir, so a test that reached the real cache with its own
# temp config dir still shows up as a new path. Everything else is compared
# by content.
_DESK_TEST_STATE_LIVE_APPENDED=(-path '*/session-events/*' -o -path '*/live-sessions/*' -o -path '*/session-reader-cache/*' -o -name session-recorder.log)
DESK_TEST_STATE_GUARD_DIRS=("$HOME/.local/state/claude" "$HOME/.local/state/desk")

# desk_test_state_guard_snapshot <dest_dir> <suffix>: writes each guarded
# real directory's recursive directory listing and file content hashes to
# <dest_dir>/state-<n>.<suffix>.
desk_test_state_guard_snapshot() {
	local dest="$1" suffix="$2" i=0 dir
	mkdir -p "$dest"
	for dir in "${DESK_TEST_STATE_GUARD_DIRS[@]}"; do
		{
			find "$dir" -path "$dir/locks" -prune -o -type d -print 2> /dev/null | sed 's/^/d /'
			find "$dir" -path "$dir/locks" -prune -o -type f \( "${_DESK_TEST_STATE_LIVE_APPENDED[@]}" \) -print 2> /dev/null | sed 's/^/l /'
			find "$dir" -path "$dir/locks" -prune -o -type f ! \( "${_DESK_TEST_STATE_LIVE_APPENDED[@]}" \) -exec shasum -a 256 {} + 2> /dev/null | sed 's/^/f /'
		} | LC_ALL=C sort > "$dest/state-$i.$suffix"
		i=$((i + 1))
	done
}

# desk_test_state_guard_check <dest_dir> <before_suffix> <after_suffix>:
# compares each guarded directory's before/after listing, printing a diff
# for and naming any that changed. Returns non-zero if anything did.
desk_test_state_guard_check() {
	local dest="$1" before_suffix="$2" after_suffix="$3" i=0 dir changed=0
	for dir in "${DESK_TEST_STATE_GUARD_DIRS[@]}"; do
		if ! diff -u "$dest/state-$i.$before_suffix" "$dest/state-$i.$after_suffix" > "$dest/state-$i.diff" 2>&1; then
			printf 'STATE GUARD FAILED: real state under %s changed\n' "$dir" >&2
			cat "$dest/state-$i.diff" >&2
			changed=1
		fi
		i=$((i + 1))
	done
	return "$changed"
}

# desk_test_safe_env_init <dest_dir>: the actual fix, not just the check —
# exports temp-scoped defaults for every real path a desk-lib test can
# forget to override (DESK_STATE_DIR and everything common.sh derives from
# it, CLAUDE_SESSION_STORE, CLAUDE_SESSION_RECORDER_LOG,
# CLAUDE_SESSION_READER_CACHE, DESK_TICKET_CACHE, DESK_STATUS_FILE,
# CLAUDE_CONFIG_DIR), plus refusing stubs for the executables a forgotten
# override would otherwise let a test actually run for real (DESK_CLAUDE_BIN
# — a live model call; DESK_OPEN_TAB_BIN/DESK_FOCUS_TAB_BIN/DESK_OPEN_URL —
# a real tab focused or URL opened) and an empty reader for DESK_READER, so
# a lookup that was never stubbed sees no sessions instead of the user's real ones.
# Call once, before the first suite/test runs; every value here is still just a default; a suite that
# sets its own (as most already do) overrides it the ordinary way.
desk_test_safe_env_init() {
	local dest="$1"
	mkdir -p "$dest/state" "$dest/claude-config" "$dest/bin"

	local stub
	for stub in claude desk-open-tab.sh desk-focus-tab.sh open-url; do
		{
			printf '#!/usr/bin/env bash\n'
			printf 'echo "refusing stub ($0): this test never overrode the env var pointing at it — refusing to run for real" >&2\n'
			printf 'exit 1\n'
		} > "$dest/bin/$stub"
		chmod +x "$dest/bin/$stub"
	done

	printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/bin/session-status.sh"
	chmod +x "$dest/bin/session-status.sh"

	export DESK_STATE_DIR="$dest/state"
	export CLAUDE_SESSION_READER_CACHE="$dest/state/session-reader-cache"
	export DESK_READER="$dest/bin/session-status.sh"
	export DESK_FOCUS_TAB_BIN="$dest/bin/desk-focus-tab.sh"
	export CLAUDE_SESSION_STORE="$dest/state/session-events"
	export CLAUDE_SESSION_RECORDER_LOG="$dest/state/session-recorder.log"
	export DESK_TICKET_CACHE="$dest/state/ticket-status.json"
	export DESK_STATUS_FILE="$dest/state/status.json"
	export CLAUDE_CONFIG_DIR="$dest/claude-config"
	export DESK_CLAUDE_BIN="$dest/bin/claude"
	export DESK_OPEN_TAB_BIN="$dest/bin/desk-open-tab.sh"
	export DESK_OPEN_URL="$dest/bin/open-url"
}
