#!/usr/bin/env bash
# Typing a session's resume into a Ghostty tab's shell, through the tab
# helper (hammerspoon/desk-close-tab.sh): restart-session.sh types it into
# the tab it has just stopped the session in, and ghostty-update into the tab
# Ghostty restored after an update. Both name the tab by its terminal id,
# which Ghostty keeps for the terminal's life and across a restore.
#
# Sourced after desk-lib/timeout.sh, desk-lib/restartable.sh (for $procs and
# the shell checks) and desk-lib/liveness.sh (check_live). The caller sets
# TAB_HELPER and TAB_TIMEOUT.
set -u

# Milliseconds since some fixed point; whole seconds where bash has no
# EPOCHREALTIME.
now_ms() {
	local t="${EPOCHREALTIME:-}"
	if [ -n "$t" ]; then echo $((${t//[.,]/} / 1000)); else echo $((SECONDS * 1000)); fi
}

tab_call() { # args... -> sets tab_rc, tab_out, tab_why
	local out
	out="$(mktemp "${TMPDIR:-/tmp}/tab-resume.XXXXXX")"
	run_with_timeout "$TAB_TIMEOUT" "$out" "$TAB_HELPER" "$@" < /dev/null
	tab_rc=$?
	tab_out="$(head -n 1 "$out" 2> /dev/null)"
	tab_why="$(tr '\n' ' ' < "$out.stderr" 2> /dev/null | sed 's/[[:space:]]*$//')"
	[ "$tab_rc" -eq 124 ] && tab_why="the tab helper timed out"
	rm -f "$out" "$out.stderr"
}

# tab_resume_command <cwd> <config dir> <claude args>: the command that
# resumes the session through the user's `claude` function in its
# directory, under its config dir: what is typed into a tab, and what a
# report gives the user to run by hand.
tab_resume_command() {
	printf '%sCLAUDE_CONFIG_DIR=%s claude %s' "${1:+cd $(restartable_shq "$1") && }" "$(restartable_shq "$2")" "$3"
}

# tab_resume_text <cwd> <config dir> <claude args>: what is typed into the
# tab's shell: a fresh login shell that runs the resume, then leaves a
# prompt in its directory. The leading space keeps it out of history.
tab_resume_text() {
	printf ' exec /bin/zsh -lic %s' "$(restartable_shq "$(tab_resume_command "$@")$RESTARTABLE_HANDOVER")"
}

# tab_await_prompt <terminal> <secs> [<pid> <args>]...: watches the
# terminal's foreground process, four times a second for up to <secs>, until
# it is an interactive shell that has settled, and sets $tab_shell_pid to it
# (empty when none did), $tab_last_seen to the args last seen in the
# foreground and $tab_unreached to why the helper last failed, if its last
# call did. A shell has settled when it is one of the <pid> <args> pairs
# given, unchanged (a shell that was waiting at its prompt all along), or
# else when two looks a second apart find it in the foreground with the same
# children: a shell still reading its startup files comes and goes through
# children, and a Ctrl-C then would cut its startup short. A pid call that
# fails is tried again until the wait runs out; it only reads, so nothing can
# have been typed.
tab_await_prompt() {
	local terminal=$1 secs=$2 seen="" seen_ms=0 look until_ms
	shift 2
	local waiting=("$@")
	tab_shell_pid="" tab_last_seen="" tab_unreached=""
	until_ms=$(($(now_ms) + secs * 1000))
	while :; do
		tab_call pid "$terminal"
		if [ "$tab_rc" -eq 0 ] && [[ "$tab_out" =~ ^[0-9]+$ ]]; then
			tab_unreached=""
			restartable_procs
			tab_last_seen="$(args_of "$tab_out")"
			if interactive_shell "$tab_last_seen"; then
				if _tab_was_waiting "$tab_out" "$tab_last_seen" ${waiting[@]+"${waiting[@]}"}; then
					tab_shell_pid="$tab_out"
					return 0
				fi
				look="$tab_out:$(_tab_children_of "$tab_out")"
				if [ "$look" = "$seen" ] && [ $(($(now_ms) - seen_ms)) -ge 1000 ]; then
					tab_shell_pid="$tab_out"
					return 0
				fi
				if [ "$look" != "$seen" ]; then
					seen="$look"
					seen_ms=$(now_ms)
				fi
			else
				seen=""
			fi
		elif [ "$tab_rc" -ne 0 ]; then
			tab_unreached="${tab_why:-the tab helper failed}"
		fi
		[ "$(now_ms)" -ge "$until_ms" ] && return 1
		sleep 0.25
	done
}
_tab_children_of() { awk -v p="$1" '$2 == p { print $1 }' <<< "$procs" | sort | paste -sd, -; }
_tab_was_waiting() { # pid args [pid args]...
	local pid=$1 args=$2
	shift 2
	while [ $# -ge 2 ]; do
		[ "$pid" = "$1" ] && [ "$args" = "$2" ] && return 0
		shift 2
	done
	return 1
}

# tab_resumed_pid <config dir> <id> <old pid>: prints the pid of a process
# holding the session again, other than <old pid>: a pid file under the
# config dir naming it whose process passes the liveness check
# session-status.sh makes. Read directly rather than through the reader,
# which takes seconds, so it can be looked for four times a second.
tab_resumed_pid() {
	local f p ps
	for f in "$1"/sessions/*.json; do
		[ -f "$f" ] && grep -q "$2" "$f" 2> /dev/null || continue
		IFS=$'\t' read -r p ps < <(jq -r --arg id "$2" \
			'select(.sessionId == $id) | [(.pid // "" | tostring), (.procStart // "")] | @tsv' "$f" 2> /dev/null)
		[[ "${p:-}" =~ ^[0-9]+$ ]] && [ "$p" != "$3" ] || continue
		check_live "$p" "$ps"
		[ "$live" = true ] && { echo "$p"; return 0; }
	done
	return 1
}
