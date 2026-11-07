#!/usr/bin/env bash
# claude/restart-self.sh: Linux's "restart the session this command runs in".
# The session is a stand-in process named `claude` (bash under that name) that
# runs the helper as its child, as a bash-mode command would, with a pid file
# written for it and the shell pid the `claude` function would have put in its
# environment. session-stale.sh, restart-session.sh and the detaching are
# fakes that log how they were called; the clock is $RESTART_SELF_NOW.
# Nothing touches a real session or a notification daemon.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/../restart-self.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

TMP="$(mktemp -d)"
cleanup() {
	pkill -KILL -f "$TMP/bin/claude" 2> /dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/config/sessions" "$TMP/bin" "$TMP/state"
ln -sf "$(command -v bash)" "$TMP/bin/claude"
export CLAUDE_CONFIG_DIR="$TMP/config"
export RESTART_SESSION_MODE=marker
export RESTART_SELF_STATE_DIR="$TMP/state/self"
export RESTART_SELF_LOG="$TMP/restart-self.log"
export RESTART_SELF_STALE_BIN="$TMP/bin/stale"
export RESTART_SELF_RESTART_BIN="$TMP/bin/restart"
export RESTART_SELF_NOTIFY="$TMP/bin/notify"
export RESTART_SELF_WINDOW_SECS=10
export RESTART_SELF_IDLE_SECS=2
unset CLAUDE_CODE_SESSION_ID RESTART_SESSION_PS
export TMP

# session-stale.sh: prints $TMP/stale.out, exits $TMP/stale.rc (default 0),
# says $TMP/stale.err, and logs whether it was asked from inside the session.
printf '#!/usr/bin/env bash\necho "stale $* inside=${RESTARTABLE_FROM_INSIDE:-no}" >> "$TMP/calls"\ncat "$TMP/stale.out" 2> /dev/null\ncat "$TMP/stale.err" >&2 2> /dev/null\nexit "$(cat "$TMP/stale.rc" 2> /dev/null || echo 0)"\n' > "$TMP/bin/stale"
# restart-session.sh: logs its call and whether it saw a session id of its own.
printf '#!/usr/bin/env bash\necho "restart $* session-id=${CLAUDE_CODE_SESSION_ID:-unset}" >> "$TMP/calls"\nprintf "restarted\\t%%s\\tn\\tok\\n" "$1"\n' > "$TMP/bin/restart"
printf '#!/usr/bin/env bash\necho "notify $*" >> "$TMP/calls"\n' > "$TMP/bin/notify"
chmod +x "$TMP/bin/stale" "$TMP/bin/restart" "$TMP/bin/notify"

SID="11111111-2222-3333-4444-555555555555"

# run_self [env...]: runs the helper as a child of a stand-in claude whose
# parent is this script (the shell pid its environment names), and sets out.
# $WRAPPED overrides that environment value; $NAME the pid file's name.
run_self() {
	local pid i
	rm -f "$TMP/go" "$TMP/pid" "$TMP/out" "$TMP/done"
	env __CLAUDE_FN_SHELL="${WRAPPED:-$$}" "$@" "$TMP/bin/claude" -c '
		echo $$ > "$TMP/pid"
		while [ ! -e "$TMP/go" ]; do sleep 0.05; done
		"$SELF" > "$TMP/out" 2>&1
		echo $? > "$TMP/done"' < /dev/null > /dev/null 2>&1 &
	for i in $(seq 1 100); do [ -s "$TMP/pid" ] && break; sleep 0.05; done
	pid=$(cat "$TMP/pid")
	if [ -z "${NO_PIDFILE:-}" ]; then
		jq -n --argjson pid "$pid" --arg sid "$SID" --arg name "${NAME-notes}" --arg status "${STATUS:-idle}" \
			'{pid:$pid, sessionId:$sid, name:$name, status:$status}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	fi
	touch "$TMP/go"
	for i in $(seq 1 200); do [ -s "$TMP/done" ] && break; sleep 0.05; done
	rc=$(cat "$TMP/done" 2> /dev/null)
	out=$(cat "$TMP/out" 2> /dev/null)
	CLAUDE_PID=$pid
	rm -f "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	kill -KILL "$pid" 2> /dev/null
}
export SELF
fresh() { : > "$TMP/calls"; rm -rf "$TMP/state/self" "$TMP/stale.out" "$TMP/stale.err" "$TMP/stale.rc" "$TMP/restart-self.log"; unset WRAPPED NAME NO_PIDFILE STATUS; }
calls() { paste -sd'|' "$TMP/calls"; }

echo "=== finding the session ==="
fresh
printf 'version: 1 running, 2 installed\n' > "$TMP/stale.out"
RESTART_SELF_NOW=1000 run_self
assert_eq "found through the process tree to claude and its pid file: asks session-stale.sh about that session, from inside" \
	"stale $SID inside=1" "$(calls)"
assert_eq "first press exits 0" "0" "$rc"
"$SELF" > "$TMP/out2" 2>&1 < /dev/null
assert_eq "run from outside any session: says so, exit 1" "1:1" "$?:$(grep -c 'not run from inside a Claude Code session' "$TMP/out2")"
fresh
NO_PIDFILE=1 RESTART_SELF_NOW=1000 run_self
assert_eq "a claude with no pid file: no session, exit 1, nothing asked" "1|" "$rc|$(calls)"

echo "=== first press ==="
fresh
printf 'version: 1 running, 2 installed\nshell: ~/.shellrc changed since it started\n' > "$TMP/stale.out"
RESTART_SELF_NOW=1000 run_self
assert_eq "prints what a restart would do, that unsent text is lost, and how to confirm" \
	"Restart notes? version: 1 running, 2 installed; shell: ~/.shellrc changed since it started.
Unsent text in its input box is lost. Press Super+Alt+R again within 10s to restart." "$out"
assert_eq "...records the press, restarts nothing" "1000 $SID|stale $SID inside=1" "$(cat "$TMP/state/self/$CLAUDE_PID")|$(calls)"
fresh
RESTART_SELF_NOW=1000 run_self
assert_eq "nothing stale is said, and it still waits for the confirming press" \
	"Restart notes? nothing in it is stale." "$(head -n 1 <<< "$out")"
fresh
printf 'not idle: a subagent wrote in the last 5 min (agent-a.jsonl)\n' > "$TMP/stale.err"
echo 1 > "$TMP/stale.rc"
: > "$TMP/stale.out"
RESTART_SELF_NOW=1000 run_self
assert_eq "a restart that would be refused says why" \
	"A restart of notes would be refused now: not idle: a subagent wrote in the last 5 min (agent-a.jsonl)." "$out"
assert_eq "...and records nothing, so a second press cannot restart" "0" "$(ls "$TMP/state/self" 2> /dev/null | wc -l | tr -d ' ')"
fresh
echo 3 > "$TMP/stale.rc"
RESTART_SELF_NOW=1000 run_self
assert_eq "a tab that would close with it: said, nothing recorded" \
	"Can't restart notes in this tab: its tab would close with it (claude --resume $SID).|0" \
	"$out|$(ls "$TMP/state/self" 2> /dev/null | wc -l | tr -d ' ')"
fresh
NAME="" RESTART_SELF_NOW=1000 run_self
assert_eq "a session with no name is called by its id" "Restart $SID?" "$(head -n 1 <<< "$out" | cut -c1-45)"

echo "=== a session its shell cannot resume ==="
fresh
WRAPPED=4242 RESTART_SELF_NOW=1000 run_self
case "$out" in
	"Can't restart notes here: it was not started through the \`claude\` shell function"*"exit it and resume it once by hand"*"(claude --resume $SID).") ok "refused, to exit and resume once by hand" ;;
	*) bad "refused, to exit and resume once by hand (got [$out])" ;;
esac
assert_eq "...exit 0, nothing recorded or asked" "0||" "$rc|$(calls)|$(ls "$TMP/state/self" 2> /dev/null)"

echo "=== the two presses ==="
# The second run is a new stand-in, so its record is placed under its pid by
# a hook between its start and the helper's: run_self's go file.
press_after() { # secs-since-first [first-press-id] -> sets out, rc
	local secs=$1 pid i
	rm -f "$TMP/go" "$TMP/pid" "$TMP/out" "$TMP/done"
	env __CLAUDE_FN_SHELL="$$" RESTART_SELF_NOW=$((1000 + secs)) RESTART_SELF_DETACH="$TMP/bin/detach" \
		"$TMP/bin/claude" -c '
		echo $$ > "$TMP/pid"
		while [ ! -e "$TMP/go" ]; do sleep 0.05; done
		"$SELF" > "$TMP/out" 2>&1
		echo $? > "$TMP/done"' < /dev/null > /dev/null 2>&1 &
	for i in $(seq 1 100); do [ -s "$TMP/pid" ] && break; sleep 0.05; done
	pid=$(cat "$TMP/pid")
	jq -n --argjson pid "$pid" --arg sid "$SID" '{pid:$pid, sessionId:$sid, name:"notes", status:"idle"}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	mkdir -p "$TMP/state/self"
	printf '%s\n' "${FIRST:-1000 $SID}" > "$TMP/state/self/$pid"
	touch "$TMP/go"
	for i in $(seq 1 200); do [ -s "$TMP/done" ] && break; sleep 0.05; done
	rc=$(cat "$TMP/done" 2> /dev/null)
	out=$(cat "$TMP/out" 2> /dev/null)
	CLAUDE_PID=$pid
	rm -f "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	kill -KILL "$pid" 2> /dev/null
}
# The detach: runs what it is given at once and in the foreground, so the
# test sees the detached half's whole effect; logs that it was used.
printf '#!/usr/bin/env bash\necho "detach $(basename "$1") ${*:2:1}" >> "$TMP/calls"\nexec "$@"\n' > "$TMP/bin/detach"
chmod +x "$TMP/bin/detach"

fresh
press_after 5
assert_eq "a second press within the window starts the restart, detached, and returns a line saying so" \
	"Restarting notes once it is idle; it comes back in this tab. Log: $TMP/restart-self.log" "$out"
assert_eq "...through the detached half, whose restart-session.sh call has no session id of its own" \
	"detach restart-self.sh --detached|restart $SID session-id=unset" "$(calls)"
case "$(cat "$TMP/restart-self.log")" in *"restart-session.sh exited 0"*) ok "...with its outcome in the log" ;; *) bad "...with its outcome in the log (got [$(cat "$TMP/restart-self.log")])" ;; esac
assert_eq "...and the record of the first press consumed" "0" "$(ls "$TMP/state/self" | wc -l | tr -d ' ')"
fresh
press_after 10
assert_eq "exactly at the window's end it still counts" "restart $SID session-id=unset" "$(calls | sed 's/^detach[^|]*|//')"
fresh
press_after 11
assert_eq "one second after the window: a first press again, restarting nothing" \
	"Restart notes? nothing in it is stale.|stale $SID inside=1" "$(head -n 1 <<< "$out")|$(calls)"
fresh
FIRST="1000 99999999-0000-0000-0000-000000000000" press_after 3
assert_eq "a record of another session's press does not count" "stale $SID inside=1" "$(calls)"
fresh
press_after -5
assert_eq "a clock that went backwards does not count either" "stale $SID inside=1" "$(calls)"

echo "=== the detached half waits for idle ==="
fresh
# Detached half run directly, as setsid would run it, against a stand-in.
run_detached() { # status -> sets rc, out
	local pid
	rm -f "$TMP/pid"
	"$TMP/bin/claude" -c 'echo $$ > "$TMP/pid"; sleep 30' < /dev/null > /dev/null 2>&1 &
	for _ in $(seq 1 100); do [ -s "$TMP/pid" ] && break; sleep 0.05; done
	pid=$(cat "$TMP/pid")
	jq -n --argjson pid "$pid" --arg sid "$SID" --arg status "$1" '{pid:$pid, sessionId:$sid, status:$status}' > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	if [ -n "${BECOMES_IDLE:-}" ]; then
		(sleep 1; jq '.status = "idle"' "$CLAUDE_CONFIG_DIR/sessions/$pid.json" > "$TMP/pf" && mv "$TMP/pf" "$CLAUDE_CONFIG_DIR/sessions/$pid.json") &
	fi
	CLAUDE_CODE_SESSION_ID=$SID "$SELF" --detached "$SID" "$pid" > "$TMP/out" 2>&1
	rc=$?
	out=$(cat "$TMP/out")
	rm -f "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	{ kill -KILL "$pid" && wait "$pid"; } 2> /dev/null
}
run_detached idle
assert_eq "idle: restart-session.sh runs at once" "0|restart $SID session-id=unset" "$rc|$(calls)"
fresh
BECOMES_IDLE=1 run_detached busy
assert_eq "busy at first, idle a second later: waits, then restarts" "0|restart $SID session-id=unset" "$rc|$(calls)"
fresh
RESTART_SELF_IDLE_SECS=1 run_detached busy
assert_eq "never idle: gives up after the bound, restarts nothing, and says so in the log and a notification" \
	"1|notify Claude Code session not restarted not restarted: not idle after 1s (not idle: its status is busy)" "$rc|$(calls)"
case "$(cat "$TMP/restart-self.log" 2> /dev/null)$out" in *"not idle after 1s"*) ok "...the log line is there" ;; *) bad "...the log line is there" ;; esac

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
