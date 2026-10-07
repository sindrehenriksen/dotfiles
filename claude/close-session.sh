#!/usr/bin/env bash
# Ends a live Claude Code session on purpose and closes the Ghostty tab it
# ran in. Meant to be run by an agent or by hand from another session: the
# session is recorded as closed (the recorder's `close`, a deliberate end,
# so it is not reopened after a restart), its process gets SIGTERM, and once
# it is gone its tab is closed when the tab can be told apart for certain.
#
# Usage: close-session.sh <session-id>
#
# Refused, with nothing done: an id that is not a full session UUID; a
# session that is not live, or that two processes hold (the reader's
# duplicate_pids); one named in the desk config's `keep_open`; the session
# running this command; a pid that is not a `claude` process.
#
# The tab. It is named before the signal, while the session's process still
# holds its terminal: the one Ghostty terminal on the session's tty whose
# foreground process is the session's pid (desk-close-tab.sh find), and the
# tty must be the one the session's latest start recorded, when it recorded
# one. Only that terminal's id, which Ghostty never reuses, is used after
# the process exits, and the tab closes only when it holds nothing else.
# Anything short of that leaves the tab open and says why: closing the
# wrong tab costs more than leaving one.
#
# Output: one tab-separated line, `<status> <id> <name> <detail>`, status
# closed, refused or failed. Exit 0 when the session was closed (whatever
# became of the tab: the detail says), 1 refused or failed, 2 usage.
#
# Overrides (tests): $DESK_READER, $DESK_SESSION_RECORDER_BIN,
# $DESK_CLOSE_TAB_BIN, $CLOSE_SESSION_GRACE_SECS (default 5),
# $CLOSE_SESSION_TAB_TIMEOUT_SECS (default 10), $DESK_CONFIG and
# $DESK_CONFIG_DEFAULT.
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

# timeout.sh is sourced on its own rather than through common.sh, which
# creates the runner's state directories as a side effect.
desk_pid_alive() { kill -0 "$1" 2> /dev/null; }
DESK_KILL_GRACE_SECS=2
# shellcheck source=desk-lib/timeout.sh
source "$HERE/desk-lib/timeout.sh"

READER="${DESK_READER:-session-status.sh}"
RECORDER="${DESK_SESSION_RECORDER_BIN:-$HERE/hooks/session-recorder.sh}"
TAB_HELPER="${DESK_CLOSE_TAB_BIN:-desk-close-tab.sh}"
GRACE="${CLOSE_SESSION_GRACE_SECS:-5}"
TAB_TIMEOUT="${CLOSE_SESSION_TAB_TIMEOUT_SECS:-10}"

id="${1:-}"
if [ $# -ne 1 ] || [ -z "$id" ]; then
	echo "usage: close-session.sh <session-id>" >&2
	exit 2
fi

name=""
report() { # status detail
	printf '%s\t%s\t%s\t%s\n' "$1" "$id" "${name:--}" "$2"
	[ "$1" = closed ]
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
	|| report refused "more than one process holds this session; close one by hand"
[ "${CLAUDE_CODE_SESSION_ID:-}" != "$id" ] || report refused "this is the session running the command"

config="${DESK_CONFIG:-}"
if [ -z "$config" ]; then
	fallback="${DESK_CONFIG_DEFAULT:-${XDG_CONFIG_HOME:-$HOME/.config}/desk/config.json}"
	[ -e "$fallback" ] && config="$fallback"
fi
if [ -n "$config" ] && [ -n "$name" ]; then
	kept="$(jq -r --arg n "$name" '(.keep_open // []) | index($n) != null' "$config" 2> /dev/null)" \
		|| report failed "could not read keep_open from $config"
	[ "$kept" != "true" ] || report refused "in keep_open"
fi

pid="$(jq -r '.pid // empty' <<< "$entries")"
[[ "$pid" =~ ^[0-9]+$ ]] || report refused "the reader gives no pid"
comm="$(ps -o comm= -p "$pid" 2> /dev/null)"
case "$comm" in
	claude | */claude) ;;
	*) report refused "pid $pid is not a claude process" ;;
esac

# Named now, while the process still holds the terminal.
tty="$(jq -r '.tty // empty' <<< "$entries")"
recorded_tty="$(jq -r '.recorded_tty // empty' <<< "$entries")"
terminal="" tab_note=""
if [ -z "$tty" ] || [ "$tty" = "??" ]; then
	tab_note="the session has no terminal"
elif [ -n "$recorded_tty" ] && [ "${recorded_tty#/dev/}" != "${tty#/dev/}" ]; then
	tab_note="its tty $tty is not the one its start recorded ($recorded_tty)"
else
	out="$(mktemp "${TMPDIR:-/tmp}/close-session.XXXXXX")"
	run_with_timeout "$TAB_TIMEOUT" "$out" "$TAB_HELPER" find "$tty" "$pid" < /dev/null
	rc=$?
	terminal="$(head -n 1 "$out" 2> /dev/null)"
	why="$(tr '\n' ' ' < "$out.stderr" 2> /dev/null | sed 's/[[:space:]]*$//')"
	rm -f "$out" "$out.stderr"
	if [ "$rc" -ne 0 ] || [ -z "$terminal" ]; then
		terminal=""
		tab_note="could not tell its tab apart${why:+: $why}"
		[ "$rc" -eq 124 ] && tab_note="the tab lookup timed out"
	fi
fi

"$RECORDER" close "$id" 2> /dev/null
kill -TERM "$pid" 2> /dev/null
waited=0
while desk_pid_alive "$pid" && [ "$waited" -lt "$GRACE" ]; do
	sleep 1
	waited=$((waited + 1))
done
if desk_pid_alive "$pid"; then
	"$RECORDER" close-failed "$id" 2> /dev/null
	report failed "pid $pid survived SIGTERM for ${GRACE}s; recorded as a failed close, tab left open"
fi
if [ "$("$READER" < /dev/null 2> /dev/null | jq -r --arg id "$id" 'select(.id == $id) | .live' 2> /dev/null)" = "true" ]; then
	report failed "pid $pid is gone but the reader still reports the session live; tab left open"
fi

if [ -z "$terminal" ]; then
	report closed "tab left open: $tab_note"
fi
out="$(mktemp "${TMPDIR:-/tmp}/close-session.XXXXXX")"
run_with_timeout "$TAB_TIMEOUT" "$out" "$TAB_HELPER" close "$terminal" < /dev/null
rc=$?
why="$(tr '\n' ' ' < "$out.stderr" 2> /dev/null | sed 's/[[:space:]]*$//')"
rm -f "$out" "$out.stderr"
[ "$rc" -eq 0 ] && report closed "tab closed"
[ "$rc" -eq 124 ] && report closed "tab left open: closing it timed out"
report closed "tab left open${why:+: $why}"
