#!/usr/bin/env bash
# Reopens the Claude Code sessions that were open when the machine last went
# down, each resumed with `claude --resume <id>` in its recorded cwd in a
# background Ghostty tab. Meant to be run by an agent on the user's behalf
# (agents/skills/reopen-sessions), so its output is one parseable line per
# session plus a summary line, or one JSON object with --json.
#
# Usage: reopen-sessions.sh [--dry-run] [--json] [--all-boots]
#                           [--idle-days N] [--session ID]...
#
#   --dry-run     list what would happen; opens nothing.
#   --json        one JSON object instead of lines.
#   --all-boots   also consider sessions left open by boots before the last
#                 one (old orphans), which are otherwise only counted.
#   --idle-days N override the idle threshold, in working days.
#   --session ID  act on just this session (a full id, or a unique prefix of
#                 8+ characters), opening it even when idle. Repeatable. It
#                 must be one of the sessions this run would list.
#
# Which sessions. Every recorder start event carries the boot it happened in
# (claude/hooks/session-recorder.sh), and a process cannot outlive its boot,
# so boots are what separate "open when the machine went down" from an old
# orphan. A session counts when its latest run is in the previous boot (the
# latest boot id in the store older than this one) or in this boot, and the
# reader reports it `left_open`: not live, not a scheduled desk-run call, and
# stopped without a deliberate end (the reader's header and docs/desk.md say
# which ends are deliberate; open_when_stopped below is the only place this
# file asks). A session left open by an older boot is an old orphan, counted
# but not listed unless --all-boots asks for it. A live session that had a
# run in the previous boot reports as running.
#
# Idle. A session is idle when its user's last human message is at least
# `close_after_working_days` working days old, the same measure and the same
# function (desk-lib/lock.sh's desk_working_days_since) the close step uses;
# the threshold comes from the desk config ($DESK_CONFIG, else
# ${XDG_CONFIG_HOME:-~/.config}/desk/config.json, as the close step finds
# it), else 3. Idle ones are listed with their last-message date and not
# opened, so the user decides.
#
# Restored tabs. After a crash or shutdown Ghostty restores its windows and
# tabs as blank shells, each with the terminal id it had. The recorder notes
# the id of the tab each session started or was resumed in (and refreshes it
# when Hammerspoon sees the session's tab focused), so a session whose
# newest recorded id belongs to a restored tab sitting idle at a shell
# prompt is resumed there, typed the way restart-session.sh and ghostty-update
# type it (desk-lib/tab-resume.sh), keeping its window and place among the
# tabs. Anything else (no id, no such tab, a tab busy with something, a tab
# another session also claims, the tab helper unreachable) opens a new tab
# as before; the line's detail says which, and --dry-run says it too. A
# resume typed by a helper call that timed out may have run, so that session
# is reported failed rather than opened a second time elsewhere.
#
# Line format (tab-separated):
#   <status> <id> <last message, local YYYY-MM-DD HH:MM> <idle working days>
#   <name> <cwd> <detail>
# status is one of: opened, would-open, running, idle, failed. A final line
# starts with "summary" and carries key=value counts.
#
# Exit codes: 0 nothing failed (including nothing to do); 1 at least one
# session failed to open or was refused; 2 usage error; 3 the inputs could
# not be read (no session store, the reader failed, no boot time), so no
# list was produced at all.
#
# The bell. Ghostty's bell marker on a tab does not survive a restart, so
# it is derived instead: before opening a session, its transcript's latest
# turn is judged by the bell hook's own idle check (claude/hooks/
# input-bell.sh --last-turn: a `[needs-you]` line or a closing direct
# question). Once the opened session is live, a needs-you one gets BEL
# written to the tty the reader reports for it, so its background tab
# carries the marker again. Only sessions this run opened and saw live are
# rung; the line's detail and the JSON's `bell_rung` say which, and the
# summary counts them as `rang`.
#
# Every opener call runs with stdin from /dev/null and under a hard timeout
# that kills its process group: `hs` reads a piped stdin as more commands
# and blocks until EOF, so an inherited stdin can hang it or eat input meant
# for something else. A timeout fails that one session and the run carries
# on.
#
# Overrides (tests): $DESK_READER, $DESK_OPEN_TAB_BIN, $CLAUDE_SESSION_STORE,
# $CLAUDE_CONFIG_DIR, $REOPEN_NOW and $REOPEN_BOOT_TIME (epochs),
# $DESK_CLOSE_TAB_BIN (the tab helper, default desk-close-tab.sh),
# $RESTART_SESSION_PS, $REOPEN_PROMPT_SECS (how long a restored tab gets to
# show a settled shell prompt, default 10),
# $REOPEN_TAB_TIMEOUT_SECS (default 10), $REOPEN_CONFIRM_SECS (how long to
# wait for an opened session to show as live, default 20; 0 skips the wait,
# and with it the bell), $REOPEN_TTY_DIR (where the reader's tty names
# resolve, default /dev).
set -u

usage() {
	sed -n '/^# Usage:/,/^#   --session/{s/^# \{0,1\}//;p;}' "$0" >&2
	printf '  (see the header of %s for the rest)\n' "$0" >&2
	exit 2
}

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

# lock.sh and timeout.sh are sourced on their own rather than through
# common.sh, which creates the runner's state directories as a side effect;
# a dry run must not write under ~/.local/state. These two are the helpers
# they expect common.sh to have defined.
desk_now() { echo "$NOW"; }
desk_pid_alive() { kill -0 "$1" 2> /dev/null; }
DESK_KILL_GRACE_SECS=2
# shellcheck source=desk-lib/lock.sh
source "$HERE/desk-lib/lock.sh"
# shellcheck source=desk-lib/timeout.sh
source "$HERE/desk-lib/timeout.sh"
# shellcheck source=desk-lib/restartable.sh
source "$HERE/desk-lib/restartable.sh"
# shellcheck source=desk-lib/liveness.sh
source "$HERE/desk-lib/liveness.sh"
# shellcheck source=desk-lib/tab-resume.sh
source "$HERE/desk-lib/tab-resume.sh"

dry_run=false
json=false
all_boots=false
idle_days_override=""
selectors=()
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) dry_run=true ;;
		--json) json=true ;;
		--all-boots) all_boots=true ;;
		--idle-days)
			[ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage
			idle_days_override="$2"
			shift
			;;
		--session)
			[ $# -ge 2 ] && [ -n "$2" ] || usage
			selectors+=("$2")
			shift
			;;
		-h | --help) usage ;;
		*) usage ;;
	esac
	shift
done

READER="${DESK_READER:-session-status.sh}"
OPENER="${DESK_OPEN_TAB_BIN:-desk-open-tab.sh}"
STORE_DIR="${CLAUDE_SESSION_STORE:-$HOME/.local/state/claude/session-events}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Above desk-open-tab.sh's own limit on hs (6s and a kill), so that one
# reports first when it fires; this is the backstop for everything else.
TAB_TIMEOUT="${REOPEN_TAB_TIMEOUT_SECS:-10}"
TAB_HELPER="${DESK_CLOSE_TAB_BIN:-desk-close-tab.sh}"
PROMPT_SECS="${REOPEN_PROMPT_SECS:-10}"
CONFIRM_SECS="${REOPEN_CONFIRM_SECS:-20}"
TTY_DIR="${REOPEN_TTY_DIR:-/dev}"
BELL_HOOK="$HERE/hooks/input-bell.sh"
NOW="${REOPEN_NOW:-$(date +%s)}"
# Boot ids a few minutes apart are treated as one boot: kern.boottime can be
# nudged when the wall clock is stepped, and a new boot never follows the
# last one by that little.
BOOT_TOLERANCE_SECS=300

# A work account's seats (~/.claude-work, ~/.claude-work-<n>) are one account's
# config dirs: a run on one may reopen a session that lives on another.
is_work_seat() {
	case "${1%/}" in "$HOME/.claude-work" | "$HOME"/.claude-work-[0-9]*) return 0 ;; esac
	return 1
}

die_inputs() {
	printf 'reopen-sessions: %s\n' "$1" >&2
	exit 3
}

current_boot() {
	if [ -n "${REOPEN_BOOT_TIME:-}" ]; then
		echo "$REOPEN_BOOT_TIME"
	elif [ -r /proc/stat ]; then
		awk '/^btime/ {print $2}' /proc/stat
	else
		sysctl -n kern.boottime 2> /dev/null \
			| sed -n 's/.*{[[:space:]]*sec[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p'
	fi
}

is_uuid() {
	[[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

fmt_time() {
	[[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "-"; return; }
	if desk_is_linux; then date -d "@$1" '+%Y-%m-%d %H:%M'; else date -j -r "$1" '+%Y-%m-%d %H:%M'; fi
}

idle_threshold=3
idle_source=default
# The same config the close step reads: $DESK_CONFIG, else the default path.
desk_config="${DESK_CONFIG:-}"
[ -n "$desk_config" ] || desk_config="${DESK_CONFIG_DEFAULT:-${XDG_CONFIG_HOME:-$HOME/.config}/desk/config.json}"
if [ -n "$idle_days_override" ]; then
	idle_threshold="$idle_days_override"
	idle_source=flag
elif [ -r "$desk_config" ]; then
	v="$(jq -r '.close_after_working_days // empty' "$desk_config" 2> /dev/null)"
	if [[ "$v" =~ ^[0-9]+$ ]]; then
		idle_threshold="$v"
		idle_source=config
	fi
fi

boot_now="$(current_boot)"
[[ "$boot_now" =~ ^[0-9]+$ ]] || die_inputs "could not read the current boot time"
[ -d "$STORE_DIR" ] || die_inputs "no session store at $STORE_DIR (is the recorder hook wired?)"

# Whether a session was left open when it stopped, from its reader record.
# The reader is the one implementation of that judgement (`left_open`); a
# record without the field comes from a reader too old to make it, and is
# refused below rather than read as "not open".
open_when_stopped() { # reader-record-json -> prints true/false
	jq -r '.left_open == true' <<< "$1"
}

# --------------------------------------------------------------------------
# 1. From the raw event records: per session, the boot of each run (one per
#    start event).
# --------------------------------------------------------------------------
shopt -s nullglob
store_files=("$STORE_DIR"/*.jsonl)
shopt -u nullglob

# A file that does not parse (a record from before the recorder's format) is
# skipped, like the reader does.
# The terminal is the newest one a start or a terminal event names; a start
# that found none makes it unknown, since an older id may be another tab's.
RUNS_JQ='{runs: map(select(.event == "start") | {boot: ((.boot // "") | tostring)}),
	terminal: ([.[] | select(.event == "start" or .event == "terminal")] | last | (.terminal // "") | tostring),
	terminal_time: ([.[] | select(.event == "start" or .event == "terminal")] | last | (.time // 0))}'
records=()
# The latest event of any kind before this boot: the machine went down
# somewhere between it and the boot itself.
last_before_boot=""
for f in "${store_files[@]}"; do
	id="$(basename "$f" .jsonl)"
	summary="$(jq -cs "$RUNS_JQ" "$f" 2> /dev/null)" || continue
	[ -n "$summary" ] || continue
	records+=("$(jq -cn --arg id "$id" --argjson s "$summary" '$s + {id: $id}')")
	t="$(jq -s --argjson b "$boot_now" '[.[].time | numbers | select(. < $b)] | max // empty' "$f" 2> /dev/null)"
	if [[ "$t" =~ ^[0-9]+$ ]] && { [ -z "$last_before_boot" ] || [ "$t" -gt "$last_before_boot" ]; }; then
		last_before_boot="$t"
	fi
done

all_records="$(printf '%s\n' "${records[@]+"${records[@]}"}" | jq -cs '.')" \
	|| die_inputs "could not combine the event records"

# The previous boot: the latest recorded boot id clearly older than this one.
prev_boot="$(jq -r --argjson now "$boot_now" --argjson tol "$BOOT_TOLERANCE_SECS" '
	[.[].runs[].boot | select(test("^[0-9]+$")) | tonumber | select(. < $now - $tol)] | max // empty
' <<< "$all_records")" || die_inputs "could not work out the previous boot"

# Per session: which boot its latest run belongs to (current, previous,
# older, unknown), and whether it had a run in the previous boot.
classified="$(jq -c --argjson now "$boot_now" --arg prev "$prev_boot" --argjson tol "$BOOT_TOLERANCE_SECS" '
	def num: if type == "string" and test("^[0-9]+$") then tonumber else null end;
	def boot_class:
		(.boot | num) as $b
		| if $b == null then "unknown"
		  elif ($b - $now | fabs) <= $tol then "current"
		  elif $prev != "" and ($b - ($prev | tonumber) | fabs) <= $tol then "previous"
		  else "older" end;
	map(select(.runs | length > 0)) | map(. + {
		latest_boot: (.runs | last | boot_class),
		ran_in_previous: (.runs | any(boot_class == "previous"))
	})
' <<< "$all_records")" || die_inputs "could not classify the event records"

# --------------------------------------------------------------------------
# 2. The reader, for liveness, name, cwd, transcript and last human message.
# --------------------------------------------------------------------------
read_sessions() {
	local out
	out="$("$READER" < /dev/null 2> /dev/null)" || return 1
	jq -cs 'map({key: .id, value: .}) | from_entries' <<< "$out" 2> /dev/null
}
reader_json="$(read_sessions)" || die_inputs "the session reader ($READER) failed"
[ -n "$reader_json" ] || die_inputs "the session reader ($READER) returned nothing parseable"
[ "$(jq 'any(.[]; .has_start_event == true and (has("left_open") | not))' <<< "$reader_json")" = "false" ] \
	|| die_inputs "the session reader ($READER) does not report left_open; it is older than this command"

# Since the last shutdown means a latest run in the previous boot or this
# one; anything older is an old orphan, only counted unless --all-boots.
candidates="$(jq -c --argjson all "$all_boots" '
	map(select(.latest_boot == "previous" or .latest_boot == "current" or $all))
' <<< "$classified")" || die_inputs "could not select candidates"
older_count="$(jq --argjson r "$reader_json" '[.[] | select((.latest_boot == "older" or .latest_boot == "unknown")
	and ($r[.id].left_open == true))] | length' <<< "$classified")" \
	|| die_inputs "could not count older orphans"

# Selection, when --session narrows it: each selector must resolve to exactly
# one candidate.
results=()
add_result() { # status id name cwd last_human idle_wd detail [confirmed] [bell_rung] [placement]
	results+=("$(jq -cn --arg status "$1" --arg id "$2" --arg name "$3" --arg cwd "$4" \
		--arg lh "$5" --arg wd "$6" --arg detail "$7" --arg confirmed "${8:-}" --arg bell "${9:-}" --arg placement "${10:-}" '
		{status: $status, id: $id, name: $name, cwd: $cwd,
		 last_human_message: ($lh | tonumber? // null),
		 idle_working_days: ($wd | tonumber? // null),
		 detail: $detail}
		+ (if $confirmed == "" then {} else {confirmed_live: ($confirmed == "true")} end)
		+ (if $bell == "" then {} else {bell_rung: ($bell == "true")} end)
		+ (if $placement == "" then {} else {placement: $placement} end)')")
}

selected_ids=()
if [ "${#selectors[@]}" -gt 0 ]; then
	for sel in "${selectors[@]}"; do
		mapfile -t hits < <(jq -r --arg s "$sel" '
			.[] | .id | select(. == $s or (($s | length) >= 8 and startswith($s)))
		' <<< "$candidates")
		if [ "${#hits[@]}" -eq 1 ]; then
			selected_ids+=("${hits[0]}")
		elif [ "${#hits[@]}" -eq 0 ]; then
			add_result failed "$sel" "" "" "" "" "not among the sessions open at the last shutdown"
		else
			add_result failed "$sel" "" "" "" "" "ambiguous: matches ${#hits[@]} sessions"
		fi
	done
	candidates="$(printf '%s\n' "${selected_ids[@]+"${selected_ids[@]}"}" | jq -R -s -c --argjson c "$candidates" '
		split("\n") | map(select(length > 0)) as $ids | $c | map(select(.id as $i | $ids | index($i)))
	')"
fi
narrowed=false
[ "${#selectors[@]}" -gt 0 ] && narrowed=true

# --------------------------------------------------------------------------
# 3. Classify each candidate against the reader, most recent message first.
# --------------------------------------------------------------------------
ended_deliberately=0
to_open=()

mapfile -t cand_lines < <(jq -c --argjson r "$reader_json" '
	map(. as $c | ($r[$c.id] // null) as $e | {c: $c, e: $e})
	| sort_by(-((.e.last_human_message // .e.last_activity // 0)))
	| .[]
' <<< "$candidates")

for line in "${cand_lines[@]+"${cand_lines[@]}"}"; do
	id="$(jq -r '.c.id' <<< "$line")"
	entry="$(jq -c '.e' <<< "$line")"
	ran_in_previous="$(jq -r '.c.ran_in_previous' <<< "$line")"
	name="$(jq -r '.name // ""' <<< "$entry" 2> /dev/null)"
	cwd="$(jq -r '.cwd // ""' <<< "$entry" 2> /dev/null)"
	lh="$(jq -r '(.last_human_message // .last_activity) // empty' <<< "$entry" 2> /dev/null)"
	wd=""
	[[ "$lh" =~ ^[0-9]+$ ]] && wd="$(desk_working_days_since "$lh" "$NOW")"

	if [ "$entry" = "null" ]; then
		add_result failed "$id" "" "" "" "" "the reader has no entry for this session"
		continue
	fi
	# Live: worth a line only when it was running before the restart too.
	if [ "$(jq -r '.live' <<< "$entry")" = "true" ]; then
		if [ "$ran_in_previous" = "true" ] || [ "$narrowed" = true ]; then
			add_result running "$id" "$name" "$cwd" "$lh" "$wd" "already live (pid $(jq -r '.pid // "?"' <<< "$entry"))"
		fi
		continue
	fi
	if [ "$(open_when_stopped "$entry")" != "true" ]; then
		if [ "$(jq -r '.end_deliberate == true' <<< "$entry")" = "true" ]; then
			ended_deliberately=$((ended_deliberately + 1))
			[ "$narrowed" = true ] && add_result failed "$id" "$name" "$cwd" "$lh" "$wd" \
				"ended deliberately ($(jq -r '.end_reason // "?"' <<< "$entry")); not reopened"
		fi
		continue
	fi
	how="no end recorded"
	[ "$(jq -r '.ended' <<< "$entry")" = "true" ] \
		&& how="ended without the user (reason $(jq -r '.end_reason // "none"' <<< "$entry"))"
	if ! is_uuid "$id"; then
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "not a session id (refusing: an empty or malformed id opens the resume picker)"
		continue
	fi
	if [ -z "$wd" ]; then
		add_result failed "$id" "$name" "$cwd" "" "" "no last-message time to judge idleness by"
		continue
	fi
	if [ "$narrowed" = false ] && [ "$wd" -ge "$idle_threshold" ]; then
		add_result idle "$id" "$name" "$cwd" "$lh" "$wd" "idle ${wd} working days (threshold ${idle_threshold}); not opened; $how"
		continue
	fi
	tp="$(jq -r '.transcript_path // ""' <<< "$entry")"
	# The seat the session lives on, as the reader names it (a work account
	# can have several); the caller's own when it names none.
	cdir="$(jq -r '.config_dir // empty' <<< "$entry")"
	cdir="${cdir:-$CONFIG_DIR}"
	if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "recorded cwd does not exist"
		continue
	fi
	if [ -z "$tp" ] || [ ! -f "$tp" ]; then
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "transcript is gone"
		continue
	fi
	case "$tp" in
		"$cdir"/projects/*) [ "$cdir" = "$CONFIG_DIR" ] || { is_work_seat "$cdir" && is_work_seat "$CONFIG_DIR"; } || tp="" ;;
	esac
	case "$tp" in
		"$cdir"/projects/*) ;;
		*)
			add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "transcript is under another Claude config dir than $cdir; run with that CLAUDE_CONFIG_DIR"
			continue
			;;
	esac
	to_open+=("$(jq -cn --arg id "$id" --arg name "$name" --arg cwd "$cwd" --arg lh "$lh" --arg wd "$wd" --arg how "$how" --arg tp "$tp" --arg cdir "$cdir" \
		--arg terminal "$(jq -r '.c.terminal // ""' <<< "$line")" --argjson tt "$(jq -r '.c.terminal_time // 0' <<< "$line")" \
		'{id: $id, name: $name, cwd: $cwd, lh: $lh, wd: $wd, how: $how, tp: $tp, cdir: $cdir, terminal: $terminal, terminal_time: $tt}')")
done

# --------------------------------------------------------------------------
# 4. Open (or, under --dry-run, only say so). Liveness is re-read right
#    before each open: the reader's first answer can be seconds old by now.
# --------------------------------------------------------------------------
reader_entry() { # id -> the reader's current entry, or nothing
	local out
	out="$("$READER" < /dev/null 2> /dev/null)" || return 1
	jq -c --arg id "$1" 'select(.id == $id)' <<< "$out" 2> /dev/null | head -n 1
}

# The single place a tab is asked for. Refuses anything not UUID-shaped
# again here, so no path into it can resume with an empty id.
open_tab() { # id cwd config-dir -> sets open_detail; returns 0 when the opener reported success
	local id="$1" cwd="$2" cdir="$3" out rc printed
	if ! is_uuid "$id"; then
		open_detail="not a session id"
		return 1
	fi
	out="$(mktemp "${TMPDIR:-/tmp}/reopen-sessions.XXXXXX")"
	run_with_timeout "$TAB_TIMEOUT" "$out" \
		"$OPENER" "CLAUDE_CONFIG_DIR=$(shq "$cdir") claude --resume $(shq "$id")" "$id" "$cwd" background \
		< /dev/null
	rc=$?
	printed="$(cat "$out" "$out.stderr" 2> /dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
	rm -f "$out" "$out.stderr"
	if [ "$rc" -eq 124 ]; then
		open_detail="opener timed out (its own limit on hs, or this command's ${TAB_TIMEOUT}s); a tab may still appear, so re-run --dry-run before retrying"
		return 1
	fi
	if [ "$rc" -ne 0 ]; then
		# desk-open-tab.sh exits non-zero whenever DeskOpenTab did not open
		# the tab, printing why; a locked screen is the one refusal worth
		# naming, since unlocking and re-running is the whole fix.
		case "$printed" in
			*"screen locked"*) open_detail="the screen is locked, so the opener refused; unlock and re-run" ;;
			*) open_detail="opener failed (exit $rc)${printed:+: $printed}" ;;
		esac
		return 1
	fi
	open_detail=""
	return 0
}

confirm_live() { # id -> true once the reader reports it live, within CONFIRM_SECS; sets live_tty
	local id="$1" waited=0 e
	live_tty=""
	[ "$CONFIRM_SECS" -gt 0 ] 2> /dev/null || return 2
	while [ "$waited" -lt "$CONFIRM_SECS" ]; do
		sleep 1
		waited=$((waited + 1))
		e="$(reader_entry "$id")"
		if [ "$(jq -r '.live // false' <<< "$e" 2> /dev/null)" = "true" ]; then
			live_tty="$(jq -r '.tty // ""' <<< "$e" 2> /dev/null)"
			return 0
		fi
	done
	return 1
}

ring_tty() { # tty name as the reader reports it (ttys012, pts/3) -> 0 when BEL was written
	[[ "$1" =~ ^[A-Za-z0-9/]+$ ]] && [[ "$1" != *..* ]] || return 1
	[ -w "$TTY_DIR/$1" ] || return 1
	printf '\a' 2> /dev/null > "$TTY_DIR/$1"
}

# A terminal id two sessions both name (one was resumed in the tab the
# other ran in) belongs to the one recorded there last; the other opens a
# new tab.
if [ "${#to_open[@]}" -gt 0 ]; then
	mapfile -t to_open < <(printf '%s\n' "${to_open[@]}" | jq -cs '
		. as $all | to_entries[] | .key as $i | .value as $v
		| if $v.terminal == "" then $v
		  elif ([$all | to_entries[] | select(.value.terminal == $v.terminal)]
		        | sort_by([-.value.terminal_time, .key]) | .[0].key) == $i then $v
		  else $v + {terminal: "", shared: true} end')
fi

# restored_tab <terminal id>: 0 when Ghostty has a terminal with that id,
# sitting at a settled interactive shell, and $tab_shell_pid is that shell;
# otherwise 1 with the reason in $tab_reason. Only reads.
restored_tab() {
	tab_reason=""
	tab_call pid "$1"
	if [ "$tab_rc" -ne 0 ]; then
		case "$tab_why" in
			*"no Ghostty terminal has that id"*) tab_reason="restored tab not found" ;;
			*) tab_reason="restored tab not reachable: ${tab_why:-exit $tab_rc}" ;;
		esac
		return 1
	fi
	if ! tab_await_prompt "$1" "$PROMPT_SECS"; then
		tab_reason="its restored tab is not at an idle shell prompt (${tab_unreached:-${tab_last_seen:-nothing in the foreground}})"
		return 1
	fi
	return 0
}

for item in "${to_open[@]+"${to_open[@]}"}"; do
	id="$(jq -r '.id' <<< "$item")"
	name="$(jq -r '.name' <<< "$item")"
	cwd="$(jq -r '.cwd' <<< "$item")"
	lh="$(jq -r '.lh' <<< "$item")"
	wd="$(jq -r '.wd' <<< "$item")"
	how="$(jq -r '.how' <<< "$item")"
	tp="$(jq -r '.tp' <<< "$item")"
	cdir="$(jq -r '.cdir' <<< "$item")"
	terminal="$(jq -r '.terminal' <<< "$item")"
	tabnote=""
	[ "$(jq -r '.shared // false' <<< "$item")" = true ] && tabnote="another session was recorded in its tab since"
	if [ "$dry_run" = true ]; then
		if [ -n "$terminal" ] && restored_tab "$terminal"; then
			add_result would-open "$id" "$name" "$cwd" "$lh" "$wd" "would resume in its restored tab; $how" "" "" restored-tab
		else
			[ -n "$terminal" ] && tabnote="$tab_reason"
			add_result would-open "$id" "$name" "$cwd" "$lh" "$wd" "would resume in a new background tab${tabnote:+ ($tabnote)}; $how" "" "" new-tab
		fi
		continue
	fi
	fresh="$(reader_entry "$id")" || fresh=""
	if [ -z "$fresh" ]; then
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "could not re-check liveness just before opening"
		continue
	fi
	if [ "$(jq -r '.live' <<< "$fresh")" = "true" ]; then
		add_result running "$id" "$name" "$cwd" "$lh" "$wd" "became live before it was opened (pid $(jq -r '.pid // "?"' <<< "$fresh"))"
		continue
	fi
	# Judged before the open, from the transcript as the session left it.
	needs_you="$("$BELL_HOOK" --last-turn "$tp" < /dev/null 2> /dev/null)"
	placed=""
	if [ -n "$terminal" ]; then
		if restored_tab "$terminal"; then
			tab_call type "$terminal" "$tab_shell_pid" "$(tab_resume_text "$cwd" "$cdir" "--resume $id")"
			if [ "$tab_rc" -eq 0 ]; then
				placed=restored-tab
				where="its restored tab"
			elif [ "$tab_rc" -eq 124 ]; then
				add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "the helper timed out typing the resume into its restored tab, so it may have run; look at the tab before resuming it elsewhere"
				continue
			else
				tabnote="the resume was not typed into its restored tab: ${tab_why:-exit $tab_rc}"
			fi
		else
			tabnote="$tab_reason"
		fi
	fi
	if [ -z "$placed" ]; then
		if open_tab "$id" "$cwd" "$cdir"; then
			placed=new-tab
			where="a background tab${tabnote:+ ($tabnote)}"
		else
			add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "$open_detail"
			continue
		fi
	fi
	opened_txt="tab opened${tabnote:+ ($tabnote)}"
	[ "$placed" = restored-tab ] && opened_txt="typed into its restored tab"
	confirm_live "$id"
	case $? in
		0)
			if [ "$needs_you" = ring ] && ring_tty "$live_tty"; then
				add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "resumed in $where; rang the bell (its last turn needs you); $how" true true "$placed"
			elif [ "$needs_you" = ring ]; then
				add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "resumed in $where; its last turn needs you, but its tty (${live_tty:-none}) could not be rung; $how" true false "$placed"
			else
				add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "resumed in $where; $how" true false "$placed"
			fi
			;;
		1) add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "$opened_txt; not live yet after ${CONFIRM_SECS}s; $how" false "" "$placed" ;;
		*) add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "$opened_txt; $how" "" "" "$placed" ;;
	esac
done

# --------------------------------------------------------------------------
# 5. Report.
# --------------------------------------------------------------------------
# What to act on first: opens, then failures, then the rest; most recent
# message first within each.
results_json="$(printf '%s\n' "${results[@]+"${results[@]}"}" | jq -cs '
	({"opened": 0, "would-open": 0, "failed": 1, "running": 2, "idle": 3}) as $rank
	| sort_by([($rank[.status] // 9), -(.last_human_message // 0)])
')"
summary_json="$(jq -c \
	--argjson dry "$dry_run" --arg prev "$prev_boot" --arg now_boot "$boot_now" --arg down "$last_before_boot" \
	--argjson thr "$idle_threshold" --arg thr_src "$idle_source" \
	--argjson older "$older_count" --argjson deliberate "$ended_deliberately" \
	--argjson all "$all_boots" '
	def n($s): map(select(.status == $s)) | length;
	{dry_run: $dry,
	 previous_boot: ($prev | tonumber? // null), current_boot: ($now_boot | tonumber),
	 last_event_before_boot: ($down | tonumber? // null),
	 idle_after_working_days: $thr, idle_threshold_from: $thr_src,
	 opened: n("opened"), would_open: n("would-open"), running: n("running"),
	 rang: (map(select(.bell_rung == true)) | length),
	 restored_tab: (map(select(.placement == "restored-tab")) | length),
	 idle: n("idle"), failed: n("failed"),
	 older_orphans: $older, older_included: $all,
	 ended_deliberately: $deliberate}
' <<< "$results_json")"

if [ "$json" = true ]; then
	jq -n --argjson s "$summary_json" --argjson r "$results_json" '{summary: $s, sessions: $r}'
else
	while IFS= read -r r; do
		IFS=$'\t' read -r st id name cwd lh wd detail < <(jq -r '
			[.status, .id, (if .name == "" then "-" else .name end), (if .cwd == "" then "-" else .cwd end),
			 (.last_human_message // "" | tostring), (.idle_working_days // "-" | tostring), .detail] | @tsv
		' <<< "$r")
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$id" "$(fmt_time "$lh")" "$wd" "$name" "$cwd" "$detail"
	done < <(jq -c '.[]' <<< "$results_json")
	down_fmt="$(fmt_time "$last_before_boot" | tr ' ' T)"
	boot_fmt="$(fmt_time "$boot_now" | tr ' ' T)"
	jq -r --arg down "$down_fmt" --arg boot "$boot_fmt" '
		"summary\tdry_run=\(.dry_run) opened=\(.opened) restored_tab=\(.restored_tab) rang=\(.rang) would_open=\(.would_open) running=\(.running) idle=\(.idle) failed=\(.failed) older_orphans=\(.older_orphans) ended_deliberately=\(.ended_deliberately) idle_after_working_days=\(.idle_after_working_days)(\(.idle_threshold_from)) went_down_after=\($down) booted=\($boot)"
	' <<< "$summary_json"
fi

if [ "$(jq '.failed' <<< "$summary_json")" -gt 0 ]; then
	exit 1
fi
exit 0
