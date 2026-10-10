#!/usr/bin/env bash
# claude/close-session.sh: ending a live session on purpose and closing its
# tab. Sessions are stand-in processes named `claude` (bash under that name)
# that run the recorder hooks as their own children and write a pid file,
# each on a terminal of its own from `script`, so the real reader sees them
# live with a tty. The tab helper is a fake that logs its calls; nothing
# reaches Hammerspoon or Ghostty, and no real session is touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"
CLOSE="$HERE/../close-session.sh"
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
PROJ_DIR="$CONFIG_DIR/projects/-tmp-close-project"
mkdir -p "$CONFIG_DIR/sessions" "$PROJ_DIR" "$TMP/store" "$TMP/cache" "$TMP/ctl" "$TMP/bin"
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$TMP/store"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
export DESK_READER="$READER"
export DESK_SESSION_RECORDER_BIN="$RECORDER"
export DESK_CLOSE_TAB_BIN="$TMP/bin/desk-close-tab.sh"
export DESK_CONFIG="$TMP/desk-config.json"
export CLOSE_SESSION_GRACE_SECS=2
unset CLAUDE_CODE_SESSION_ID DESK_HEADLESS
echo '{"keep_open": ["keep-me"]}' > "$DESK_CONFIG"
ln -sf "$(command -v bash)" "$TMP/bin/claude"

# The fake tab helper: `find` names terminal T-<pid> for the tty and pid it is
# given (logging whether that pid was still alive), unless $TMP/find-fails
# exists; `close` succeeds unless $TMP/close-fails exists.
cat > "$DESK_CLOSE_TAB_BIN" << FAKE
#!/usr/bin/env bash
if [ "\$1" = find ]; then
	alive=dead; kill -0 "\$3" 2> /dev/null && alive=alive
	echo "find \$2 \$3 \$alive" >> "$TMP/tab.log"
	[ -e "$TMP/find-fails" ] && { echo "DeskTabTerminal: no Ghostty terminal is on \$2" >&2; exit 1; }
	echo "T-\$3"
	exit 0
fi
echo "close \$2" >> "$TMP/tab.log"
[ -e "$TMP/close-fails" ] && { echo "DeskCloseTerminalTab: not closed: its tab holds other terminals too" >&2; exit 1; }
exit 0
FAKE
chmod +x "$DESK_CLOSE_TAB_BIN"

wait_for() { # file, up to ~5s
	local i
	for i in $(seq 1 100); do
		[ -s "$1" ] && return 0
		sleep 0.05
	done
	return 1
}
wait_gone() { # pid, up to ~5s
	local i
	for i in $(seq 1 100); do
		kill -0 "$1" 2> /dev/null || return 0
		sleep 0.05
	done
	return 1
}

# Starts a stand-in session $1 on a terminal of its own and prints its pid.
# It runs the SessionStart hook, then waits; on SIGTERM it runs the
# SessionEnd hook with reason "other", as Claude Code does, and exits. With
# $2 = stubborn it ignores SIGTERM instead.
spawn() { # sid [stubborn]
	local sid=$1 mode=${2:-} tag="$TMP/ctl/$1"
	jq -cn --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg tp "$PROJ_DIR/$sid.jsonl" \
		'{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup", hook_event_name:"SessionStart"}' > "$tag.start.json"
	jq -cn --arg sid "$sid" '{session_id:$sid, reason:"other", hook_event_name:"SessionEnd"}' > "$tag.end.json"
	[ -e "$PROJ_DIR/$sid.jsonl" ] || : > "$PROJ_DIR/$sid.jsonl"
	on_a_terminal "$TMP/bin/claude" -c '
		if [ "$4" = stubborn ]; then trap "" TERM; else trap "\"\$2\" end < \"\$1.end.json\"; exit 0" TERM; fi
		"$2" start < "$1.start.json" > /dev/null
		echo $$ > "$1.pid"
		while :; do sleep 1 & wait $!; done' _ "$tag" "$RECORDER" "" "$mode" < /dev/null > /dev/null 2>&1 &
	echo "$!" >> "$TMP/spawned"
	wait_for "$tag.pid" || { echo "stand-in for $sid never started" >&2; return 1; }
	local pid procstart now_ms
	pid=$(cat "$tag.pid")
	procstart=$(proc_start_of "$pid")
	now_ms=$(($(date +%s) * 1000))
	jq -n --argjson pid "$pid" --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg procstart "$procstart" --argjson now "$now_ms" \
		'{pid:$pid, sessionId:$sid, cwd:$cwd, startedAt:$now, procStart:$procstart, nameSource:"none", status:"idle", updatedAt:$now}' \
		> "$CONFIG_DIR/sessions/$pid.json"
	echo "$pid"
}
field() { "$READER" | jq -r --arg id "$1" "select(.id == \$id) | $2"; }
uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
run_close() { # id -> sets out, rc
	out="$("$CLOSE" "$1" 2> "$TMP/close.err")"
	rc=$?
}
detail() { cut -f4 <<< "$out"; }
status() { cut -f1 <<< "$out"; }

echo "=== refused before anything is touched ==="
run_close "not-a-uuid"
assert_eq "a non-UUID id is refused" "refused" "$(status)"
assert_eq "...exit 1" "1" "$rc"
run_close "$(uuid)"
assert_eq "an unknown session is refused" "refused	no such session" "$(status)	$(detail)"
"$CLOSE" > /dev/null 2>&1
assert_eq "no argument is a usage error" "2" "$?"

echo "=== a live session: recorded, signalled, its tab closed ==="
s1=$(uuid)
# An earlier run that never recorded an end, as a resumed session's often has.
: > "$PROJ_DIR/$s1.jsonl"
jq -cn --arg cwd "$PROJ_DIR" --arg tp "$PROJ_DIR/$s1.jsonl" \
	'{event:"start", time:1, source:"resume", cwd:$cwd, transcript_path:$tp, boot:"1"}' > "$TMP/store/$s1.jsonl"
p1=$(spawn "$s1")
tty1=$(field "$s1" .tty)
case "$tty1" in tty* | pts/*) ok "the stand-in is live on a terminal ($tty1)" ;; *) bad "the stand-in is live on a terminal (got [$tty1])" ;; esac
: > "$TMP/tab.log"
run_close "$s1"
assert_eq "it reports closed, tab closed" "closed	tab closed" "$(status)	$(detail)"
assert_eq "...exit 0" "0" "$rc"
assert_eq "the process is gone" "true" "$(kill -0 "$p1" 2> /dev/null && echo false || echo true)"
rm -f "$CONFIG_DIR/sessions/$p1.json"
assert_eq "the tab was named while the process was alive, then closed by that id" \
	"find $tty1 $p1 alive|close T-$p1" "$(paste -sd'|' "$TMP/tab.log")"
assert_eq "the session's end is the deliberate close, not the process's own SessionEnd" \
	"closed-by-pass true false" "$(field "$s1" '"\(.end_reason) \(.end_deliberate) \(.left_open)"')"
assert_eq "...even though the SessionEnd was recorded after it" "closed-by-pass other" \
	"$(jq -rs '[.[] | select(.event == "end") | .reason] | join(" ")' "$TMP/store/$s1.jsonl")"
run_close "$s1"
assert_eq "a session no longer live is refused" "refused	not live" "$(status)	$(detail)"

echo "=== the tab cannot be told apart: the session closes, the tab stays ==="
s2=$(uuid)
p2=$(spawn "$s2")
: > "$TMP/tab.log"
: > "$TMP/find-fails"
run_close "$s2"
rm -f "$TMP/find-fails" "$CONFIG_DIR/sessions/$p2.json"
assert_eq "closed" "closed" "$(status)"
assert_eq "...saying why the tab was left" "tab left open: could not tell its tab apart: DeskTabTerminal: no Ghostty terminal is on $(field "$s2" .recorded_tty)" "$(detail)"
assert_eq "...and never asked to close one" "0" "$(grep -c '^close' "$TMP/tab.log")"

s3=$(uuid)
p3=$(spawn "$s3")
: > "$TMP/close-fails"
run_close "$s3"
rm -f "$TMP/close-fails" "$CONFIG_DIR/sessions/$p3.json"
assert_eq "a tab the helper would not close is reported, the session still closed" \
	"closed	tab left open: DeskCloseTerminalTab: not closed: its tab holds other terminals too" "$(status)	$(detail)"

s4=$(uuid)
p4=$(spawn "$s4")
jq -c 'if .event == "start" then .tty = "ttys999" else . end' "$TMP/store/$s4.jsonl" > "$TMP/s4" && mv "$TMP/s4" "$TMP/store/$s4.jsonl"
: > "$TMP/tab.log"
run_close "$s4"
rm -f "$CONFIG_DIR/sessions/$p4.json"
case "$(detail)" in "tab left open: its tty "*" is not the one its start recorded (ttys999)") ok "a tty other than the one the start recorded leaves the tab" ;;
	*) bad "a tty other than the one the start recorded leaves the tab (got [$(detail)])" ;; esac
assert_eq "...without asking Ghostty about it" "" "$(cat "$TMP/tab.log")"

echo "=== refusals on a live session leave it running ==="
s5=$(uuid)
p5=$(spawn "$s5")
printf '{"type":"custom-title","customTitle":"keep-me","sessionId":"%s"}\n' "$s5" >> "$PROJ_DIR/$s5.jsonl"
run_close "$s5"
assert_eq "a session in keep_open is refused" "refused	keep-me	in keep_open" "$(status)	$(cut -f3 <<< "$out")	$(detail)"
CLAUDE_CODE_SESSION_ID="$s5" DESK_CONFIG=/dev/null run_close "$s5"
assert_eq "the session running the command is refused" "refused	this is the session running the command" "$(status)	$(detail)"
cp "$CONFIG_DIR/sessions/$p5.json" "$CONFIG_DIR/sessions/99999999.json"
DESK_CONFIG=/dev/null run_close "$s5"
rm -f "$CONFIG_DIR/sessions/99999999.json"
assert_eq "a session two pid files name is refused" "refused" "$(status)"
assert_eq "...as held by more than one process" "more than one process holds this session; close one by hand" "$(detail)"
assert_eq "...and it is still running after all of them" "true" "$(kill -0 "$p5" 2> /dev/null && echo true || echo false)"
assert_eq "...with no end recorded" "0" "$(jq -s 'map(select(.event == "end")) | length' "$TMP/store/$s5.jsonl")"

echo "=== a process that survives SIGTERM ==="
s6=$(uuid)
p6=$(spawn "$s6" stubborn)
: > "$TMP/tab.log"
run_close "$s6"
assert_eq "it is reported as failed" "failed" "$(status)"
assert_eq "...exit 1" "1" "$rc"
assert_eq "...recorded as a failed close" "true" "$(field "$s6" .close_failed)"
assert_eq "...and its tab left alone" "0" "$(grep -c '^close' "$TMP/tab.log")"
kill -KILL "$p6" 2> /dev/null

echo "=== recorder never logged an error ==="
if [ -s "$TMP/recorder.log" ]; then bad "recorder log is empty"; cat "$TMP/recorder.log"; else ok "recorder log is empty"; fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
