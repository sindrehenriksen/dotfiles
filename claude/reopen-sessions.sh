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
# Every opener call runs with stdin from /dev/null and under a hard timeout
# that kills its process group: `hs` reads a piped stdin as more commands
# and blocks until EOF, so an inherited stdin can hang it or eat input meant
# for something else. A timeout fails that one session and the run carries
# on.
#
# Overrides (tests): $DESK_READER, $DESK_OPEN_TAB_BIN, $CLAUDE_SESSION_STORE,
# $CLAUDE_CONFIG_DIR, $REOPEN_NOW and $REOPEN_BOOT_TIME (epochs),
# $REOPEN_TAB_TIMEOUT_SECS (default 10), $REOPEN_CONFIRM_SECS (how long to
# wait for an opened session to show as live, default 20; 0 skips the wait).
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
CONFIRM_SECS="${REOPEN_CONFIRM_SECS:-20}"
NOW="${REOPEN_NOW:-$(date +%s)}"
# Boot ids a few minutes apart are treated as one boot: kern.boottime can be
# nudged when the wall clock is stepped, and a new boot never follows the
# last one by that little.
BOOT_TOLERANCE_SECS=300

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
RUNS_JQ='{runs: map(select(.event == "start") | {boot: ((.boot // "") | tostring)})}'
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
add_result() { # status id name cwd last_human idle_wd detail [confirmed]
	results+=("$(jq -cn --arg status "$1" --arg id "$2" --arg name "$3" --arg cwd "$4" \
		--arg lh "$5" --arg wd "$6" --arg detail "$7" --arg confirmed "${8:-}" '
		{status: $status, id: $id, name: $name, cwd: $cwd,
		 last_human_message: ($lh | tonumber? // null),
		 idle_working_days: ($wd | tonumber? // null),
		 detail: $detail}
		+ (if $confirmed == "" then {} else {confirmed_live: ($confirmed == "true")} end)')")
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
	if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "recorded cwd does not exist"
		continue
	fi
	if [ -z "$tp" ] || [ ! -f "$tp" ]; then
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "transcript is gone"
		continue
	fi
	case "$tp" in
		"$CONFIG_DIR"/projects/*) ;;
		*)
			add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "transcript is under another Claude config dir than $CONFIG_DIR; run with that CLAUDE_CONFIG_DIR"
			continue
			;;
	esac
	to_open+=("$(jq -cn --arg id "$id" --arg name "$name" --arg cwd "$cwd" --arg lh "$lh" --arg wd "$wd" --arg how "$how" '{id: $id, name: $name, cwd: $cwd, lh: $lh, wd: $wd, how: $how}')")
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
open_tab() { # id cwd -> sets open_detail; returns 0 when the opener reported success
	local id="$1" cwd="$2" out rc printed
	if ! is_uuid "$id"; then
		open_detail="not a session id"
		return 1
	fi
	out="$(mktemp "${TMPDIR:-/tmp}/reopen-sessions.XXXXXX")"
	run_with_timeout "$TAB_TIMEOUT" "$out" \
		"$OPENER" "CLAUDE_CONFIG_DIR=$(shq "$CONFIG_DIR") claude --resume $(shq "$id")" "$id" "$cwd" background \
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

confirm_live() { # id -> true once the reader reports it live, within CONFIRM_SECS
	local id="$1" waited=0
	[ "$CONFIRM_SECS" -gt 0 ] 2> /dev/null || return 2
	while [ "$waited" -lt "$CONFIRM_SECS" ]; do
		sleep 1
		waited=$((waited + 1))
		[ "$(reader_entry "$id" | jq -r '.live // false' 2> /dev/null)" = "true" ] && return 0
	done
	return 1
}

for item in "${to_open[@]+"${to_open[@]}"}"; do
	id="$(jq -r '.id' <<< "$item")"
	name="$(jq -r '.name' <<< "$item")"
	cwd="$(jq -r '.cwd' <<< "$item")"
	lh="$(jq -r '.lh' <<< "$item")"
	wd="$(jq -r '.wd' <<< "$item")"
	how="$(jq -r '.how' <<< "$item")"
	if [ "$dry_run" = true ]; then
		add_result would-open "$id" "$name" "$cwd" "$lh" "$wd" "would resume in a background tab; $how"
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
	if open_tab "$id" "$cwd"; then
		confirm_live "$id"
		case $? in
			0) add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "resumed in a background tab; $how" true ;;
			1) add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "tab opened; not live yet after ${CONFIRM_SECS}s; $how" false ;;
			*) add_result opened "$id" "$name" "$cwd" "$lh" "$wd" "tab opened; $how" ;;
		esac
	else
		add_result failed "$id" "$name" "$cwd" "$lh" "$wd" "$open_detail"
	fi
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
		"summary\tdry_run=\(.dry_run) opened=\(.opened) would_open=\(.would_open) running=\(.running) idle=\(.idle) failed=\(.failed) older_orphans=\(.older_orphans) ended_deliberately=\(.ended_deliberately) idle_after_working_days=\(.idle_after_working_days)(\(.idle_threshold_from)) went_down_after=\($down) booted=\($boot)"
	' <<< "$summary_json"
fi

if [ "$(jq '.failed' <<< "$summary_json")" -gt 0 ]; then
	exit 1
fi
exit 0
