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
DESK_SCRATCH_ROOT="${DESK_SCRATCH_ROOT:-$DESK_STATE_DIR/scratch}"
DESK_LOG_DIR="${DESK_LOG_DIR:-$DESK_STATE_DIR/logs}"
# Durable per-call scratch dirs for a "visible" (persisted) call: kept here, never under
# $DESK_SCRATCH_ROOT (which desk-run's own trap sweeps every invocation),
# so a `claude --resume` after the pass finishes still finds its cwd. See
# claude/desk-lib/model-call.sh's desk_pass_scratch_dir/desk_prune_old_runs.
DESK_RUNS_ROOT="${DESK_RUNS_ROOT:-$DESK_STATE_DIR/runs}"

# How long a lock wait gives up after, and how long a "running"
# status entry can go stale before the next run treats it as a crash.
# Both are overridable so a test never waits the real default.
DESK_LOCK_MAX_WAIT_SECS="${DESK_LOCK_MAX_WAIT_SECS:-1800}"
DESK_LOCK_POLL_SECS="${DESK_LOCK_POLL_SECS:-5}"
DESK_STALE_RUNNING_MINUTES="${DESK_STALE_RUNNING_MINUTES:-60}"
DESK_KILL_GRACE_SECS="${DESK_KILL_GRACE_SECS:-5}"
# How long a waiter tolerates a lock dir with no meta.json yet before
# treating it as a crash rather than another acquirer mid-publish (lock.sh's
# desk_lock_acquire holds off a lock with no meta for a short grace period) — and the pid-reuse tolerance for comparing
# a lock's recorded owner start time against the same pid's current one
# (same idea as session-status.sh's own LIVENESS_TOLERANCE_SECS, duplicated
# in lock.sh since it's sourced standalone, without that script loaded).
DESK_LOCK_NO_META_GRACE_SECS="${DESK_LOCK_NO_META_GRACE_SECS:-10}"
DESK_LOCK_LIVENESS_TOLERANCE_SECS="${DESK_LOCK_LIVENESS_TOLERANCE_SECS:-3}"

# The per-call --max-budget-usd a step falls back to when it (and
# $DESK_CONFIG's own top-level `default_max_budget_usd`) don't name one —
# a generic backstop, never an instantiation-specific figure, same as
# every other numeric default in this file.
DESK_DEFAULT_MAX_BUDGET_USD="${DESK_DEFAULT_MAX_BUDGET_USD:-2}"

mkdir -p "$DESK_STATE_DIR" "$DESK_LOCK_DIR" "$DESK_GUARD_DIR" "$DESK_SCRATCH_ROOT" "$DESK_LOG_DIR" "$DESK_RUNS_ROOT" 2>/dev/null

desk_log() {
	# $1: pass name (or "-" outside any pass); rest: message. Goes to
	# stderr only — launchd's own per-pass log redirect is what actually persists it; this never writes a log file
	# itself so a test never has to clean one up.
	local pass="$1"
	shift
	printf '%s [desk-run:%s] %s\n' "$(date -u +%FT%TZ)" "$pass" "$*" >&2
}

desk_now() { date +%s; }

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
