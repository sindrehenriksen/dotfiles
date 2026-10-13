#!/usr/bin/env bash
# Shared paths, env-var overrides and small helpers for the desk runner.
# Sourced by claude/desk-run and every other
# claude/desk-lib/*.sh file — never executed on its own.
#
# Every path below follows the same override convention the rest of desk
# already uses (desk.status's $DESK_STATUS_FILE, desk.annotate's
# $DESK_TICKET_CACHE, ...): a real default under ~/.local/state/desk, an env
# var a test points elsewhere instead.
set -u

# The directory this file lives in, resolved through any symlink (so it
# works whether sourced via the real path or via ~/.local/bin/desk-run's
# symlink into this repo) — the same technique cli.lua uses for itself.
desk_lib_dir() {
	local src="${BASH_SOURCE[0]}"
	while [ -h "$src" ]; do
		local dir
		dir="$(cd -P "$(dirname "$src")" && pwd)"
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}

DESK_LIB_DIR="$(desk_lib_dir)"
DESK_REPO_DIR="$(cd -P "$DESK_LIB_DIR/../.." && pwd)"
DESK_CLI_LUA="$DESK_REPO_DIR/nvim/lua/desk/cli.lua"
DESK_SESSION_RECORDER_BIN="${DESK_SESSION_RECORDER_BIN:-$DESK_REPO_DIR/claude/hooks/session-recorder.sh}"

DESK_STATE_DIR="${DESK_STATE_DIR:-$HOME/.local/state/desk}"
DESK_STATUS_FILE="${DESK_STATUS_FILE:-$DESK_STATE_DIR/status.json}"
DESK_LOCK_DIR="${DESK_LOCK_ROOT:-$DESK_STATE_DIR/lock}"
DESK_GUARD_DIR="${DESK_GUARD_ROOT:-$DESK_STATE_DIR/guard}"
# Whether the caller set the call roots itself, which wins over the
# config's `calls_root` (desk_apply_calls_root).
DESK_ROOTS_FROM_ENV="${DESK_SCRATCH_ROOT:+scratch}${DESK_RUNS_ROOT:+runs}"
DESK_SCRATCH_ROOT="${DESK_SCRATCH_ROOT:-$DESK_STATE_DIR/scratch}"
DESK_LOG_DIR="${DESK_LOG_DIR:-$DESK_STATE_DIR/logs}"
# Durable per-call scratch dirs for a "visible" (persisted) call: kept here, never under
# $DESK_SCRATCH_ROOT (which desk-run's own trap sweeps every invocation),
# so a `claude --resume` after the pass finishes still finds its cwd. See
# claude/desk-lib/model-call.sh's desk_pass_scratch_dir/desk_prune_old_runs.
DESK_RUNS_ROOT="${DESK_RUNS_ROOT:-$DESK_STATE_DIR/runs}"

# desk_apply_calls_root <config-json> <config-dir>: the config's
# `calls_root`, when set, is where every model call runs: visible calls
# under <calls_root>/runs, the rest under <calls_root>/scratch. A leading
# `~` is expanded and a relative path is taken from the config's directory.
# A DESK_RUNS_ROOT or DESK_SCRATCH_ROOT the caller set still wins.
desk_apply_calls_root() {
	local root
	root="$(jq -r '.calls_root // empty' <<< "$1" 2> /dev/null)"
	[ -n "$root" ] || return 0
	root="${root/#\~/$HOME}"
	case "$root" in /*) ;; *) root="$2/$root" ;; esac
	# Resolved, with no trailing slash, so a session's cwd (always physical)
	# compares to it exactly.
	mkdir -p "$root" 2> /dev/null
	local resolved
	if ! resolved="$(cd -P "$root" 2> /dev/null && pwd -P)"; then
		desk_log - "calls_root $root could not be created or resolved — the calls run under the state directory"
		return 0
	fi
	root="$resolved"
	[[ "$DESK_ROOTS_FROM_ENV" == *runs* ]] || DESK_RUNS_ROOT="$root/runs"
	[[ "$DESK_ROOTS_FROM_ENV" == *scratch* ]] || DESK_SCRATCH_ROOT="$root/scratch"
	mkdir -p "$DESK_RUNS_ROOT" "$DESK_SCRATCH_ROOT" 2> /dev/null
	export DESK_RUNS_ROOT DESK_SCRATCH_ROOT
}

# How long a lock wait gives up after, and how often it polls.
# Both are overridable so a test never waits the real default.
DESK_LOCK_MAX_WAIT_SECS="${DESK_LOCK_MAX_WAIT_SECS:-1800}"
DESK_LOCK_POLL_SECS="${DESK_LOCK_POLL_SECS:-5}"
DESK_KILL_GRACE_SECS="${DESK_KILL_GRACE_SECS:-5}"
# How long a waiter tolerates a lock dir with no meta.json yet before
# treating it as a crash rather than another acquirer mid-publish (lock.sh's
# desk_lock_acquire holds off a lock with no meta for a short grace period) — and the pid-reuse tolerance for comparing
# a lock's recorded owner start time against the same pid's current one
# (same idea as session-status.sh's own LIVENESS_TOLERANCE_SECS, duplicated
# in lock.sh since it's sourced standalone, without that script loaded).
DESK_LOCK_NO_META_GRACE_SECS="${DESK_LOCK_NO_META_GRACE_SECS:-10}"
DESK_LOCK_LIVENESS_TOLERANCE_SECS="${DESK_LOCK_LIVENESS_TOLERANCE_SECS:-3}"

# Failsafes on every model call, set high enough that normal work never
# reaches them: they are there to stop a runaway call, not to size one. The
# spend ceiling is the config's top-level `default_max_budget_usd`, else
# this; the timeout is a step's own `timeout`, else this.
DESK_DEFAULT_MAX_BUDGET_USD="${DESK_DEFAULT_MAX_BUDGET_USD:-25}"
DESK_DEFAULT_TIMEOUT_SECS="${DESK_DEFAULT_TIMEOUT_SECS:-1200}"

# desk_max_budget_usd: the one per-call spend ceiling.
desk_max_budget_usd() {
	local v
	v="$(jq -r '.default_max_budget_usd // empty' "${DESK_CONFIG:-/dev/null}" 2> /dev/null)"
	printf '%s' "${v:-$DESK_DEFAULT_MAX_BUDGET_USD}"
}

mkdir -p "$DESK_STATE_DIR" "$DESK_LOCK_DIR" "$DESK_GUARD_DIR" "$DESK_SCRATCH_ROOT" "$DESK_LOG_DIR" "$DESK_RUNS_ROOT" 2>/dev/null

# $DESK_CONFIG, or when it is unset, the machine-local default
# ${XDG_CONFIG_HOME:-~/.config}/desk/config.json if that exists: a shell
# started before the variable was exported, or an agent's Bash tool, still
# finds the instance. The default is a path an instance's own installer
# links, never one this repo names. $DESK_CONFIG_DEFAULT overrides that
# path, which is how the test suite keeps a real instance out of reach.
desk_resolve_config() {
	if [ -z "${DESK_CONFIG:-}" ]; then
		local fallback="${DESK_CONFIG_DEFAULT:-${XDG_CONFIG_HOME:-$HOME/.config}/desk/config.json}"
		# Resolved, since the config's own paths are relative to the
		# directory it really lives in, not the link's.
		[ -e "$fallback" ] && DESK_CONFIG="$(realpath "$fallback")"
	fi
	DESK_CONFIG="${DESK_CONFIG:-}"
}

desk_log() {
	# $1: pass name (or "-" outside any pass); rest: message. Goes to
	# stderr only — launchd's own per-pass log redirect is what actually persists it; this never writes a log file
	# itself so a test never has to clean one up.
	local pass="$1"
	shift
	printf '%s [desk-run:%s] %s\n' "$(date -u +%FT%TZ)" "$pass" "$*" >&2
}

# $DESK_NOW (epoch seconds) pins the clock for tests.
desk_now() { echo "${DESK_NOW:-$(date +%s)}"; }

# The pid this whole desk-run invocation belongs to, so a lock/guard can
# record and later liveness-check its owner.
desk_pid() { echo $$; }

desk_pid_alive() {
	kill -0 "$1" 2>/dev/null
}

# A fresh lowercase UUID for a "visible" call's own --session-id. uuidgen's own output is
# uppercase; Claude Code's session ids are lowercase.
desk_new_session_id() {
	if command -v uuidgen > /dev/null 2>&1; then
		uuidgen | tr '[:upper:]' '[:lower:]'
	else
		cat /proc/sys/kernel/random/uuid 2> /dev/null
	fi
}

# nvim -l wrapper: every cli.lua call goes through here so error output lands
# on stderr uniformly and a bad exit is never silently swallowed.
desk_nvim_cli() {
	nvim -l "$DESK_CLI_LUA" "$@"
}

# A single POSIX-shell-safe single-quoted token for $1 — the one place a
# value ever needs re-quoting into shell syntax at all is desk_step_open_tab
# assembling its whole launch command as one *string* (Ghostty's own
# `command:` field takes a shell command line, never an argv array), so
# every argument goes through this rather than being hand-escaped inline.
desk_shq() {
	printf "'%s'" "${1//\'/\'\\\'\'}"
}

# Writes $2 to $1 atomically (temp file in the same directory, then
# rename), so a reader never sees a half-written file.
desk_write_atomic() {
	local path="$1" content="$2"
	local dir tmp
	dir="$(dirname "$path")"
	mkdir -p "$dir" 2>/dev/null
	tmp="$dir/.tmp.$$.$RANDOM"
	printf '%s' "$content" > "$tmp"
	mv -f "$tmp" "$path"
}

# desk_line_key: each line on stdin as it is compared with a quoted one:
# the agent mark at the end of the line dropped together with the
# whitespace around it, then trailing whitespace dropped, so a quote of a
# taken line ending in a space still matches it. The rule of
# nvim/lua/desk/snippet.lua's line_key, which placement uses;
# desk-line-key-test.sh checks the two agree.
desk_line_key() {
	DESK_MARK="$(sed 's/^[[:space:]]*//' <<< "${DESK_AGENT_MARK:-  <<agent-suggested>>}")" \
		perl -pe 'BEGIN { $m = quotemeta($ENV{DESK_MARK}) } s/[ \t\r]*$m[ \t\r]*$//; s/[ \t\r]+$//'
}
