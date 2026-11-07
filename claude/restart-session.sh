#!/usr/bin/env bash
# Restarts a live Claude Code session in the Ghostty tab it runs in: ends
# its process gracefully, then has the tab's shell exec a fresh login shell
# that resumes it, so a new Claude Code version, changed settings or hooks,
# or changed shell config take effect without losing the tab. The resume
# goes through the user's `claude` shell function, so it gets the same
# account and flags a session started by hand gets, plus the allowlisted
# flags its exact argv shows it was started with (restartable_flags in
# desk-lib/restartable.sh has the list), and the tab is left at a prompt in
# the session's directory when the resumed session ends.
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
# dir>/shell-snapshots/snapshot-…`, how Claude Code runs a Bash call); a
# file under its transcript's `<id>/subagents/` changed in the last
# $RESTART_SESSION_QUIET_MINS minutes (default 5), or a subagent it started
# not marked finished there; or a wakeup or session cron its transcript
# shows still pending, which lives in the process and would be lost. Other
# children, the MCP servers, do not count. One whose argv cannot be read, or
# holds an option a resume would drop, or a flag that bypasses permissions,
# which a restart never passes on: the user passes it again by hand. And a session whose tab cannot be
# named for certain (as close-session.sh names it: the one terminal on its
# tty running its pid) or would not be left at a prompt: claude's own shell must be an
# interactive one, the command typed into one, or the form this script
# types. A tab whose only shell is the one running claude, which tabs
# opened before desk-open-tab.sh left a prompt have, closes with it.
#
# Then the idle checks again, since naming the tab can take seconds; SIGTERM
# straight after, as close-session.sh sends; and a wait for the process and
# its pid file to go. A session that will not stop is reported and nothing
# more is done. Once it has, the tab's foreground process is watched until
# it is an interactive shell that has settled: one claude ran under, still
# the same, or else the same shell with the same children on two looks a
# second apart; then Ctrl-C clears the line, in vi insert and command mode
# alike, and
#   exec /bin/zsh -lic 'cd <cwd> && CLAUDE_CONFIG_DIR=<dir> claude --resume <id>; exec /bin/zsh -il'
# is pasted and entered, only while that shell is still the foreground
# process. What that guarantees: nothing is typed into anything but that
# shell, and whatever was on its line is discarded. What it does not: a key
# pressed in the tab between the clear and the paste lands in front of the
# resume. The resume is confirmed by a new live pid file naming the session.
# A helper call that times out while typing may have typed, so the
# session is then watched for and a manual resume advised only once it is
# seen not to be live. How long each phase took (check, stop, settle, type,
# confirm) goes to stderr as `restart-session: took …`. Nothing is recorded as a deliberate end: the
# process's own SessionEnd records its stop like any other, so
# reopen-sessions.sh treats the session as it would have.
#
# The idle and prompt checks live in desk-lib/restartable.sh, shared with
# session-stale.sh, which offers a restart only where this would accept it;
# the wait for the tab's prompt, the typing and the confirmation in
# desk-lib/tab-resume.sh, shared with ghostty-update.
#
# On Linux (restartable_mode in desk-lib/restartable.sh), where nothing
# outside Ghostty can name a tab or type into one, there is no tab step:
# before the signal this writes a marker, `<marker dir>/<pid of claude's
# shell>` ($XDG_RUNTIME_DIR/claude-restart), holding claude's pid, the
# session id and the same resume command a tab would be typed
# (tab_resume_command), and the `claude` shell function in .shellrc, once
# claude has ended, finds the marker, removes it and runs the resume in that
# same shell. That works only for a session the function started (it puts
# its shell's pid in claude's environment, __CLAUDE_FN_SHELL); any other is
# refused, exit 3, with exit and resume it once by hand as the way to get
# one. The shell is not replaced, so shell config that changed since it
# started is not picked up by the resume. The resume is confirmed as below;
# a marker nothing picked up is removed and the failure says so.
#
# Output: one tab-separated line, `<status> <id> <name> <detail>`, status
# restarted, refused or failed. Exit 0 when restarted, 1 refused or failed,
# 2 usage, 3 refused because its tab would close with it: a tab opened
# before tabs left a prompt, where exiting the session and resuming it once
# by hand gives a tab later restarts work in. `failed` after the signal says
# what state the session was left in and how to resume it by hand.
#
# Overrides (tests): $DESK_READER, $DESK_CLOSE_TAB_BIN, $RESTART_SESSION_PS
# (a command printing `pid ppid args` for every process, default ps),
# $RESTART_SESSION_QUIET_MINS, $RESTART_SESSION_GRACE_SECS (default 10),
# $RESTART_SESSION_PROMPT_SECS (how long to wait for the tab's prompt,
# default 10), $RESTART_SESSION_CONFIRM_SECS (how long to wait for the
# resumed session to show as live, default 20; 0 skips the wait) and
# $RESTART_SESSION_TAB_TIMEOUT_SECS (default 10), $RESTART_SESSION_MODE
# (tab or marker) and $CLAUDE_RESTART_DIR (the marker dir).
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
# shellcheck source=desk-lib/restartable.sh
source "$HERE/desk-lib/restartable.sh"
# shellcheck source=desk-lib/liveness.sh
source "$HERE/desk-lib/liveness.sh"
# shellcheck source=desk-lib/tab-resume.sh
source "$HERE/desk-lib/tab-resume.sh"

# The phase timings this reports on stderr.
t0=$(now_ms)
timings=""
phase() { # name: the time since the last phase, added to $timings
	local t d
	t=$(now_ms)
	d=$(((t - t0) / 100))
	timings="${timings:+$timings }$1=$((d / 10)).$((d % 10))s"
	t0=$t
}

READER="${DESK_READER:-session-status.sh}"
TAB_HELPER="${DESK_CLOSE_TAB_BIN:-desk-close-tab.sh}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CONFIG_DIR%/}"
GRACE="${RESTART_SESSION_GRACE_SECS:-10}"
PROMPT_SECS="${RESTART_SESSION_PROMPT_SECS:-10}"
CONFIRM_SECS="${RESTART_SESSION_CONFIRM_SECS:-20}"
TAB_TIMEOUT="${RESTART_SESSION_TAB_TIMEOUT_SECS:-10}"

id="${1:-}"
if [ $# -ne 1 ] || [ -z "$id" ]; then
	echo "usage: restart-session.sh <session-id>" >&2
	exit 2
fi

name=""
report() { # status detail [exit code]
	printf '%s\t%s\t%s\t%s\n' "$1" "$id" "${name:--}" "$2"
	[ -z "${timings:-}" ] || echo "restart-session: took $timings" >&2
	[ -n "${3:-}" ] && exit "$3"
	[ "$1" = restarted ]
	exit $?
}

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
restartable_procs || report failed "could not list processes"
transcript="$(jq -r '.transcript_path // empty' <<< "$entries")"
[ -n "$transcript" ] || report refused "no transcript, so no way to tell whether subagents are running"
restartable_idle "$pid" "$pidfile" "$(dirname "$transcript")/$id/subagents" \
	|| report refused "$restartable_why"
restartable_schedules "$pidfile" "$transcript" || report refused "$restartable_why"

# --- the tab, and whether it is left at a prompt ---

restartable_prompt "$pid" || report refused "$restartable_why" 3
cwd="$(jq -r '.cwd // empty' <<< "$entries")"
restartable_flags "$pid" "${cwd:-/}" || report refused "$restartable_why"

tty="$(jq -r '.tty // empty' <<< "$entries")"
recorded_tty="$(jq -r '.recorded_tty // empty' <<< "$entries")"
if [ -z "$tty" ] || [ "$tty" = "??" ]; then
	report refused "the session has no terminal"
fi
if [ -n "$recorded_tty" ] && [ "${recorded_tty#/dev/}" != "${tty#/dev/}" ]; then
	report refused "its tty $tty is not the one its start recorded ($recorded_tty)"
fi

mode="$(restartable_mode)"
terminal=""
if [ "$mode" = tab ]; then
	tab_call find "$tty" "$pid"
	terminal="$tab_out"
	if [ "$tab_rc" -ne 0 ] || [ -z "$terminal" ]; then
		report refused "could not tell its tab apart${tab_why:+: $tab_why}"
	fi
fi

# --- stop it ---

# The tab lookup can take seconds, so anything that started meanwhile is
# caught here, as close to the signal as the checks can get.
restartable_procs || report failed "could not list processes"
{ restartable_idle "$pid" "$pidfile" "$(dirname "$transcript")/$id/subagents" \
	&& restartable_schedules "$pidfile" "$transcript"; } \
	|| report refused "$restartable_why (since the first look)"

claude_args="${restartable_carry:+$restartable_carry }--resume $id"
by_hand="resume it by hand: $(tab_resume_command "$cwd" "$CONFIG_DIR" "$claude_args")"

# The shells claude ran under, as they were before it ended: one that is
# still the same process, with the same argv, afterwards was already
# sitting at its prompt, so it has settled.
pre_parent="$(parent_of "$pid")"
pre_parent_args="$(args_of "$pre_parent")"
pre_grand="$(parent_of "$pre_parent")"
pre_grand_args="$(args_of "$pre_grand")"
phase check

# In marker mode the shell's `claude` function runs the resume, so the marker
# is in place before claude can end.
marker=""
if [ "$mode" = marker ]; then
	marker="$(restartable_marker_dir)/$pre_parent"
	if ! { mkdir -p -m 700 "$(dirname "$marker")" \
		&& printf '%s\n%s\n%s\n' "$pid" "$id" "$(tab_resume_command "$cwd" "$CONFIG_DIR" "$claude_args")" > "$marker"; }; then
		rm -f "$marker"
		report failed "could not write the restart marker ($marker)"
	fi
fi

# Said before the signal, so a caller that has to end this script part way
# still has what to tell the user.
echo "restart-session: stopping the session; if nothing more is reported, $by_hand" >&2
kill -TERM "$pid" 2> /dev/null
until_s=$((SECONDS + GRACE))
while { desk_pid_alive "$pid" || [ -e "$pidfile" ]; } && [ "$SECONDS" -lt "$until_s" ]; do
	sleep 0.2
done
phase stop
if desk_pid_alive "$pid"; then
	[ -z "$marker" ] || rm -f "$marker"
	report failed "pid $pid survived SIGTERM for ${GRACE}s; nothing more done"
fi

if [ "$mode" = marker ]; then
	# The shell's function takes the marker (removing it) and resumes.
	[ "$CONFIRM_SECS" -gt 0 ] || report restarted "resume left for its shell"
	until_s=$((SECONDS + CONFIRM_SECS))
	while [ "$SECONDS" -lt "$until_s" ]; do
		sleep 0.25
		if now="$(tab_resumed_pid "$CONFIG_DIR" "$id" "$pid")"; then
			phase confirm
			report restarted "resumed in its shell (pid $now)"
		fi
	done
	phase confirm
	if [ -e "$marker" ]; then
		rm -f "$marker"
		report failed "the session stopped, but its shell did not pick up the resume within ${CONFIRM_SECS}s (is it still there?); $by_hand"
	fi
	report failed "the resume was started by its shell, but the session is not live after ${CONFIRM_SECS}s; look at the tab"
fi

# --- resume it in the tab ---

# A shell claude ran under, unchanged, was waiting at its prompt all along;
# any other (the one a restarted tab execs) must hold still first
# (tab_await_prompt in desk-lib/tab-resume.sh).
tab_await_prompt "$terminal" "$PROMPT_SECS" "$pre_parent" "$pre_parent_args" "$pre_grand" "$pre_grand_args"
shell_pid="$tab_shell_pid"
phase settle
if [ -n "$tab_unreached" ]; then
	report failed "the session stopped, but its tab is out of reach ($tab_unreached); $by_hand"
fi
if [ -z "$shell_pid" ]; then
	report failed "the session stopped, but its tab showed no settled prompt within ${PROMPT_SECS}s (${tab_last_seen:-nothing in the foreground}); $by_hand"
fi

# A type that timed out may still have typed and run the resume, so a
# manual resume is advised only once the session is seen not to be live:
# two processes on one transcript is the outcome to avoid.
maybe_typed=""
tab_call type "$terminal" "$shell_pid" "$(tab_resume_text "$cwd" "$CONFIG_DIR" "$claude_args")"
if [ "$tab_rc" -eq 124 ]; then
	maybe_typed=1
	[ "$CONFIRM_SECS" -gt 0 ] \
		|| report failed "the session stopped and the tab helper timed out while typing, so the resume may have been typed; look at the tab before resuming it by hand"
elif [ "$tab_rc" -ne 0 ]; then
	report failed "the session stopped, but the resume was not typed${tab_why:+: $tab_why}; $by_hand"
fi
phase type

# The resumed process shows as a new pid file naming the session
# (tab_resumed_pid).
[ "$CONFIRM_SECS" -gt 0 ] || report restarted "resume typed into its tab"
until_s=$((SECONDS + CONFIRM_SECS))
while [ "$SECONDS" -lt "$until_s" ]; do
	sleep 0.25
	if now="$(tab_resumed_pid "$CONFIG_DIR" "$id" "$pid")"; then
		phase confirm
		report restarted "resumed in its tab (pid $now)"
	fi
done
phase confirm
if [ -n "$maybe_typed" ]; then
	report failed "the session stopped and the tab helper timed out while typing; it is not live after ${CONFIRM_SECS}s, so if its tab shows nothing running, $by_hand"
fi
report failed "the resume was typed into its tab, but the session is not live after ${CONFIRM_SECS}s; look at the tab"
