#!/usr/bin/env bash
# claude/ghostty-update: which sessions it records and refuses on, and what
# the job does with them around the quit and the brew step. Sessions are
# stand-in processes named `claude` (bash under that name) that run the
# recorder hooks, write a pid file and remove it on SIGTERM, each on a
# terminal of its own from `script`, so the real reader sees them live with
# a tty and reopen-sessions.sh, run for real, sees them left open. The
# boundaries are fakes: brew, Ghostty (running, quit, launch, version), the
# notification, the launchd hand-over (the job runs inline), the tab helper
# (which "restores" the terminals the test names), the tab opener
# reopen-sessions.sh calls, the process table and the argv reader. Nothing
# reaches Homebrew, Ghostty, Hammerspoon or launchd, and no real session is
# touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"
CLI="$HERE/../ghostty-update"
RECORDER="$HERE/../hooks/session-recorder.sh"
READER="$HERE/../session-status.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
assert_has() { # description needle haystack
	case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no [$2] in [$3])" ;; esac
}
assert_lacks() {
	case "$3" in *"$2"*) bad "$1 ([$2] in [$3])" ;; *) ok "$1" ;; esac
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
TRANSCRIPTS="$CONFIG_DIR/projects/-the-project"
mkdir -p "$CONFIG_DIR/sessions" "$TRANSCRIPTS" "$PROJ_DIR" "$TMP/store" "$TMP/cache" "$TMP/ctl" "$TMP/bin" "$TMP/state"
export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export GHOSTTY_UPDATE_CONFIG_DIRS="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$TMP/store"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
export DESK_STATE_DIR="$TMP/state"
export DESK_READER="$READER"
export DESK_CLOSE_TAB_BIN="$TMP/bin/desk-close-tab.sh"
export DESK_OPEN_TAB_BIN="$TMP/bin/desk-open-tab.sh"
export DESK_CONFIG_DEFAULT="$TMP/no-desk-config.json"
export RESTART_SESSION_PS="$TMP/bin/ps"
export RESTART_SESSION_ARGV="$TMP/bin/argv"
export GHOSTTY_UPDATE_BREW="$TMP/bin/brew"
export GHOSTTY_UPDATE_APP_BIN="$TMP/bin/ghostty-app"
export GHOSTTY_UPDATE_NOTIFY_BIN="$TMP/bin/notify"
export GHOSTTY_UPDATE_DETACH_BIN="$TMP/bin/detach"
export GHOSTTY_UPDATE_DELAY_SECS=0 GHOSTTY_UPDATE_GRACE_SECS=3 GHOSTTY_UPDATE_QUIT_SECS=2
export GHOSTTY_UPDATE_LAUNCH_SECS=2 GHOSTTY_UPDATE_RESTORE_SECS=2 GHOSTTY_UPDATE_PROMPT_SECS=3
export GHOSTTY_UPDATE_CONFIRM_SECS=3 GHOSTTY_UPDATE_TAB_TIMEOUT_SECS=5
export REOPEN_CONFIRM_SECS=0
unset CLAUDE_CODE_SESSION_ID DESK_HEADLESS DESK_CONFIG
ln -sf "$(command -v bash)" "$TMP/bin/claude"
export TMP PROJ_DIR TRANSCRIPTS RECORDER PLATFORM="$HERE/lib/platform.sh"

# Starts a stand-in session $1 on a terminal of its own and prints its pid:
# the SessionStart hook, then a wait; on SIGTERM the SessionEnd hook with
# reason "other", its pid file removed, as Claude Code does. Shared with the
# fake tab helper, whose `type` can stand for the resume.
cat > "$TMP/spawn.sh" << 'SPAWN'
source "$PLATFORM"
name_of() { echo "s-${1:0:8}"; }
spawn() { # sid [status]
	local sid=$1 status=${2:-idle} tag i pid procstart now_ms
	tag="$TMP/ctl/$sid.$RANDOM"
	jq -cn --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg tp "$TRANSCRIPTS/$sid.jsonl" \
		'{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup", hook_event_name:"SessionStart"}' > "$tag.start.json"
	jq -cn --arg sid "$sid" '{session_id:$sid, reason:"other", hook_event_name:"SessionEnd"}' > "$tag.end.json"
	[ -e "$TRANSCRIPTS/$sid.jsonl" ] \
		|| printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hello"}}\n{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$(name_of "$sid")" "$sid" > "$TRANSCRIPTS/$sid.jsonl"
	on_a_terminal "$TMP/bin/claude" -c '
		trap "\"\$2\" end < \"\$1.end.json\"; rm -f \"\$3/sessions/\$\$.json\"; exit 0" TERM
		"$2" start < "$1.start.json" > /dev/null
		echo $$ > "$1.pid"
		while :; do sleep 1 & wait $!; done' _ "$tag" "$RECORDER" "$CLAUDE_CONFIG_DIR" < /dev/null > /dev/null 2>&1 &
	echo "$!" >> "$TMP/spawned"
	for i in $(seq 1 100); do [ -s "$tag.pid" ] && break; sleep 0.05; done
	pid=$(cat "$tag.pid" 2> /dev/null) || { echo "stand-in for $sid never started" >&2; return 1; }
	echo "$pid" >> "$TMP/spawned"
	procstart=$(proc_start_of "$pid")
	now_ms=$(($(date +%s) * 1000))
	jq -n --argjson pid "$pid" --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg procstart "$procstart" --argjson now "$now_ms" --arg st "$status" \
		'{pid:$pid, sessionId:$sid, cwd:$cwd, startedAt:$now, procStart:$procstart, nameSource:"none", status:$st, updatedAt:$now}' \
		> "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	echo "$pid"
}
SPAWN
# shellcheck source=/dev/null
source "$TMP/spawn.sh"

# The process table: each stand-in in a desk tab (the user's login shell,
# the command typed into it), and 7000, the login shell of a tab Ghostty
# restored. With $TMP/procs-extra, those rows too.
cat > "$TMP/bin/ps" << 'EOF'
#!/usr/bin/env bash
echo "8000 1 /Applications/Ghostty.app/Contents/MacOS/ghostty"
echo "7000 8000 -zsh"
for f in "$CLAUDE_CONFIG_DIR"/sessions/*.json; do
	[ -f "$f" ] || continue
	p=$(basename "$f" .json)
	echo "$((p + 200000)) 8000 -/bin/zsh"
	echo "$((p + 100000)) $((p + 200000)) /bin/zsh -lic claude --resume x"
	echo "$p $((p + 100000)) claude --resume x"
done
cat "$TMP/procs-extra" 2> /dev/null || true
EOF
# A session's exact argv: $TMP/argv-<pid> when the test wrote one.
cat > "$TMP/bin/argv" << 'EOF'
#!/usr/bin/env bash
if [ -f "$TMP/argv-$1" ]; then cat "$TMP/argv-$1"; else printf '%s\0' claude --resume x; fi
EOF

# The tab helper. `find` names terminal T-<pid>, unless $TMP/outside-<pid>
# says that session runs outside Ghostty. `pid` answers only while Ghostty
# runs, and only for a terminal listed in $TMP/terminals (those still open,
# or restored), with the restored login shell 7000. `type` logs, keeps the
# text, and unless $TMP/no-resume, starts a stand-in for the session the
# text resumes, as the typed resume would.
cat > "$DESK_CLOSE_TAB_BIN" << 'EOF'
#!/usr/bin/env bash
case "$1" in
	find)
		echo "find $2 $3" >> "$TMP/tab.log"
		[ -e "$TMP/outside-$3" ] && { echo "DeskTabTerminal: no Ghostty terminal is on $2" >&2; exit 1; }
		echo "T-$3" ;;
	pid)
		[ -e "$TMP/running" ] || { echo "DeskTerminalPid: Ghostty is not running" >&2; exit 1; }
		grep -qxF "$2" "$TMP/terminals" 2> /dev/null \
			|| { echo "DeskTerminalPid: no Ghostty terminal has that id any more" >&2; exit 1; }
		echo 7000 ;;
	type)
		echo "type $2 $3" >> "$TMP/tab.log"
		printf '%s' "$4" > "$TMP/typed-$2"
		if [ ! -e "$TMP/no-resume" ]; then
			source "$TMP/spawn.sh"
			spawn "$(sed -n 's/.*--resume \([0-9a-f-]*\).*/\1/p' <<< "$4")" > /dev/null
		fi ;;
esac
exit 0
EOF
# The tab opener reopen-sessions.sh calls: logs the command.
cat > "$DESK_OPEN_TAB_BIN" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TMP/opened"
echo true
EOF

# brew: $TMP/installed names the installed cask; $TMP/outdated makes it
# outdated; every other verb is logged, failing when $TMP/brew-fails-<verb>
# names the cask it fails for.
cat > "$GHOSTTY_UPDATE_BREW" << 'EOF'
#!/usr/bin/env bash
cask="${*: -1}"
case "$1" in
	list) [ "$(cat "$TMP/installed")" = "$cask" ] ;;
	outdated) [ -e "$TMP/outdated" ] && echo "$cask"; exit 0 ;;
	info) jq -n --arg c "$cask" '{casks: [{token: $c, version: (if $c == "ghostty" then "1.4.0" else "18605,c7f6" end)}]}' ;;
	*)
		echo "$1 $cask" >> "$TMP/brew.log"
		[ "$(cat "$TMP/brew-fails-$1" 2> /dev/null)" = "$cask" ] && exit 1
		case "$1" in
			uninstall) rm -f "$TMP/installed" ;;
			install) echo "$cask" > "$TMP/installed" ;;
		esac
		exit 0 ;;
esac
EOF
# Ghostty: running while $TMP/running exists. quit ends it unless
# $TMP/quit-refused (a confirmation cancelled); launch starts it, Ghostty
# restoring the terminals listed in $TMP/restore. version is the installed
# cask's.
cat > "$GHOSTTY_UPDATE_APP_BIN" << 'EOF'
#!/usr/bin/env bash
case "$1" in
	running) [ -e "$TMP/running" ] ;;
	quit)
		echo quit >> "$TMP/app.log"
		[ -e "$TMP/quit-refused" ] || { rm -f "$TMP/running"; : > "$TMP/terminals"; } ;;
	launch)
		echo launch >> "$TMP/app.log"
		touch "$TMP/running"
		cp "$TMP/restore" "$TMP/terminals" 2> /dev/null ;;
	version)
		case "$(cat "$TMP/installed" 2> /dev/null)" in
			ghostty) echo 1.4.0 ;;
			ghostty@tip) echo "b3dc3d794 (build 18248)" ;;
			*) echo "none installed" ;;
		esac ;;
esac
EOF
cat > "$GHOSTTY_UPDATE_NOTIFY_BIN" << 'EOF'
#!/usr/bin/env bash
printf '%s: %s\n' "$1" "$2" >> "$TMP/notified"
EOF
# The hand-over: the job runs inline, after $TMP/before-job if there is one.
cat > "$GHOSTTY_UPDATE_DETACH_BIN" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TMP/detached"
[ -f "$TMP/before-job" ] && bash "$TMP/before-job"
"$@"
EOF
chmod +x "$TMP"/bin/*

uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
alive() { kill -0 "$1" 2> /dev/null && echo alive || echo gone; }
run_update() { # args... -> sets out, rc
	out="$("$CLI" "$@" 2>&1)"
	rc=$?
}
the_log() { cat "$TMP"/state/logs/ghostty-update-*.log 2> /dev/null; }
# Ends every stand-in from earlier cases and resets the fakes: Ghostty running
# with ghostty@tip, and the tabs open.
fresh() {
	local f
	for f in "$CONFIG_DIR"/sessions/*.json; do
		[ -f "$f" ] && kill -TERM "$(basename "$f" .json)" 2> /dev/null
	done
	sleep 0.5
	rm -f "$CONFIG_DIR"/sessions/*.json "$TMP"/outside-* "$TMP"/argv-* "$TMP"/typed-* "$TMP"/brew-fails-* \
		"$TMP/tab.log" "$TMP/opened" "$TMP/brew.log" "$TMP/app.log" "$TMP/notified" "$TMP/detached" \
		"$TMP/before-job" "$TMP/quit-refused" "$TMP/no-resume" "$TMP/outdated" "$TMP/procs-extra" "$TMP/restore"
	rm -rf "$TMP/state"/*
	echo ghostty@tip > "$TMP/installed"
	touch "$TMP/running"
}
tabs() { printf 'T-%s\n' "$@" > "$TMP/terminals"; }

echo "=== a dry run says what it would do, and does nothing ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
o=$(uuid)
po=$(spawn "$o")
touch "$TMP/outside-$po"
printf '%s\0' claude --model opus --resume x > "$TMP/argv-$pa"
tabs "$pa"
run_update --dry-run --to ghostty
assert_eq "exit 0" "0" "$rc"
assert_has "it names the move, from the version the app reports" \
	"move from ghostty@tip b3dc3d794 (build 18248) to ghostty 1.4.0" "$out"
assert_has "...the session in Ghostty, resumed in its tab with its flags" "($a), in its tab, with --model 'opus'" "$out"
assert_has "...the one outside Ghostty, left alone" "($o): not in a Ghostty tab" "$out"
assert_has "...and that unsent text is lost" "Unsent text in their input boxes is lost." "$out"
assert_eq "nothing stopped" "alive alive" "$(alive "$pa") $(alive "$po")"
assert_eq "...no brew step, no quit, no job" "||" "$(cat "$TMP/brew.log" 2> /dev/null)|$(cat "$TMP/app.log" 2> /dev/null)|$(cat "$TMP/detached" 2> /dev/null)"

echo "=== a session that is busy or running something refuses the whole update ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
b=$(uuid)
pb=$(spawn "$b" busy)
c=$(uuid)
pc=$(spawn "$c")
echo "4100 $pc /bin/zsh -c source $CONFIG_DIR/shell-snapshots/snapshot-zsh-1.sh && eval 'make test'" > "$TMP/procs-extra"
tabs "$pa" "$pb" "$pc"
run_update --to ghostty
assert_eq "exit 1" "1" "$rc"
assert_has "it names the busy one and why" "($b): not idle: its status is busy" "$out"
assert_has "...and the one running a command" "($c): not idle: it is running a shell command (pid 4100)" "$out"
assert_lacks "...not the idle one" "($a): not idle" "$out"
assert_eq "nothing stopped" "alive alive alive" "$(alive "$pa") $(alive "$pb") $(alive "$pc")"
assert_eq "...no brew step, no quit, no job" "||" "$(cat "$TMP/brew.log" 2> /dev/null)|$(cat "$TMP/app.log" 2> /dev/null)|$(cat "$TMP/detached" 2> /dev/null)"
CLAUDE_CODE_SESSION_ID="$b" run_update --dry-run --to ghostty
assert_lacks "the session running the command is spared the idle check" "($b): not idle" "$out"

echo "=== the move: each session back in the tab Ghostty restored for it ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
b=$(uuid)
pb=$(spawn "$b")
o=$(uuid)
po=$(spawn "$o")
touch "$TMP/outside-$po"
printf '%s\0' claude --model opus --resume x > "$TMP/argv-$pa"
tabs "$pa" "$pb"
# Ghostty restores a's tab only: b's must come back in a new tab.
printf 'T-%s\n' "$pa" > "$TMP/restore"
run_update --to ghostty
assert_eq "exit 0" "0" "$rc"
assert_has "it says where the log is" "Log: $DESK_STATE_DIR/logs/ghostty-update-" "$out"
assert_eq "the job was handed the plan" "--job" "$(awk '{print $3}' "$TMP/detached")"
assert_eq "the new cask fetched before the quit, the old one uninstalled, the new one installed" \
	"fetch ghostty|uninstall ghostty@tip|install ghostty" "$(paste -sd'|' "$TMP/brew.log")"
assert_eq "Ghostty quit, then launched" "quit|launch" "$(paste -sd'|' "$TMP/app.log")"
assert_eq "the sessions were stopped" "gone gone" "$(alive "$pa") $(alive "$pb")"
assert_eq "...the one outside Ghostty was not" "alive" "$(alive "$po")"
typed="$(cat "$TMP/typed-T-$pa" 2> /dev/null)"
eval "set -- ${typed# exec /bin/zsh -lic }"
assert_eq "a's resume, with its flags, was typed into its restored tab's shell" \
	"cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --model 'opus' --resume $a; exec /bin/zsh -il" "${1:-}"
assert_eq "...and nothing into b's, which was not restored" "false" "$([ -e "$TMP/typed-T-$pb" ] && echo true || echo false)"
assert_has "b was reopened in a new tab by reopen-sessions.sh" "claude --resume '$b'" "$(cat "$TMP/opened" 2> /dev/null)"
assert_lacks "...and a was not opened a second time" "$a" "$(cat "$TMP/opened" 2> /dev/null)"
note="$(tail -n 1 "$TMP/notified")"
assert_has "the notification says what was updated, from which version to which" \
	"Ghostty updated: ghostty@tip b3dc3d794 (build 18248) -> ghostty 1.4.0. 2 session(s) resumed (" "$note"
assert_has "...naming the sessions and how each came back" "$(name_of "$a"): in its tab" "$note"
assert_has "...b in a new tab" "$(name_of "$b"): in a new tab" "$note"
assert_has "the log has the same" "resumed  $(name_of "$b"): in a new tab" "$(the_log)"

echo "=== a session that turns busy before the job acts stops everything ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'jq %s %s > %s && mv %s %s\n' "'.status = \"busy\"'" "'$CONFIG_DIR/sessions/$pa.json'" "'$TMP/pf'" "'$TMP/pf'" "'$CONFIG_DIR/sessions/$pa.json'" > "$TMP/before-job"
run_update --to ghostty
assert_eq "the session still runs" "alive" "$(alive "$pa")"
assert_eq "...Ghostty was not quit and nothing installed" "|" "$(cat "$TMP/app.log" 2> /dev/null)|$(grep -v '^fetch' "$TMP/brew.log" 2> /dev/null)"
assert_has "...and the notification says why" "Ghostty not updated: Nothing was done: $(name_of "$a") ($a) is no longer idle: not idle: its status is busy" "$(cat "$TMP/notified")"

echo "=== a quit that is cancelled updates nothing, and resumes the sessions where they are ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/quit-refused"
run_update --to ghostty
assert_eq "nothing uninstalled or installed" "fetch ghostty" "$(paste -sd'|' "$TMP/brew.log")"
assert_eq "...still ghostty@tip" "ghostty@tip" "$(cat "$TMP/installed")"
assert_has "the session was resumed in its own tab" "type T-$pa 7000" "$(cat "$TMP/tab.log")"
assert_has "...and the notification says nothing was updated" "Ghostty not updated: Ghostty did not quit within 2s" "$(tail -n 1 "$TMP/notified")"

echo "=== an install that fails puts the old cask back ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
echo ghostty > "$TMP/brew-fails-install"
run_update --to ghostty
assert_eq "ghostty failed to install, so ghostty@tip went back" \
	"fetch ghostty|uninstall ghostty@tip|install ghostty|install ghostty@tip" "$(paste -sd'|' "$TMP/brew.log")"
assert_has "...the notification saying so" "Ghostty not updated: brew install --cask ghostty failed (exit 1); put ghostty@tip back" "$(tail -n 1 "$TMP/notified")"
assert_has "...and the session still came back" "type T-$pa 7000" "$(cat "$TMP/tab.log")"

echo "=== a resume that does not take is reported with the command to run ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
: > "$TMP/no-resume"
run_update
assert_eq "an upgrade of the installed cask, not outdated: nothing to do" "0" "$rc"
assert_has "...saying so" "ghostty@tip is up to date" "$out"
assert_eq "...and nothing stopped" "alive" "$(alive "$pa")"
: > "$TMP/outdated"
run_update
assert_eq "outdated: upgraded in place" "fetch ghostty@tip|upgrade ghostty@tip" "$(paste -sd'|' "$TMP/brew.log")"
assert_has "the failed one is in the notification with the exact resume command" \
	"$(name_of "$a"): typed into its tab but not live after 3s; look at the tab, else: cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" \
	"$(tail -n 1 "$TMP/notified")"

echo "=== recorder never logged an error ==="
assert_eq "recorder log is empty" "" "$(cat "$CLAUDE_SESSION_RECORDER_LOG" 2> /dev/null)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
