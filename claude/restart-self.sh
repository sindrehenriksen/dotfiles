#!/usr/bin/env bash
# Linux: restarts the Claude Code session this command runs in, in its own
# tab. The Linux counterpart of Hammerspoon's Cmd+Opt+R (docs/desk.md,
# "Stale sessions"), which can type into a tab; nothing outside Ghostty can
# on Linux, so Ghostty types this instead. ghostty/linux-keybinds binds
# Super+Alt+R to: clear Claude Code's input line (Ctrl+K, then Ctrl+U a few
# times; unsent text is lost, as on the Mac) and enter `!<this script>` as a
# bash-mode command, so it runs inside the session's own shell.
#
# Usage: restart-self.sh
#
# Finds its session by walking its parents to the `claude` process and
# reading that process's pid file under $CLAUDE_CONFIG_DIR (default
# ~/.claude). Then two presses, as on the Mac:
#   First press: prints what a restart would do (the reasons
#     session-stale.sh gives, or why it would be refused now, or that nothing
#     in the session is stale) and that unsent text is lost, and records the
#     time. Nothing is restarted.
#   A second press within $RESTART_SELF_WINDOW_SECS (default 10) of the first
#     restarts: it starts itself again, detached (setsid) with its output in
#     a log, and returns at once, because restart-session.sh refuses a
#     session with a shell of its own running, and this is one. The detached
#     part waits up to $RESTART_SELF_IDLE_SECS (default 60) for the session
#     to be idle (the pid file's status, and no shell command running), then
#     runs restart-session.sh <id>, whose checks are the final word. A
#     refusal or failure there, or no idle in time, is in the log and in a
#     desktop notification.
# A session not started through the `claude` shell function, or started
# before restarts worked this way, cannot be restarted: it is told to exit
# and resume once by hand, and records nothing.
#
# Exit 0 for a first press, a second press that started the restart, and a
# refusal; 1 when the session cannot be found (not run from a session).
#
# Overrides (tests): $CLAUDE_CONFIG_DIR, $RESTART_SESSION_PS (the process
# table, as restart-session.sh reads it), $RESTART_SESSION_MODE,
# $RESTART_SELF_NOW (epoch seconds), $RESTART_SELF_WINDOW_SECS,
# $RESTART_SELF_STATE_DIR (where the first press is recorded, default
# $XDG_RUNTIME_DIR/claude-restart-self), $RESTART_SELF_STALE_BIN,
# $RESTART_SELF_RESTART_BIN, $RESTART_SELF_DETACH (default `setsid -f`),
# $RESTART_SELF_LOG (default ~/.local/state/claude/restart-self.log),
# $RESTART_SELF_IDLE_SECS and $RESTART_SELF_NOTIFY (default notify-send).
set -u

script_dir() {
	local src="${BASH_SOURCE[0]}" dir
	while [ -h "$src" ]; do
		dir="$(cd -P "$(dirname "$src")" && pwd)"
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}
HERE="$(script_dir)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=desk-lib/restartable.sh
source "$HERE/desk-lib/restartable.sh"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CONFIG_DIR%/}"
WINDOW="${RESTART_SELF_WINDOW_SECS:-10}"
IDLE_SECS="${RESTART_SELF_IDLE_SECS:-60}"
STATE_DIR="${RESTART_SELF_STATE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/claude-restart-self}"
STALE_BIN="${RESTART_SELF_STALE_BIN:-$HERE/session-stale.sh}"
RESTART_BIN="${RESTART_SELF_RESTART_BIN:-$HERE/restart-session.sh}"
LOG="${RESTART_SELF_LOG:-$HOME/.local/state/claude/restart-self.log}"
DETACH="${RESTART_SELF_DETACH:-setsid -f}"
NOTIFY="${RESTART_SELF_NOTIFY:-notify-send}"

now() { echo "${RESTART_SELF_NOW:-$(date +%s)}"; }
log() { printf '%s restart-self: %s\n' "$(date '+%F %T')" "$1"; }

# The detached half: wait for idle, restart, say how it went.
if [ "${1:-}" = --detached ]; then
	id="$2" pid="$3"
	unset CLAUDE_CODE_SESSION_ID
	pidfile="$CONFIG_DIR/sessions/$pid.json"
	fail() {
		log "$1"
		if command -v "$NOTIFY" > /dev/null 2>&1; then
			"$NOTIFY" "Claude Code session not restarted" "$1" > /dev/null 2>&1 || true
		fi
		exit 1
	}
	log "restarting $id (pid $pid) once it is idle"
	until_s=$((SECONDS + IDLE_SECS))
	restartable_why="its pid file is gone"
	while :; do
		if [ -f "$pidfile" ] && restartable_procs && restartable_idle "$pid" "$pidfile"; then
			break
		fi
		[ "$SECONDS" -lt "$until_s" ] || fail "not restarted: not idle after ${IDLE_SECS}s ($restartable_why)"
		sleep 0.5
	done
	out="$("$RESTART_BIN" "$id" 2>&1)"
	rc=$?
	log "restart-session.sh exited $rc: $out"
	[ "$rc" -eq 0 ] || fail "not restarted: $(printf '%s' "$out" | tail -n 1 | cut -f4)"
	exit 0
fi

# --- find the session ---

restartable_procs || { echo "restart-self: could not list processes" >&2; exit 1; }
pid=$$
claude_pid=""
while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; do
	args="$(args_of "$pid")"
	first="${args%% *}"
	if [ "${first##*/}" = claude ] || [ "$(ps -o comm= -p "$pid" 2> /dev/null)" = claude ]; then
		claude_pid="$pid"
		break
	fi
	pid="$(parent_of "$pid")"
done
pidfile="$CONFIG_DIR/sessions/$claude_pid.json"
if [ -z "$claude_pid" ] || [ ! -f "$pidfile" ]; then
	echo "restart-self: not run from inside a Claude Code session (no claude process above this command with a pid file in $CONFIG_DIR/sessions)" >&2
	exit 1
fi
id="$(jq -r '.sessionId // empty' "$pidfile" 2> /dev/null)"
name="$(jq -r '.name // empty' "$pidfile" 2> /dev/null)"
name="${name:-$id}"
if [ -z "$id" ]; then
	echo "restart-self: the pid file ($pidfile) names no session" >&2
	exit 1
fi

if ! restartable_wrapped "$claude_pid"; then
	echo "Can't restart $name here: $restartable_why (claude --resume $id)."
	exit 0
fi

# --- second press ---

state="$STATE_DIR/$claude_pid"
t="$(now)"
if [ -f "$state" ]; then
	read -r first_t first_id < "$state"
	rm -f "$state"
	if [ "${first_id:-}" = "$id" ] && [[ "${first_t:-}" =~ ^[0-9]+$ ]] && [ $((t - first_t)) -ge 0 ] && [ $((t - first_t)) -le "$WINDOW" ]; then
		mkdir -p "$(dirname "$LOG")"
		# shellcheck disable=SC2086 # $DETACH is a command with its words
		$DETACH "$SELF" --detached "$id" "$claude_pid" < /dev/null >> "$LOG" 2>&1
		echo "Restarting $name once it is idle; it comes back in this tab. Log: $LOG"
		exit 0
	fi
fi

# --- first press ---

export RESTARTABLE_FROM_INSIDE=1
errf="$(mktemp)"
reasons="$(CLAUDE_CONFIG_DIR="$CONFIG_DIR" "$STALE_BIN" "$id" 2> "$errf" < /dev/null)"
rc=$?
why="$(tr '\n' ' ' < "$errf" | sed 's/^session-stale: //; s/[[:space:]]*$//')"
rm -f "$errf"
case "$rc" in
	0) if [ -n "$reasons" ]; then
		reasons="${reasons//$'\n'/; }"
	else
		reasons="nothing in it is stale"
	fi ;;
	3) echo "Can't restart $name in this tab: its tab would close with it (claude --resume $id)."
		exit 0 ;;
	*) echo "A restart of $name would be refused now: ${why:-session-stale.sh exited $rc}."
		exit 0 ;;
esac
mkdir -p -m 700 "$STATE_DIR"
printf '%s %s\n' "$t" "$id" > "$state"
echo "Restart $name? $reasons."
echo "Unsent text in its input box is lost. Press Super+Alt+R again within ${WINDOW}s to restart."
