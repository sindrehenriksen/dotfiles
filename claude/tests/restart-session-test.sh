#!/usr/bin/env bash
# claude/restart-session.sh: restarting a live session in its own tab.
# Sessions are stand-in processes named `claude` (bash under that name) that
# run the recorder hooks as their own children, write a pid file and remove
# it on SIGTERM, each on a terminal of its own from `script`, so the real
# reader sees them live with a tty. Two boundaries are fakes: the tab
# helper, which logs its calls and reports a foreground pid the test sets,
# and the process table, which the test writes, so a tab's shells and the
# session's children can take any shape without real shells behind them.
# Nothing reaches Hammerspoon or Ghostty, and no real session is touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"
RESTART="$HERE/../restart-session.sh"
RECORDER="$HERE/../hooks/session-recorder.sh"
READER="$HERE/../session-status.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

TMP="$(mktemp -d)"
cleanup() {
	local p
	for p in $(cat "$TMP/spawned" 2> /dev/null); do
		pkill -KILL -P "$p" 2> /dev/null
		kill -KILL "$p" 2> /dev/null
	done
	rm -rf "$TMP"
}
trap cleanup EXIT

CONFIG_DIR="$TMP/config"
PROJ_DIR="$TMP/the project"
mkdir -p "$CONFIG_DIR/sessions" "$CONFIG_DIR/projects" "$PROJ_DIR" "$TMP/store" "$TMP/cache" "$TMP/ctl" "$TMP/bin"
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$TMP/store"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
export DESK_READER="$READER"
export DESK_CLOSE_TAB_BIN="$TMP/bin/desk-close-tab.sh"
export RESTART_SESSION_PS="$TMP/bin/ps"
export RESTART_SESSION_GRACE_SECS=3
export RESTART_SESSION_PROMPT_SECS=2
export RESTART_SESSION_CONFIRM_SECS=0
unset CLAUDE_CODE_SESSION_ID DESK_HEADLESS
ln -sf "$(command -v bash)" "$TMP/bin/claude"
export TMP PROJ_DIR RECORDER

# The process table: whatever the test last wrote.
printf '#!/usr/bin/env bash\ncat "%s/procs"\n' "$TMP" > "$TMP/bin/ps"
chmod +x "$TMP/bin/ps"

# Starts a stand-in session $1 on a terminal of its own and prints its pid.
# It runs the SessionStart hook, then waits; on SIGTERM it runs the
# SessionEnd hook with reason "other", removes its pid file and exits, as
# Claude Code does. With $2 = stubborn it ignores SIGTERM instead. Shared
# with the fake tab helper, whose `type` can stand for the resume.
cat > "$TMP/spawn.sh" << 'SPAWN'
source "$PLATFORM"
wait_for() { # file, up to ~5s
	local i
	for i in $(seq 1 100); do
		[ -s "$1" ] && return 0
		sleep 0.05
	done
	return 1
}
spawn() { # sid [stubborn]
	local sid=$1 mode=${2:-} tag
	tag="$TMP/ctl/$1.$RANDOM"
	jq -cn --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg tp "$PROJ_DIR/$sid.jsonl" \
		'{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup", hook_event_name:"SessionStart"}' > "$tag.start.json"
	jq -cn --arg sid "$sid" '{session_id:$sid, reason:"other", hook_event_name:"SessionEnd"}' > "$tag.end.json"
	[ -e "$PROJ_DIR/$sid.jsonl" ] || : > "$PROJ_DIR/$sid.jsonl"
	on_a_terminal "$TMP/bin/claude" -c '
		if [ "$4" = stubborn ]; then trap "" TERM
		else trap "\"\$2\" end < \"\$1.end.json\"; rm -f \"\$3/sessions/\$\$.json\"; exit 0" TERM; fi
		"$2" start < "$1.start.json" > /dev/null
		echo $$ > "$1.pid"
		while :; do sleep 1 & wait $!; done' _ "$tag" "$RECORDER" "$CLAUDE_CONFIG_DIR" "$mode" < /dev/null > /dev/null 2>&1 &
	echo "$!" >> "$TMP/spawned"
	wait_for "$tag.pid" || { echo "stand-in for $sid never started" >&2; return 1; }
	local pid procstart now_ms
	pid=$(cat "$tag.pid")
	echo "$pid" >> "$TMP/spawned"
	procstart=$(proc_start_of "$pid")
	now_ms=$(($(date +%s) * 1000))
	jq -n --argjson pid "$pid" --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg procstart "$procstart" --argjson now "$now_ms" \
		'{pid:$pid, sessionId:$sid, cwd:$cwd, startedAt:$now, procStart:$procstart, nameSource:"none", status:"idle", updatedAt:$now}' \
		> "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	echo "$pid"
}
SPAWN
export PLATFORM="$HERE/lib/platform.sh"
# shellcheck source=/dev/null
source "$TMP/spawn.sh"

# The fake tab helper: `find` names terminal T-<pid> (logging whether that
# pid was still alive) unless $TMP/find-fails exists; `pid` prints the pid in
# $TMP/fg, first putting $TMP/procs.after in place as the process table
# once the session has stopped, when there is one; `type` keeps the text in $TMP/typed and fails if $TMP/type-fails
# exists, and with $TMP/resume-on-type naming a session starts a stand-in for
# it, as the typed resume would.
cat > "$DESK_CLOSE_TAB_BIN" << 'FAKE'
#!/usr/bin/env bash
case "$1" in
	find)
		alive=dead; kill -0 "$3" 2> /dev/null && alive=alive
		echo "find $2 $3 $alive" >> "$TMP/tab.log"
		[ -e "$TMP/find-fails" ] && { echo "DeskTabTerminal: no Ghostty terminal is on $2" >&2; exit 1; }
		echo "T-$3" ;;
	pid)
		echo "pid $2" >> "$TMP/tab.log"
		[ -e "$TMP/procs.after" ] && mv "$TMP/procs.after" "$TMP/procs"
		cat "$TMP/fg" ;;
	type)
		echo "type $2 $3" >> "$TMP/tab.log"
		printf '%s' "$4" > "$TMP/typed"
		[ -e "$TMP/type-fails" ] && { echo "DeskTypeInTerminal: not typed: its foreground process changed" >&2; exit 1; }
		if [ -s "$TMP/resume-on-type" ]; then
			source "$TMP/spawn.sh"
			spawn "$(cat "$TMP/resume-on-type")" > /dev/null
		fi ;;
esac
exit 0
FAKE
chmod +x "$DESK_CLOSE_TAB_BIN"

# The tab's shells, as the process table shows them. $1 is the stand-in's
# pid, $2 the args of its parent (pid 9001), $3 those of the parent's parent
# (pid 9000); further arguments are extra rows, written as they come.
LOGIN_ROW="/usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l /bin/zsh"
table() { # claude_pid parent_args grand_args [row...]
	local c=$1 p=$2 g=$3
	shift 3
	{
		printf '%s 1 /Applications/Ghostty.app/Contents/MacOS/ghostty\n' 8000
		printf '%s 8000 %s\n' 9000 "$g"
		printf '%s 9000 %s\n' 9001 "$p"
		printf '%s 9001 claude --resume x\n' "$c"
		for row in "$@"; do printf '%s\n' "$row"; done
	} > "$TMP/procs"
}
# A desk tab: the user's login shell, with the command typed into it.
desk_tab() { table "$1" "/bin/zsh -lic claude --resume x" "-/bin/zsh" "${@:2}"; }

field() { "$READER" | jq -r --arg id "$1" "select(.id == \$id) | $2"; }
uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
run_restart() { # id -> sets out, rc
	out="$("$RESTART" "$1" 2> "$TMP/restart.err")"
	rc=$?
}
detail() { cut -f4 <<< "$out"; }
status() { cut -f1 <<< "$out"; }
alive() { kill -0 "$1" 2> /dev/null && echo alive || echo gone; }
fresh() {
	: > "$TMP/tab.log"
	rm -f "$TMP/typed" "$TMP/find-fails" "$TMP/type-fails" "$TMP/resume-on-type" "$TMP/procs.after"
	echo 9000 > "$TMP/fg"
}

echo "=== refused before anything is touched ==="
run_restart "not-a-uuid"
assert_eq "a non-UUID id is refused" "refused	not a session id" "$(status)	$(detail)"
assert_eq "...exit 1" "1" "$rc"
run_restart "$(uuid)"
assert_eq "an unknown session is refused" "refused	no such session" "$(status)	$(detail)"
"$RESTART" > /dev/null 2>&1
assert_eq "no argument is a usage error" "2" "$?"

echo "=== an idle session in a desk tab: stopped, then resumed in the same tab ==="
fresh
s1=$(uuid)
p1=$(spawn "$s1")
tty1=$(field "$s1" .tty)
desk_tab "$p1" "$p1 4000 node /opt/mcp/server.js" "4000 1 unrelated"
run_restart "$s1"
assert_eq "it reports restarted" "restarted	resume typed into its tab" "$(status)	$(detail)"
assert_eq "...exit 0" "0" "$rc"
assert_eq "an MCP server child did not count as running" "restarted" "$(status)"
assert_eq "the process is gone" "gone" "$(alive "$p1")"
assert_eq "...and so is its pid file" "false" "$([ -e "$CONFIG_DIR/sessions/$p1.json" ] && echo true || echo false)"
assert_eq "the tab was named while the process was alive, then typed into at the shell it came back to" \
	"find $tty1 $p1 alive|pid T-$p1|type T-$p1 9000" "$(paste -sd'|' "$TMP/tab.log")"
typed="$(cat "$TMP/typed")"
assert_eq "a fresh login shell is exec'd, kept out of history by its leading space" " exec /bin/zsh -lic " "${typed:0:20}"
eval "set -- ${typed# exec /bin/zsh -lic }"
assert_eq "...running the resume in the session's directory through the claude function, then a prompt" \
	"cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s1; exec /bin/zsh -il" "$1"
assert_eq "nothing was recorded as a deliberate end" "other false" "$(field "$s1" '"\(.end_reason) \(.end_deliberate)"')"
assert_eq "...so reopen-sessions.sh still counts it left open" "true" "$(field "$s1" .left_open)"
assert_eq "...and no close event is in its log" "0" "$(jq -s 'map(select(.event != "start" and .event != "end")) | length' "$TMP/store/$s1.jsonl")"

echo "=== the tab's other shapes that leave a prompt ==="
for shape in hand restarted; do
	fresh
	s=$(uuid)
	p=$(spawn "$s")
	case $shape in
		hand) table "$p" "-/bin/zsh" "$LOGIN_ROW" ;;
		restarted) table "$p" "/bin/zsh -lic cd '/x' && CLAUDE_CONFIG_DIR='/c' claude --resume $s; exec /bin/zsh -il" "$LOGIN_ROW" ;;
	esac
	echo 9001 > "$TMP/fg"
	sed 's|^9001 9000 .*|9001 9000 /bin/zsh -il|' "$TMP/procs" > "$TMP/procs.after"
	run_restart "$s"
	assert_eq "claude started from the $shape shell: restarted" "restarted" "$(status)"
done

echo "=== a tab that would close with the session is refused ==="
fresh
s2=$(uuid)
p2=$(spawn "$s2")
table "$p2" "/bin/zsh -lic CLAUDE_CONFIG_DIR='/c' claude --resume x" "$LOGIN_ROW"
run_restart "$s2"
assert_eq "refused" "refused" "$(status)"
case "$(detail)" in "its tab would close with it: "*) ok "...saying why" ;; *) bad "...saying why (got [$(detail)])" ;; esac
assert_eq "...exit 3, which tells it from the other refusals" "3" "$rc"
assert_eq "...still running" "alive" "$(alive "$p2")"
assert_eq "...and its tab never asked about" "" "$(cat "$TMP/tab.log")"

echo "=== a session that is not idle is left running ==="
fresh
desk_tab "$p2" "4100 $p2 /bin/zsh -c source $CONFIG_DIR/shell-snapshots/snapshot-zsh-1.sh && eval 'make test'"
run_restart "$s2"
assert_eq "a shell command running: refused" "refused	not idle: it is running a shell command (pid 4100)" "$(status)	$(detail)"
desk_tab "$p2"
jq '.status = "busy"' "$CONFIG_DIR/sessions/$p2.json" > "$TMP/pf" && mv "$TMP/pf" "$CONFIG_DIR/sessions/$p2.json"
run_restart "$s2"
assert_eq "a busy status: refused" "refused	not idle: its status is busy" "$(status)	$(detail)"
jq '.status = "idle"' "$CONFIG_DIR/sessions/$p2.json" > "$TMP/pf" && mv "$TMP/pf" "$CONFIG_DIR/sessions/$p2.json"
mkdir -p "$PROJ_DIR/$s2/subagents"
: > "$PROJ_DIR/$s2/subagents/agent-a1.jsonl"
run_restart "$s2"
assert_eq "a subagent writing just now: refused" "refused	not idle: a subagent wrote in the last 5 min (agent-a1.jsonl)" "$(status)	$(detail)"
assert_eq "...still running after all of them" "alive" "$(alive "$p2")"
assert_eq "...with its tab never asked about" "" "$(cat "$TMP/tab.log")"
touch -t 202001010000 "$PROJ_DIR/$s2/subagents/agent-a1.jsonl"
run_restart "$s2"
assert_eq "a subagent quiet for longer does not hold it up" "restarted" "$(status)"

echo "=== refusals on a live session leave it running ==="
fresh
s3=$(uuid)
p3=$(spawn "$s3")
desk_tab "$p3"
CLAUDE_CODE_SESSION_ID="$s3" run_restart "$s3"
assert_eq "the session running the command is refused" "refused	this is the session running the command" "$(status)	$(detail)"
cp "$CONFIG_DIR/sessions/$p3.json" "$CONFIG_DIR/sessions/99999999.json"
run_restart "$s3"
rm -f "$CONFIG_DIR/sessions/99999999.json"
assert_eq "a session two pid files name is refused" "refused	more than one process holds this session" "$(status)	$(detail)"
: > "$TMP/find-fails"
run_restart "$s3"
assert_eq "a tab that cannot be told apart is refused" \
	"refused	could not tell its tab apart: DeskTabTerminal: no Ghostty terminal is on $(field "$s3" .tty)" "$(status)	$(detail)"
assert_eq "...still running after all of them" "alive" "$(alive "$p3")"
assert_eq "...and nothing typed" "false" "$([ -e "$TMP/typed" ] && echo true || echo false)"

echo "=== a session that will not stop ==="
fresh
s4=$(uuid)
p4=$(spawn "$s4" stubborn)
desk_tab "$p4"
run_restart "$s4"
assert_eq "failed, nothing more done" "failed	pid $p4 survived SIGTERM for 3s; nothing more done" "$(status)	$(detail)"
assert_eq "...exit 1" "1" "$rc"
assert_eq "...the tab was named but never typed into" "find" "$(cut -d' ' -f1 "$TMP/tab.log" | paste -sd'|' -)"
kill -KILL "$p4" 2> /dev/null

echo "=== stopped, but the tab gives nothing to type into ==="
fresh
s5=$(uuid)
p5=$(spawn "$s5")
desk_tab "$p5"
echo 9001 > "$TMP/fg"
run_restart "$s5"
assert_eq "no prompt in time: failed" "failed" "$(status)"
assert_eq "...saying what was in the foreground and how to resume by hand" \
	"the session stopped, but its tab showed no prompt within 2s (/bin/zsh -lic claude --resume x); resume it by hand: cd '$PROJ_DIR' && claude --resume $s5" "$(detail)"
assert_eq "...having typed nothing" "false" "$([ -e "$TMP/typed" ] && echo true || echo false)"

fresh
s6=$(uuid)
p6=$(spawn "$s6")
desk_tab "$p6"
: > "$TMP/type-fails"
run_restart "$s6"
assert_eq "the helper refusing to type: failed, with the reason" \
	"failed	the session stopped, but the resume was not typed: DeskTypeInTerminal: not typed: its foreground process changed; resume it by hand: cd '$PROJ_DIR' && claude --resume $s6" \
	"$(status)	$(detail)"

echo "=== the resumed session is confirmed live ==="
fresh
s7=$(uuid)
p7=$(spawn "$s7")
desk_tab "$p7"
echo "$s7" > "$TMP/resume-on-type"
RESTART_SESSION_CONFIRM_SECS=10 run_restart "$s7"
new7=$(field "$s7" .pid)
assert_eq "live again under a new pid: restarted, naming it" "restarted	resumed in its tab (pid $new7)" "$(status)	$(detail)"
assert_eq "...a pid other than the old one" "true" "$([ -n "$new7" ] && [ "$new7" != "$p7" ] && echo true || echo false)"

fresh
s8=$(uuid)
p8=$(spawn "$s8")
desk_tab "$p8"
RESTART_SESSION_CONFIRM_SECS=2 run_restart "$s8"
assert_eq "not live again in time: failed, pointing at the tab" \
	"failed	the resume was typed into its tab, but the session is not live after 2s; look at the tab" "$(status)	$(detail)"

echo "=== recorder never logged an error ==="
if [ -s "$TMP/recorder.log" ]; then bad "recorder log is empty"; cat "$TMP/recorder.log"; else ok "recorder log is empty"; fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
