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
# The tab-typing path is macOS's; the marker path has its own section below.
export RESTART_SESSION_MODE=tab
unset CLAUDE_CODE_SESSION_ID DESK_HEADLESS
ln -sf "$(command -v bash)" "$TMP/bin/claude"
export TMP PROJ_DIR RECORDER

# The session's exact argv: whatever the test last wrote, a NUL after each
# word, whatever the pid.
export RESTART_SESSION_ARGV="$TMP/bin/argv"
printf '#!/usr/bin/env bash\ncat "%s/argv"\n' "$TMP" > "$TMP/bin/argv"
chmod +x "$TMP/bin/argv"

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
# pid was still alive) unless $TMP/find-fails exists, and with
# $TMP/busy-on-find marks the session busy, as a prompt arriving meanwhile
# would; `pid` prints the pid in
# $TMP/fg, first putting $TMP/procs.after in place as the process table
# once the session has stopped, when there is one, and fails while the count
# in $TMP/pid-fails is above 0; `type` keeps the text in $TMP/typed and fails
# if $TMP/type-fails exists, with $TMP/resume-on-type naming a session starts
# a stand-in for it, as the typed resume would, and with $TMP/type-times-out
# then exits 124, as a timed-out hs call does after it may have typed.
cat > "$DESK_CLOSE_TAB_BIN" << 'FAKE'
#!/usr/bin/env bash
case "$1" in
	find)
		alive=dead; kill -0 "$3" 2> /dev/null && alive=alive
		echo "find $2 $3 $alive" >> "$TMP/tab.log"
		[ -e "$TMP/find-fails" ] && { echo "DeskTabTerminal: no Ghostty terminal is on $2" >&2; exit 1; }
		if [ -e "$TMP/busy-on-find" ]; then
			jq '.status = "busy"' "$CLAUDE_CONFIG_DIR/sessions/$3.json" > "$TMP/pf.find" \
				&& mv "$TMP/pf.find" "$CLAUDE_CONFIG_DIR/sessions/$3.json"
		fi
		echo "T-$3" ;;
	pid)
		echo "pid $2" >> "$TMP/tab.log"
		left=$(cat "$TMP/pid-fails" 2> /dev/null || echo 0)
		if [ "$left" -gt 0 ]; then
			echo $((left - 1)) > "$TMP/pid-fails"
			echo "DeskTerminalPid: osascript failed: busy" >&2
			exit 1
		fi
		[ -e "$TMP/procs.after" ] && mv "$TMP/procs.after" "$TMP/procs"
		cat "$TMP/fg" ;;
	type)
		echo "type $2 $3" >> "$TMP/tab.log"
		printf '%s' "$4" > "$TMP/typed"
		[ -e "$TMP/type-fails" ] && { echo "DeskTypeInTerminal: not typed: its foreground process changed" >&2; exit 1; }
		if [ -s "$TMP/resume-on-type" ]; then
			source "$TMP/spawn.sh"
			spawn "$(cat "$TMP/resume-on-type")" > /dev/null
		fi
		[ -e "$TMP/type-times-out" ] && exit 124 ;;
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
	rm -f "$TMP/typed" "$TMP/find-fails" "$TMP/busy-on-find" "$TMP/type-fails" "$TMP/type-times-out" \
		"$TMP/resume-on-type" "$TMP/procs.after" "$TMP/pid-fails"
	echo 9000 > "$TMP/fg"
	printf '%s\0' claude --resume x > "$TMP/argv"
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
desk_tab "$p1" "4000 $p1 node /opt/mcp/server.js" "4001 1 unrelated"
run_restart "$s1"
assert_eq "it reports restarted" "restarted	resume typed into its tab" "$(status)	$(detail)"
assert_eq "...exit 0" "0" "$rc"
assert_eq "an MCP server child did not count as running" "restarted" "$(status)"
assert_eq "the process is gone" "gone" "$(alive "$p1")"
assert_eq "...and so is its pid file" "false" "$([ -e "$CONFIG_DIR/sessions/$p1.json" ] && echo true || echo false)"
assert_eq "the tab was named while the process was alive, then typed into at once at the login shell that had waited under it" \
	"find $tty1 $p1 alive|pid T-$p1|type T-$p1 9000" "$(paste -sd'|' "$TMP/tab.log")"
case "$(cat "$TMP/restart.err")" in *"restart-session: took check="*" stop="*" settle="*" type="*) ok "...saying how long each phase took" ;; *) bad "...saying how long each phase took (got [$(cat "$TMP/restart.err")])" ;; esac
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
	settle=$(sed -n 's/.* settle=\([0-9]*\)\.\([0-9]\)s.*/\1\2/p' "$TMP/restart.err")
	if [ "${settle:-0}" -ge 10 ]; then ok "...typed only once the new shell held still for a second (settle took ${settle}00 ms)"
	else bad "...typed only once the new shell held still for a second (settle took ${settle:-?}00 ms)"; fi
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

echo "=== a subagent still running, however long since it wrote ==="
fresh
s16=$(uuid)
p16=$(spawn "$s16")
desk_tab "$p16"
an_hour_ago_ms=$((($(date +%s) - 3600) * 1000))
jq --argjson t "$an_hour_ago_ms" '.startedAt = $t' "$CONFIG_DIR/sessions/$p16.json" > "$TMP/pf" && mv "$TMP/pf" "$CONFIG_DIR/sessions/$p16.json"
sub16="$PROJ_DIR/$s16/subagents"
mkdir -p "$sub16"
ten_min_ago=$(date -r $(($(date +%s) - 600)) +%Y%m%d%H%M 2> /dev/null || date -d @$(($(date +%s) - 600)) +%Y%m%d%H%M)
two_hours_ago=$(date -r $(($(date +%s) - 7200)) +%Y%m%d%H%M 2> /dev/null || date -d @$(($(date +%s) - 7200)) +%Y%m%d%H%M)
echo '{"agentType":"general-purpose","finished":true}' > "$sub16/agent-done.meta.json"
echo '{"agentType":"general-purpose","finished":null}' > "$sub16/agent-left.meta.json"
touch -t "$ten_min_ago" "$sub16/agent-done.meta.json"
touch -t "$two_hours_ago" "$sub16/agent-left.meta.json"
echo '{"agentType":"general-purpose"}' > "$sub16/agent-slow.meta.json"
touch -t "$ten_min_ago" "$sub16/agent-slow.meta.json"
run_restart "$s16"
assert_eq "one it started, not finished, quiet for ten minutes: refused" \
	"refused	not idle: a subagent it started has not finished (agent-slow)" "$(status)	$(detail)"
rm "$sub16/agent-slow.meta.json"
s16b=$(uuid)
p16b=$(spawn "$s16b")
desk_tab "$p16b"
five_hours_ago_ms=$((($(date +%s) - 18000) * 1000))
jq --argjson t "$five_hours_ago_ms" '.startedAt = $t' "$CONFIG_DIR/sessions/$p16b.json" > "$TMP/pf" && mv "$TMP/pf" "$CONFIG_DIR/sessions/$p16b.json"
mkdir -p "$PROJ_DIR/$s16b/subagents"
three_hours_ago=$(date -r $(($(date +%s) - 10800)) +%Y%m%d%H%M 2> /dev/null || date -d @$(($(date +%s) - 10800)) +%Y%m%d%H%M)
echo '{"agentType":"general-purpose","finished":null}' > "$PROJ_DIR/$s16b/subagents/agent-stopped.meta.json"
: > "$PROJ_DIR/$s16b/subagents/agent-stopped.jsonl"
touch -t "$three_hours_ago" "$PROJ_DIR/$s16b/subagents/agent-stopped.meta.json" "$PROJ_DIR/$s16b/subagents/agent-stopped.jsonl"
run_restart "$s16b"
assert_eq "one it started but stopped hours ago, left unfinished, does not hold it up" "restarted" "$(status)"
fresh
desk_tab "$p16"
run_restart "$s16"
assert_eq "finished ones, and one an earlier process left unfinished, do not hold it up" "restarted" "$(status)"

echo "=== something scheduled in the process ==="
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2> /dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
schedule_case() { # description expected-status transcript-line...
	local desc=$1 want=$2 s p
	shift 2
	fresh
	s=$(uuid)
	p=$(spawn "$s")
	desk_tab "$p"
	jq --argjson t "$an_hour_ago_ms" '.startedAt = $t' "$CONFIG_DIR/sessions/$p.json" > "$TMP/pf" && mv "$TMP/pf" "$CONFIG_DIR/sessions/$p.json"
	printf '%s\n' "$@" > "$PROJ_DIR/$s.jsonl"
	run_restart "$s"
	assert_eq "$desc" "$want" "$(status)"
}
now_s=$(date +%s)
recent=$(iso $((now_s - 60)))
before=$(iso $((now_s - 7200)))
schedule_case "a wakeup still to fire: refused" refused \
	"{\"type\":\"user\",\"timestamp\":\"$recent\",\"toolUseResult\":{\"scheduledFor\":$(((now_s + 600) * 1000))}}"
case "$(detail)" in "it has a wakeup due at "*", which a restart would lose") ok "...saying so" ;; *) bad "...saying so (got [$(detail)])" ;; esac
schedule_case "a wakeup that has fired: restarted" restarted \
	"{\"type\":\"user\",\"timestamp\":\"$recent\",\"toolUseResult\":{\"scheduledFor\":$(((now_s - 30) * 1000))}}"
schedule_case "a recurring session cron: refused" refused \
	"{\"type\":\"user\",\"timestamp\":\"$recent\",\"toolUseResult\":{\"id\":\"c1\",\"humanSchedule\":\"*/5 * * * *\",\"recurring\":true,\"durable\":false,\"nextFireAt\":$(((now_s - 30) * 1000))}}"
schedule_case "...one deleted since: restarted" restarted \
	"{\"type\":\"user\",\"timestamp\":\"$recent\",\"toolUseResult\":{\"id\":\"c1\",\"recurring\":true,\"durable\":false,\"nextFireAt\":$(((now_s - 30) * 1000))}}" \
	"{\"type\":\"assistant\",\"timestamp\":\"$recent\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"CronDelete\",\"input\":{\"id\":\"c1\"}}]}}"
schedule_case "...a durable one, which outlives the process: restarted" restarted \
	"{\"type\":\"user\",\"timestamp\":\"$recent\",\"toolUseResult\":{\"id\":\"c2\",\"recurring\":true,\"durable\":true,\"nextFireAt\":$(((now_s + 60) * 1000))}}"
schedule_case "...one made by an earlier process, gone with it: restarted" restarted \
	"{\"type\":\"user\",\"timestamp\":\"$before\",\"toolUseResult\":{\"id\":\"c3\",\"recurring\":true,\"durable\":false,\"nextFireAt\":$(((now_s + 60) * 1000))}}"

echo "=== the flags it was started with ==="
# The stand-in's exact argv, as the argv stub reports it: one word each.
flags_case() { # argv words... -> sets s, out, rc
	fresh
	s=$(uuid)
	p=$(spawn "$s")
	desk_tab "$p"
	printf '%s\0' "$@" > "$TMP/argv"
	run_restart "$s"
}
mkdir -p "$PROJ_DIR/extra" "$TMP/my dir"
flags_case claude --settings /x/account.json --model opus --permission-mode plan --add-dir extra "$TMP/my dir" \
	-n "my session" --verbose --resume x "fix the bug --model haiku" --effort=high
assert_eq "carried flags: restarted" "restarted" "$(status)"
typed="$(cat "$TMP/typed")"
eval "set -- ${typed# exec /bin/zsh -lic }"
assert_eq "...the resume carries them, a spaced directory whole, without the function's settings, the name, the old resume or the prompt" \
	"cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --model 'opus' --permission-mode 'plan' --add-dir 'extra' '$TMP/my dir' --verbose --effort 'high' --resume $s; exec /bin/zsh -il" "$1"
flags_case claude --settings /tmp -n ticket-2 "Fix the bug" --permission-mode bypassPermissions
assert_eq "a named session's prompt is skipped, and a bypass after it is still seen: refused" \
	"refused	it was started with --permission-mode bypassPermissions, which bypasses permissions and a restart never passes on; restart it by hand" \
	"$(status)	$(detail)"
flags_case claude --settings /tmp -n ticket-2 Fix the bug --model sonnet
typed="$(cat "$TMP/typed" 2> /dev/null)"
eval "set -- ${typed# exec /bin/zsh -lic }"
typed="$1"
case "$typed" in *"claude --model 'sonnet' --resume $s;"*) ok "...a prompt typed as several words is skipped too, the flag after it carried" ;; *) bad "...a prompt typed as several words is skipped too (got [$typed])" ;; esac
flags_case claude --resume "a long session name" --model opus --verbose
typed="$(cat "$TMP/typed" 2> /dev/null)"
eval "set -- ${typed# exec /bin/zsh -lic }"
typed="$1"
case "$typed" in *"claude --model 'opus' --verbose --resume $s;"*) ok "a multi-word --resume name with flags after it: the flags carried" ;; *) bad "a multi-word --resume name with flags after it (got [$typed])" ;; esac
flags_case claude --dangerously-skip-permissions --resume x
assert_eq "--dangerously-skip-permissions: refused" \
	"refused	it was started with --dangerously-skip-permissions, which bypasses permissions and a restart never passes on; restart it by hand" \
	"$(status)	$(detail)"
flags_case claude --permission-mode=bypassPermissions --resume x
assert_eq "...in its = form too" "refused" "$(status)"
flags_case claude --add-dir=extra src --resume x
typed="$(cat "$TMP/typed" 2> /dev/null)"
eval "set -- ${typed# exec /bin/zsh -lic }"
typed="$1"
case "$typed" in *"claude --add-dir 'extra' --resume $s;"*) ok "--add-dir= takes its one value, the prompt after it left out" ;; *) bad "--add-dir= takes its one value (got [$typed])" ;; esac
flags_case claude --resume x --settings /x/extra.json
assert_eq "a --settings passed by hand, which could set a permission mode: refused" \
	"refused	it was started with --settings by hand, which a resume would read again as it is now and which can set permissions; restart it by hand" \
	"$(status)	$(detail)"
flags_case claude --agent reviewer --resume x
assert_eq "...an --agent too" "refused" "$(status)"
flags_case claude --resume x --mcp-config extra.json
assert_eq "an option a resume would drop: refused, saying which" \
	"refused	it was started with --mcp-config, which a resume would drop; restart it by hand" "$(status)	$(detail)"
flags_case claude --add-dir "$TMP/gone" --resume x
assert_eq "an --add-dir that is gone: refused" \
	"refused	its --add-dir $TMP/gone is not a directory a restart can find" "$(status)	$(detail)"
fresh
s=$(uuid)
p=$(spawn "$s")
desk_tab "$p"
: > "$TMP/argv"
run_restart "$s"
assert_eq "an argv that cannot be read: refused" \
	"refused	its argv could not be read, so the flags it was started with are unknown" "$(status)	$(detail)"
bash -c 'sleep 30; :' "a b" --model x &
reader=$!
sleep 0.3
assert_eq "the real argv reader keeps a spaced word whole" "bash|-c|sleep 30; :|a b|--model|x|" \
	"$(unset RESTART_SESSION_ARGV; source "$HERE/../desk-lib/restartable.sh"; restartable_argv "$reader" | tr '\0' '|')"
kill "$reader" 2> /dev/null

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

echo "=== something that starts during the tab lookup stops the restart ==="
fresh
s9=$(uuid)
p9=$(spawn "$s9")
desk_tab "$p9"
: > "$TMP/busy-on-find"
run_restart "$s9"
assert_eq "refused, saying it changed since the first look" \
	"refused	not idle: its status is busy (since the first look)" "$(status)	$(detail)"
assert_eq "...still running" "alive" "$(alive "$p9")"
rm -f "$TMP/busy-on-find"

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
	"the session stopped, but its tab showed no settled prompt within 2s (/bin/zsh -lic claude --resume x); resume it by hand: cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s5" "$(detail)"
assert_eq "...having typed nothing" "false" "$([ -e "$TMP/typed" ] && echo true || echo false)"

fresh
s6=$(uuid)
p6=$(spawn "$s6")
desk_tab "$p6"
: > "$TMP/type-fails"
run_restart "$s6"
assert_eq "the helper refusing to type: failed, with the reason" \
	"failed	the session stopped, but the resume was not typed: DeskTypeInTerminal: not typed: its foreground process changed; resume it by hand: cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s6" \
	"$(status)	$(detail)"

echo "=== a tab that is slow to answer ==="
fresh
s10=$(uuid)
p10=$(spawn "$s10")
desk_tab "$p10"
echo 1 > "$TMP/pid-fails"
RESTART_SESSION_PROMPT_SECS=3 run_restart "$s10"
assert_eq "a pid call that fails once is tried again: restarted" "restarted" "$(status)"
assert_eq "...typed once it answered" "type T-$p10 9000" "$(grep '^type' "$TMP/tab.log")"

fresh
s11=$(uuid)
p11=$(spawn "$s11")
desk_tab "$p11"
echo 9 > "$TMP/pid-fails"
run_restart "$s11"
assert_eq "one that never answers: failed, nothing typed, a manual resume advised" \
	"failed	the session stopped, but its tab is out of reach (DeskTerminalPid: osascript failed: busy); resume it by hand: cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s11" \
	"$(status)	$(detail)"
assert_eq "...having typed nothing" "false" "$([ -e "$TMP/typed" ] && echo true || echo false)"

echo "=== a type that times out may have typed ==="
fresh
s12=$(uuid)
p12=$(spawn "$s12")
desk_tab "$p12"
: > "$TMP/type-times-out"
run_restart "$s12"
assert_eq "with no confirm wait: failed, with no manual resume advised" \
	"failed	the session stopped and the tab helper timed out while typing, so the resume may have been typed; look at the tab before resuming it by hand" \
	"$(status)	$(detail)"

fresh
s13=$(uuid)
p13=$(spawn "$s13")
desk_tab "$p13"
: > "$TMP/type-times-out"
echo "$s13" > "$TMP/resume-on-type"
RESTART_SESSION_CONFIRM_SECS=10 run_restart "$s13"
assert_eq "it had typed, and the session came back: restarted" "restarted" "$(status)"

fresh
s14=$(uuid)
p14=$(spawn "$s14")
desk_tab "$p14"
: > "$TMP/type-times-out"
RESTART_SESSION_CONFIRM_SECS=2 run_restart "$s14"
assert_eq "it had not, and the session stayed down: a manual resume, only now and with a look first" \
	"failed	the session stopped and the tab helper timed out while typing; it is not live after 2s, so if its tab shows nothing running, resume it by hand: cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s14" \
	"$(status)	$(detail)"

echo "=== a directory with a quote in its name ==="
fresh
plain_proj="$PROJ_DIR"
PROJ_DIR="$TMP/it's here"
mkdir -p "$PROJ_DIR"
s15=$(uuid)
p15=$(spawn "$s15")
desk_tab "$p15"
run_restart "$s15"
PROJ_DIR="$plain_proj"
assert_eq "restarted" "restarted" "$(status)"
typed="$(cat "$TMP/typed")"
eval "set -- ${typed# exec /bin/zsh -lic }"
inner="${1%; exec /bin/zsh -il}"
assert_eq "the typed resume changes into that directory, intact" "$TMP/it's here" \
	"$(cd / && bash -c "claude() { pwd; }; $inner")"

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

echo "=== marker mode (Linux): the resume is left for the session's shell, nothing typed ==="
export RESTART_SESSION_MODE=marker
export CLAUDE_RESTART_DIR="$TMP/markers"
# A claude the `claude` function started: its parent shell's pid (9001, the
# parent in table's process table) is in its environment.
spawn_wrapped() { __CLAUDE_FN_SHELL="${2:-9001}" spawn "$1"; }

fresh
s20=$(uuid)
p20=$(spawn_wrapped "$s20")
desk_tab "$p20"
run_restart "$s20"
assert_eq "restarted, the resume left for its shell" "restarted	resume left for its shell" "$(status)	$(detail)"
assert_eq "the process is gone" "gone" "$(alive "$p20")"
assert_eq "the tab helper was never asked anything" "" "$(cat "$TMP/tab.log")"
assert_eq "the marker is keyed by the shell's pid and holds claude's pid, the session and the resume" \
	"$p20|$s20|cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s20" "$(paste -sd'|' "$TMP/markers/9001")"
assert_eq "...in a directory it created for its owner alone" "700" "$(stat -c %a "$TMP/markers" 2> /dev/null || stat -f %Lp "$TMP/markers")"
rm -f "$TMP/markers/9001"

fresh
s21=$(uuid)
p21=$(spawn_wrapped "$s21")
printf '%s\0' claude --model opus --resume x > "$TMP/argv"
desk_tab "$p21"
run_restart "$s21"
assert_eq "the allowlisted flags of its argv are carried, by the same builder a tab uses" \
	"cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --model 'opus' --resume $s21" "$(sed -n 3p "$TMP/markers/9001")"
rm -f "$TMP/markers/9001"

echo "=== marker mode: a session its shell cannot resume is refused, untouched ==="
fresh
s22=$(uuid)
p22=$(spawn "$s22")
desk_tab "$p22"
run_restart "$s22"
assert_eq "started without the function (no shell pid in its environment): refused" "refused" "$(status)"
case "$(detail)" in *"not started through the \`claude\` shell function"*"exit it and resume it once by hand"*) ok "...saying to exit and resume once by hand" ;; *) bad "...saying to exit and resume once by hand (got [$(detail)])" ;; esac
assert_eq "...exit 3" "3" "$rc"
assert_eq "...still running, no marker left" "alive|" "$(alive "$p22")|$(ls "$TMP/markers")"
kill -KILL "$p22" 2> /dev/null
s23=$(uuid)
p23=$(spawn_wrapped "$s23" 4242)
desk_tab "$p23"
run_restart "$s23"
assert_eq "started by a function in some other shell than its parent: refused" "refused	3" "$(status)	$rc"

echo "=== marker mode: the resume is confirmed, or the missing pickup is said ==="
fresh
s24=$(uuid)
p24=$(spawn_wrapped "$s24")
desk_tab "$p24"
(
	for _ in $(seq 1 100); do [ -f "$TMP/markers/9001" ] && break; sleep 0.05; done
	sleep 0.3
	rm -f "$TMP/markers/9001"
	source "$TMP/spawn.sh"
	spawn "$s24" > /dev/null
) &
RESTART_SESSION_CONFIRM_SECS=10 run_restart "$s24"
new24=$(field "$s24" .pid)
assert_eq "a shell that picks the marker up and resumes: restarted, naming the new pid" \
	"restarted	resumed in its shell (pid $new24)" "$(status)	$(detail)"
fresh
s25=$(uuid)
p25=$(spawn_wrapped "$s25")
desk_tab "$p25"
RESTART_SESSION_CONFIRM_SECS=2 run_restart "$s25"
assert_eq "nothing picks it up: failed, with the resume by hand" \
	"failed	the session stopped, but its shell did not pick up the resume within 2s (is it still there?); resume it by hand: cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $s25" "$(status)	$(detail)"
assert_eq "...and the marker is removed, so a later claude in that shell is not resumed" "" "$(ls "$TMP/markers")"

fresh
s26=$(uuid)
p26=$(spawn_wrapped "$s26")
desk_tab "$p26"
# stubborn: ignores SIGTERM
kill -KILL "$p26" 2> /dev/null
s26=$(uuid)
p26=$(__CLAUDE_FN_SHELL=9001 spawn "$s26" stubborn)
desk_tab "$p26"
RESTART_SESSION_GRACE_SECS=1 run_restart "$s26"
assert_eq "a session that will not stop: failed, and no marker left behind" "failed|" "$(status)|$(ls "$TMP/markers")"
kill -KILL "$p26" 2> /dev/null
unset CLAUDE_RESTART_DIR
export RESTART_SESSION_MODE=tab

echo "=== recorder never logged an error ==="
if [ -s "$TMP/recorder.log" ]; then bad "recorder log is empty"; cat "$TMP/recorder.log"; else ok "recorder log is empty"; fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
