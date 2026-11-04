#!/usr/bin/env bash
# Whether a live session can be restarted in place: idle with nothing
# running, in a tab that a prompt outlives. claude/restart-session.sh refuses
# on these, and claude/session-stale.sh offers a restart only where they
# pass, so the two never disagree about which sessions qualify.
#
# Sourced. The caller sets CONFIG_DIR (the session's config dir, no trailing
# slash), and may set $RESTART_SESSION_PS (a command printing `pid ppid args`
# for every process, default ps) and $RESTART_SESSION_QUIET_MINS (default 5).
# Each check returns 0 when it passes, else 1 with the reason in
# $restartable_why.
set -u

# What a restart types after the resume, and how a later restart of the same
# tab knows a prompt follows the session.
RESTARTABLE_HANDOVER="; exec /bin/zsh -il"

# Loads the process table into $procs; 1 when it cannot be listed.
restartable_procs() {
	procs="$("${RESTART_SESSION_PS:-ps}" -A -ww -o pid= -o ppid= -o args= 2> /dev/null)"
}
args_of() { awk -v p="$1" '$1 == p { $1 = ""; $2 = ""; sub(/^  /, ""); print; exit }' <<< "$procs"; }
parent_of() { awk -v p="$1" '$1 == p { print $2; exit }' <<< "$procs"; }

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

# restartable_idle <pid> <pidfile> [subagents-dir...]: its pid file's status
# is idle; it has no shell of its own running (a child `<shell> -c source
# <config dir>/shell-snapshots/snapshot-…`, how Claude Code runs a Bash
# call); and no file under a subagents dir given changed in the last
# $RESTART_SESSION_QUIET_MINS minutes. Other children, the MCP servers, do
# not count. Needs $procs loaded.
restartable_idle() {
	local pid=$1 pidfile=$2 quiet="${RESTART_SESSION_QUIET_MINS:-5}" state running dir recent
	shift 2
	state="$(jq -r '.status // empty' "$pidfile" 2> /dev/null)"
	if [ -z "$state" ]; then
		restartable_why="no status in its pid file ($pidfile)"
		return 1
	fi
	if [ "$state" != idle ]; then
		restartable_why="not idle: its status is $state"
		return 1
	fi
	running="$(awk -v p="$pid" -v pat=" -c source $CONFIG_DIR/shell-snapshots/snapshot-" \
		'$2 == p && index($0, pat) { print $1 }' <<< "$procs" | head -n 1)"
	if [ -n "$running" ]; then
		restartable_why="not idle: it is running a shell command (pid $running)"
		return 1
	fi
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		recent="$(find "$dir" -type f -mmin "-$quiet" 2> /dev/null | head -n 1)"
		if [ -n "$recent" ]; then
			restartable_why="not idle: a subagent wrote in the last ${quiet} min ($(basename "$recent"))"
			return 1
		fi
	done
	return 0
}

# restartable_prompt <pid>: the tab is left at a prompt when claude ends:
# claude's own shell is an interactive one, the command typed into one, or
# the form a restart types. A tab whose only shell is the one running
# claude, which tabs opened before desk-open-tab.sh left a prompt have,
# closes with it. Needs $procs loaded.
restartable_prompt() {
	local parent parent_args grand_args
	parent="$(parent_of "$1")"
	parent_args="$(args_of "$parent")"
	grand_args="$(args_of "$(parent_of "$parent")")"
	if interactive_shell "$parent_args"; then
		return 0
	elif is_shell "$parent_args" && [[ "$parent_args" == *"$RESTARTABLE_HANDOVER" ]]; then
		return 0
	elif is_shell "$parent_args" && interactive_shell "$grand_args"; then
		return 0
	fi
	restartable_why="its tab would close with it: no shell in the tab outlives claude (${parent_args:-no parent})"
	return 1
}
