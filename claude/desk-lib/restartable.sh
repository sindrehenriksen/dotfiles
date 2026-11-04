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

restartable_shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
restartable_mtime() { stat -c %Y "$1" 2> /dev/null || stat -f %m "$1" 2> /dev/null; }

# restartable_idle <pid> <pidfile> [subagents-dir...]: its pid file's status
# is idle; it has no shell of its own running (a child `<shell> -c source
# <config dir>/shell-snapshots/snapshot-…`, how Claude Code runs a Bash
# call); and no subagent is running under a subagents dir given: none wrote
# in the last $RESTART_SESSION_QUIET_MINS minutes, and none this process
# started has a `<agent>.meta.json` without `finished: true`, which is what
# catches a background subagent waiting on a long model call, when nothing
# is written for minutes. One a crashed earlier process left unfinished
# predates this process's start and does not count. Other children, the
# MCP servers, do not count. Needs $procs loaded.
restartable_idle() {
	local pid=$1 pidfile=$2 quiet="${RESTART_SESSION_QUIET_MINS:-5}" state running dir recent started meta
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
	started=$(($(jq -r '.startedAt // 0' "$pidfile" 2> /dev/null) / 1000))
	for dir in "$@"; do
		[ -d "$dir" ] || continue
		recent="$(find "$dir" -type f -mmin "-$quiet" 2> /dev/null | head -n 1)"
		if [ -n "$recent" ]; then
			restartable_why="not idle: a subagent wrote in the last ${quiet} min ($(basename "$recent"))"
			return 1
		fi
		while IFS= read -r meta; do
			[ -n "$meta" ] || continue
			if [ "$(restartable_mtime "$meta")" -ge "$started" ]; then
				restartable_why="not idle: a subagent it started has not finished ($(basename "$meta" .meta.json))"
				return 1
			fi
		done < <(find "$dir" -maxdepth 1 -name '*.meta.json' -exec jq -r 'select(.finished != true) | input_filename' {} + 2> /dev/null)
	done
	return 0
}

# restartable_schedules <pidfile> [transcript...]: nothing is scheduled in
# the process itself, which a restart would lose: a ScheduleWakeup still to
# fire, or a CronCreate that is not durable and not deleted, recurring or
# still to fire, made since this process started. Read from the tool
# results in its transcripts, so one made any other way goes unseen. That a
# CronDelete names its cron by `input.id` is assumed: no transcript here
# had one to read.
restartable_schedules() {
	local pidfile=$1 since t found
	shift
	since="$(jq -r '.startedAt // 0' "$pidfile" 2> /dev/null)"
	for t in "$@"; do
		[ -f "$t" ] || continue
		found="$(grep -E '"(scheduledFor|nextFireAt)"|"name":"CronDelete"' "$t" 2> /dev/null \
			| jq -rs --argjson since "${since:-0}" --argjson now "$(($(date +%s) * 1000))" '
				def at: (.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // 0)) * 1000;
				map(select(at >= $since)) as $recs
				| [$recs[] | .message.content[]? | objects | select(.type == "tool_use" and .name == "CronDelete") | .input.id] as $deleted
				| [$recs[] | .toolUseResult? | objects
					| if has("scheduledFor") then
						select(.scheduledFor > $now) | "a wakeup due at \(.scheduledFor / 1000 | floor | strflocaltime("%H:%M"))"
					elif has("nextFireAt") and .durable != true then
						select(.id as $i | $deleted | index($i) | not)
						| select(.recurring == true or .nextFireAt > $now)
						| "a session cron (\(.humanSchedule // .id))"
					else empty end][0] // empty' 2> /dev/null)"
		if [ -n "$found" ]; then
			restartable_why="it has $found scheduled in the process, which a restart would lose"
			return 1
		fi
	done
	return 0
}

# restartable_argv <pid>: the process's exact argv, a NUL after each word:
# /proc on Linux, KERN_PROCARGS2 on macOS (proc-argv.py), or the command in
# $RESTART_SESSION_ARGV, given the pid. Fails when it cannot be read.
restartable_argv() {
	if [ -n "${RESTART_SESSION_ARGV:-}" ]; then
		"$RESTART_SESSION_ARGV" "$1"
	elif [ -r "/proc/$1/cmdline" ]; then
		cat "/proc/$1/cmdline"
	else
		python3 -I "$(dirname "${BASH_SOURCE[0]}")/proc-argv.py" "$1"
	fi
}

# restartable_flags <pid> <cwd>: the flags claude was started with that a
# resume should carry, from its exact argv, into $restartable_carry as
# words quoted for a shell (empty when there are none). Each word is read
# against the options below, with their arities as `claude --help` gives
# them, so a value and a prompt are never mistaken for an option.
#   Left out, since the resume supplies its own: a leading `--settings
#   <file>`, which the user's `claude` function adds; -n/--name <name>;
#   -r/--resume [value]; -c/--continue; --fork-session; and the prompt,
#   any word that is not an option or an option's value, or after `--`.
#   Carried: --model, --effort, --fallback-model, --agent, --permission-mode
#   (but see below), a later --settings, --add-dir <directories...>,
#   --verbose, --ide, --chrome and --no-chrome.
# Refused (returns 1, why in $restartable_why): an argv that cannot be read;
# any other option, which a resume would silently drop; an --add-dir or
# --settings value that is not an existing directory or file from <cwd>;
# and, whatever else the argv says, a flag that bypasses permissions
# (--dangerously-skip-permissions, --allow-dangerously-skip-permissions,
# --permission-mode bypassPermissions), which a restart never passes on its
# own: the user passes it again by hand.
restartable_flags() {
	local cwd=$2 word name val has_val i n words=()
	while IFS= read -r -d '' word; do words+=("$word"); done < <(restartable_argv "$1" 2> /dev/null)
	n=${#words[@]}
	if [ "$n" -eq 0 ]; then
		restartable_why="its argv could not be read, so the flags it was started with are unknown"
		return 1
	fi
	restartable_carry=""
	_rf_carry() { restartable_carry="${restartable_carry:+$restartable_carry }$1"; }
	_rf_at() { case "$1" in /*) [ -e "$1" ] ;; *) [ -e "$cwd/$1" ] ;; esac; }
	_rf_bypass() {
		restartable_why="it was started with $1, which bypasses permissions and a restart never passes on; restart it by hand"
		return 1
	}
	# The next word as the value, unless an = gave one.
	_rf_take() {
		[ -n "$has_val" ] && return 0
		if [ "$i" -ge "$n" ]; then
			restartable_why="its $name has no value"
			return 1
		fi
		val="${words[$i]}" has_val=1
		i=$((i + 1))
	}
	i=1
	[ "${words[1]:-}" = --settings ] && i=3
	while [ "$i" -lt "$n" ]; do
		word="${words[$i]}"
		i=$((i + 1))
		name="$word" val="" has_val=""
		if [[ "$word" == --*=* ]]; then
			name="${word%%=*}" val="${word#*=}" has_val=1
		fi
		case "$name" in
			--)
				break ;;
			-n | --name) _rf_take || return 1 ;;
			-r | --resume)
				if [ -z "$has_val" ] && [ "$i" -lt "$n" ] && [[ "${words[$i]}" != -* ]]; then i=$((i + 1)); fi ;;
			-c | --continue | --fork-session) ;;
			--dangerously-skip-permissions | --allow-dangerously-skip-permissions)
				_rf_bypass "$name"
				return 1 ;;
			--permission-mode)
				_rf_take || return 1
				if [ "$val" = bypassPermissions ]; then
					_rf_bypass "--permission-mode $val"
					return 1
				fi
				_rf_carry "$name $(restartable_shq "$val")" ;;
			--model | --effort | --fallback-model | --agent)
				_rf_take || return 1
				_rf_carry "$name $(restartable_shq "$val")" ;;
			--settings)
				_rf_take || return 1
				if ! _rf_at "$val"; then
					restartable_why="its --settings $val is not a file a restart can find"
					return 1
				fi
				_rf_carry "$name $(restartable_shq "$val")" ;;
			--add-dir)
				if [ -z "$has_val" ]; then
					[ "$i" -lt "$n" ] && [[ "${words[$i]}" != -* ]] || {
						restartable_why="its --add-dir has no directory"
						return 1
					}
				fi
				_rf_carry --add-dir
				while :; do
					if [ -z "$has_val" ]; then
						[ "$i" -lt "$n" ] && [[ "${words[$i]}" != -* ]] || break
						val="${words[$i]}"
						i=$((i + 1))
					fi
					has_val=""
					if ! _rf_at "$val"; then
						restartable_why="its --add-dir $val is not a directory a restart can find"
						return 1
					fi
					_rf_carry "$(restartable_shq "$val")"
				done ;;
			--verbose | --ide | --chrome | --no-chrome) _rf_carry "$name" ;;
			-*)
				restartable_why="it was started with $name, which a resume would drop; restart it by hand"
				return 1 ;;
			*) ;;
		esac
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
