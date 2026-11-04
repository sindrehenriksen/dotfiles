#!/usr/bin/env bash
# Restarts a live Claude Code session in the Ghostty tab it runs in: ends
# its process gracefully, then has the tab's shell exec a fresh login shell
# that resumes it, so a new Claude Code version, changed settings or hooks,
# or changed shell config take effect without losing the tab. The resume
# goes through the user's `claude` shell function, so it gets the same
# account and flags a session started by hand gets, and the tab is left at
# a prompt in the session's directory when the resumed session ends.
#
# Unsent text in the session's input box is lost: the restart ends the
# process holding it and clears the tab's line before typing the resume.
#
# Usage: restart-session.sh <session-id>
#
# Refused, with nothing done: an id that is not a full session UUID; a
# session that is not live, or that two processes hold; the session running
# this command; a pid that is not a `claude` process. Also a session that is
# not idle with nothing running: its pid file's status is not idle; it has a
# shell of its own running (a child `<shell> -c source <config
# dir>/shell-snapshots/snapshot-…`, how Claude Code runs a Bash call); or a
# file under its transcript's `<id>/subagents/` changed in the last
# $RESTART_SESSION_QUIET_MINS minutes (default 5). Other children, the MCP
# servers, do not count. And a session whose tab cannot be named for certain
# (as close-session.sh names it: the one terminal on its tty running its
# pid) or would not be left at a prompt: claude's own shell must be an
# interactive one, the command typed into one, or the form this script
# types. A tab whose only shell is the one running claude, which tabs
# opened before desk-open-tab.sh left a prompt have, closes with it.
#
# Then: SIGTERM, as close-session.sh sends, and a wait for the process and
# its pid file to go. A session that will not stop is reported and nothing
# more is done. Once it has, and the tab's foreground process is an
# interactive shell, the tab's line is cleared and
#   exec /bin/zsh -lic 'cd <cwd> && CLAUDE_CONFIG_DIR=<dir> claude --resume <id>; exec /bin/zsh -il'
# typed and entered, only while that shell is still the foreground process.
# Nothing is recorded as a deliberate end: the process's own SessionEnd
# records its stop like any other, so reopen-sessions.sh treats the session
# as it would have.
#
# Output: one tab-separated line, `<status> <id> <name> <detail>`, status
# restarted, refused or failed. Exit 0 when restarted, 1 refused or failed,
# 2 usage. `failed` after the signal says what state the session was left
# in and how to resume it by hand.
#
# Overrides (tests): $DESK_READER, $DESK_CLOSE_TAB_BIN, $RESTART_SESSION_PS
# (a command printing `pid ppid args` for every process, default ps),
# $RESTART_SESSION_QUIET_MINS, $RESTART_SESSION_GRACE_SECS (default 10),
# $RESTART_SESSION_PROMPT_SECS (how long to wait for the tab's prompt,
# default 10), $RESTART_SESSION_CONFIRM_SECS (how long to wait for the
# resumed session to show as live, default 20; 0 skips the wait) and
# $RESTART_SESSION_TAB_TIMEOUT_SECS (default 10).
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

desk_pid_alive() { kill -0 "$1" 2> /dev/null; }
DESK_KILL_GRACE_SECS=2
# shellcheck source=desk-lib/timeout.sh
source "$HERE/desk-lib/timeout.sh"

READER="${DESK_READER:-session-status.sh}"
TAB_HELPER="${DESK_CLOSE_TAB_BIN:-desk-close-tab.sh}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CONFIG_DIR%/}"
QUIET_MINS="${RESTART_SESSION_QUIET_MINS:-5}"
GRACE="${RESTART_SESSION_GRACE_SECS:-10}"
PROMPT_SECS="${RESTART_SESSION_PROMPT_SECS:-10}"
CONFIRM_SECS="${RESTART_SESSION_CONFIRM_SECS:-20}"
TAB_TIMEOUT="${RESTART_SESSION_TAB_TIMEOUT_SECS:-10}"
# What the typed command ends with, and how a later restart of the same tab
# knows a prompt follows the session.
HANDOVER="; exec /bin/zsh -il"

id="${1:-}"
if [ $# -ne 1 ] || [ -z "$id" ]; then
	echo "usage: restart-session.sh <session-id>" >&2
	exit 2
fi

name=""
report() { # status detail
	printf '%s\t%s\t%s\t%s\n' "$1" "$id" "${name:--}" "$2"
	[ "$1" = restarted ]
	exit $?
}

shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

[[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
	|| report refused "not a session id"

entries="$("$READER" < /dev/null 2> /dev/null | jq -c --arg id "$id" 'select(.id == $id)' 2> /dev/null)" \
	|| report failed "the session reader ($READER) failed"
n="$(jq -s 'length' <<< "$entries")"
[ "$n" -gt 0 ] || report refused "no such session"
[ "$n" -eq 1 ] || report refused "the reader reports $n entries for this id"
name="$(jq -r '.name // ""' <<< "$entries")"
[ "$(jq -r '.live == true' <<< "$entries")" = "true" ] || report refused "not live"
[ "$(jq -r '.duplicate_pids == true' <<< "$entries")" = "false" ] \
	|| report refused "more than one process holds this session"
[ "${CLAUDE_CODE_SESSION_ID:-}" != "$id" ] || report refused "this is the session running the command"

pid="$(jq -r '.pid // empty' <<< "$entries")"
[[ "$pid" =~ ^[0-9]+$ ]] || report refused "the reader gives no pid"
comm="$(ps -o comm= -p "$pid" 2> /dev/null)"
case "$comm" in
	claude | */claude) ;;
	*) report refused "pid $pid is not a claude process" ;;
esac

# --- idle, with nothing running ---

pidfile="$CONFIG_DIR/sessions/$pid.json"
state="$(jq -r '.status // empty' "$pidfile" 2> /dev/null)"
[ -n "$state" ] || report refused "no status in its pid file ($pidfile)"
[ "$state" = idle ] || report refused "not idle: its status is $state"

procs="$("${RESTART_SESSION_PS:-ps}" -A -ww -o pid= -o ppid= -o args= 2> /dev/null)" \
	|| report failed "could not list processes"
args_of() { awk -v p="$1" '$1 == p { $1 = ""; $2 = ""; sub(/^  /, ""); print; exit }' <<< "$procs"; }
parent_of() { awk -v p="$1" '$1 == p { print $2; exit }' <<< "$procs"; }

running="$(awk -v p="$pid" -v pat=" -c source $CONFIG_DIR/shell-snapshots/snapshot-" \
	'$2 == p && index($0, pat) { print $1 }' <<< "$procs" | head -n 1)"
[ -z "$running" ] || report refused "not idle: it is running a shell command (pid $running)"

transcript="$(jq -r '.transcript_path // empty' <<< "$entries")"
[ -n "$transcript" ] || report refused "no transcript, so no way to tell whether subagents are running"
subagents="$(dirname "$transcript")/$id/subagents"
if [ -d "$subagents" ]; then
	recent="$(find "$subagents" -type f -mmin "-$QUIET_MINS" 2> /dev/null | head -n 1)"
	[ -z "$recent" ] || report refused "not idle: a subagent wrote in the last ${QUIET_MINS} min ($(basename "$recent"))"
fi

# --- the tab, and whether it is left at a prompt ---

# A shell's argv: its name (a login shell's with a leading -), then option
# words. One running a command has a `c` among them; an interactive one has
# none and nothing after them.
is_shell() {
	local first="${1%% *}"
	first="${first#-}"
	case "${first##*/}" in zsh | bash | sh) return 0 ;; esac
	return 1
}
runs_command() {
	local word words
	read -r -a words <<< "$1"
	for word in "${words[@]:1}"; do
		case "$word" in
			--*) ;;
			-*c*) return 0 ;;
			-*) ;;
			*) return 0 ;;
		esac
	done
	return 1
}
interactive_shell() { is_shell "$1" && ! runs_command "$1"; }

parent="$(parent_of "$pid")"
parent_args="$(args_of "$parent")"
grand_args="$(args_of "$(parent_of "$parent")")"
if interactive_shell "$parent_args"; then
	:
elif is_shell "$parent_args" && [[ "$parent_args" == *"$HANDOVER" ]]; then
	:
elif is_shell "$parent_args" && interactive_shell "$grand_args"; then
	:
else
	report refused "its tab would close with it: no shell in the tab outlives claude (${parent_args:-no parent})"
fi

tty="$(jq -r '.tty // empty' <<< "$entries")"
recorded_tty="$(jq -r '.recorded_tty // empty' <<< "$entries")"
if [ -z "$tty" ] || [ "$tty" = "??" ]; then
	report refused "the session has no terminal"
fi
if [ -n "$recorded_tty" ] && [ "${recorded_tty#/dev/}" != "${tty#/dev/}" ]; then
	report refused "its tty $tty is not the one its start recorded ($recorded_tty)"
fi

tab_call() { # args... -> sets tab_rc, tab_out, tab_why
	local out
	out="$(mktemp "${TMPDIR:-/tmp}/restart-session.XXXXXX")"
	run_with_timeout "$TAB_TIMEOUT" "$out" "$TAB_HELPER" "$@" < /dev/null
	tab_rc=$?
	tab_out="$(head -n 1 "$out" 2> /dev/null)"
	tab_why="$(tr '\n' ' ' < "$out.stderr" 2> /dev/null | sed 's/[[:space:]]*$//')"
	[ "$tab_rc" -eq 124 ] && tab_why="the tab helper timed out"
	rm -f "$out" "$out.stderr"
}

tab_call find "$tty" "$pid"
terminal="$tab_out"
if [ "$tab_rc" -ne 0 ] || [ -z "$terminal" ]; then
	report refused "could not tell its tab apart${tab_why:+: $tab_why}"
fi

# --- stop it ---

cwd="$(jq -r '.cwd // empty' <<< "$entries")"
resume="CLAUDE_CONFIG_DIR=$(shq "$CONFIG_DIR") claude --resume $id"
[ -n "$cwd" ] && resume="cd $(shq "$cwd") && $resume"
by_hand="resume it by hand: ${cwd:+cd $(shq "$cwd") && }claude --resume $id"

kill -TERM "$pid" 2> /dev/null
waited=0
while { desk_pid_alive "$pid" || [ -e "$pidfile" ]; } && [ "$waited" -lt "$GRACE" ]; do
	sleep 1
	waited=$((waited + 1))
done
if desk_pid_alive "$pid"; then
	report failed "pid $pid survived SIGTERM for ${GRACE}s; nothing more done"
fi

# --- resume it in the tab ---

shell_pid="" last_seen=""
waited=0
while :; do
	tab_call pid "$terminal"
	if [ "$tab_rc" -eq 0 ] && [[ "$tab_out" =~ ^[0-9]+$ ]]; then
		procs="$("${RESTART_SESSION_PS:-ps}" -A -ww -o pid= -o ppid= -o args= 2> /dev/null)"
		last_seen="$(args_of "$tab_out")"
		if interactive_shell "$last_seen"; then
			shell_pid="$tab_out"
			break
		fi
	elif [ "$tab_rc" -ne 0 ]; then
		report failed "the session stopped, but its tab is out of reach${tab_why:+ ($tab_why)}; $by_hand"
	fi
	[ "$waited" -ge "$PROMPT_SECS" ] && break
	sleep 1
	waited=$((waited + 1))
done
if [ -z "$shell_pid" ]; then
	report failed "the session stopped, but its tab showed no prompt within ${PROMPT_SECS}s (${last_seen:-nothing in the foreground}); $by_hand"
fi

tab_call type "$terminal" "$shell_pid" " exec /bin/zsh -lic $(shq "$resume$HANDOVER")"
if [ "$tab_rc" -ne 0 ]; then
	report failed "the session stopped, but the resume was not typed${tab_why:+: $tab_why}; $by_hand"
fi

[ "$CONFIRM_SECS" -gt 0 ] || report restarted "resume typed into its tab"
waited=0
while [ "$waited" -lt "$CONFIRM_SECS" ]; do
	sleep 1
	waited=$((waited + 1))
	now="$("$READER" < /dev/null 2> /dev/null | jq -r --arg id "$id" 'select(.id == $id and .live == true) | .pid' 2> /dev/null | head -n 1)"
	if [[ "$now" =~ ^[0-9]+$ ]] && [ "$now" != "$pid" ]; then
		report restarted "resumed in its tab (pid $now)"
	fi
done
report failed "the resume was typed into its tab, but the session is not live after ${CONFIRM_SECS}s; look at the tab"
