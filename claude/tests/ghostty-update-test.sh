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

# A home of its own, so nothing that falls back to ~/.claude reads a live
# pid file.
export HOME="$TMP/home"
mkdir -p "$HOME"
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
export GHOSTTY_UPDATE_CALLER_SECS=3 GHOSTTY_UPDATE_CONFIRM_WAIT_SECS=8
export GHOSTTY_UPDATE_LAUNCH_SECS=2 GHOSTTY_UPDATE_RESTORE_SECS=2 GHOSTTY_UPDATE_PROMPT_SECS=3
export GHOSTTY_UPDATE_CONFIRM_SECS=3 GHOSTTY_UPDATE_TAB_TIMEOUT_SECS=5
export REOPEN_CONFIRM_SECS=5
unset CLAUDE_CODE_SESSION_ID DESK_HEADLESS DESK_CONFIG
ln -sf "$(command -v bash)" "$TMP/bin/claude"
export TMP PROJ_DIR TRANSCRIPTS RECORDER PLATFORM="$HERE/lib/platform.sh"

# Starts a stand-in session $1 on a terminal of its own and prints its pid:
# the SessionStart hook, then a wait; on SIGTERM the SessionEnd hook with
# reason "other", its pid file removed, as Claude Code does; with notty, in a
# session of its own with no terminal at all. Shared with the fake tab
# helper, whose `type` can stand for the resume.
cat > "$TMP/spawn.sh" << 'SPAWN'
source "$PLATFORM"
name_of() { echo "s-${1:0:8}"; }
no_terminal() { perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' "$@"; }
spawn() { # sid [status] [notty]
	local sid=$1 status=${2:-idle} run=on_a_terminal tag i pid procstart now_ms
	[ "${3:-}" = notty ] && run=no_terminal
	tag="$TMP/ctl/$sid.$RANDOM"
	jq -cn --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg tp "$TRANSCRIPTS/$sid.jsonl" \
		'{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup", hook_event_name:"SessionStart"}' > "$tag.start.json"
	jq -cn --arg sid "$sid" '{session_id:$sid, reason:"other", hook_event_name:"SessionEnd"}' > "$tag.end.json"
	[ -e "$TRANSCRIPTS/$sid.jsonl" ] \
		|| printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hello"}}\n{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$(name_of "$sid")" "$sid" > "$TRANSCRIPTS/$sid.jsonl"
	"$run" "$TMP/bin/claude" -c '
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
# the command typed into it) under Ghostty, or under Terminal.app when
# $TMP/outside-<pid> says it runs outside Ghostty, and 7000, the login shell
# of a tab Ghostty restored. With $TMP/procs-extra, those rows too.
cat > "$TMP/bin/ps" << 'EOF'
#!/usr/bin/env bash
echo "8000 1 /Applications/Ghostty.app/Contents/MacOS/ghostty"
echo "8100 1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
echo "7000 8000 -zsh"
for f in "$CLAUDE_CONFIG_DIR"/sessions/*.json; do
	[ -f "$f" ] || continue
	p=$(basename "$f" .json)
	app=8000
	[ -e "$TMP/outside-$p" ] && app=8100
	echo "$((p + 200000)) $app -/bin/zsh"
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
# says that session runs outside Ghostty, or $TMP/nested-<pid> inside
# another program's terminal in a Ghostty tab. `pid` answers only while Ghostty
# runs, and only for a terminal listed in $TMP/terminals (those still open,
# or restored), with the restored login shell 7000. `type` logs, keeps the
# text, and unless $TMP/no-resume, starts a stand-in for the session the
# text resumes, as the typed resume would.
cat > "$DESK_CLOSE_TAB_BIN" << 'EOF'
#!/usr/bin/env bash
case "$1" in
	find)
		echo "find $2 $3" >> "$TMP/tab.log"
		{ [ -e "$TMP/outside-$3" ] || [ -e "$TMP/nested-$3" ]; } && { echo "DeskTabTerminal: no Ghostty terminal is on $2" >&2; exit 1; }
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
# The tab opener reopen-sessions.sh calls: logs the command and starts a
# stand-in for the session, as the resume in the new tab would, unless
# $TMP/opener-fails, or $TMP/no-resume (opened, but the session never
# comes up).
cat > "$DESK_OPEN_TAB_BIN" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$TMP/opened"
[ -e "$TMP/opener-fails" ] && { echo "DeskOpenTab: no frontmost Ghostty window" >&2; echo false; exit 1; }
[ -e "$TMP/no-resume" ] && { echo true; exit 0; }
source "$TMP/spawn.sh"
spawn "$2" > /dev/null
echo true
EOF

# brew: $TMP/installed names the installed cask; $TMP/outdated makes it
# outdated; every other verb is logged, failing when $TMP/brew-fails-<verb>
# lists the cask it fails for.
cat > "$GHOSTTY_UPDATE_BREW" << 'EOF'
#!/usr/bin/env bash
cask="${*: -1}"
case "$1" in
	list) [ "$(cat "$TMP/installed")" = "$cask" ] ;;
	outdated) [ -e "$TMP/outdated" ] && echo "$cask"; exit 0 ;;
	info) jq -n --arg c "$cask" '{casks: [{token: $c, version: (if $c == "ghostty" then "1.4.0" else "18605,c7f6" end)}]}' ;;
	*)
		echo "$1 $cask" >> "$TMP/brew.log"
		[ "$1" = fetch ] && [ -f "$TMP/on-fetch" ] && bash "$TMP/on-fetch"
		grep -qxF "$cask" "$TMP/brew-fails-$1" 2> /dev/null && exit 1
		case "$1" in
			uninstall) rm -f "$TMP/installed" ;;
			install) echo "$cask" > "$TMP/installed" ;;
		esac
		exit 0 ;;
esac
EOF
# Ghostty, and the Hammerspoon driving it: with $TMP/hs-down Hammerspoon
# is unreachable, and accessibility, quit and dialog all fail, as they do
# for real; $TMP/quit-kills-hs makes it so at the quit. Otherwise
# accessibility answers true, or false with $TMP/no-ax. running while
# $TMP/running exists. quit ends it, unless $TMP/quit-fails (the call
# timed out before it reached Ghostty; with $TMP/quit-delivered it timed
# out after), $TMP/quit-refused (it stays, showing nothing) or
# $TMP/dialog-checks (a confirmation it shows for that many looks, after
# which it quits if $TMP/confirm-quit, else stays: a cancel).
# With $TMP/dialog-unknown, dialog cannot tell; when that file holds a
# count, for that many looks, after which Ghostty is gone, as one shutting
# down shows. launch starts it, unless $TMP/no-launch or no cask is
# installed, restoring the terminals listed in $TMP/restore. version is
# the installed cask's.
cat > "$GHOSTTY_UPDATE_APP_BIN" << 'EOF'
#!/usr/bin/env bash
gone() { rm -f "$TMP/running"; : > "$TMP/terminals"; }
case "$1" in
	accessibility)
		[ -e "$TMP/hs-down" ] && { echo "hs: can't access Hammerspoon message port"; exit 1; }
		[ -e "$TMP/no-ax" ] && { echo false; exit 0; }
		echo true ;;
	running) [ -e "$TMP/running" ] ;;
	quit)
		echo quit >> "$TMP/app.log"
		[ -e "$TMP/quit-kills-hs" ] && : > "$TMP/hs-down"
		[ -e "$TMP/hs-down" ] && { echo "hs: can't access Hammerspoon message port"; exit 1; }
		[ -e "$TMP/quit-delivered" ] && { gone; echo "hs did not return within 6s; killed"; exit 124; }
		[ -e "$TMP/quit-fails" ] && { echo "hs did not return within 6s; killed"; exit 124; }
		[ -e "$TMP/quit-refused" ] || [ -e "$TMP/dialog-checks" ] || gone ;;
	dialog)
		[ -e "$TMP/hs-down" ] && { echo unreachable; exit 1; }
		if [ -e "$TMP/dialog-unknown" ]; then
			left=$(cat "$TMP/dialog-unknown")
			if [ -z "$left" ]; then echo unknown; exit 1; fi
			if [ "$left" -gt 0 ]; then echo $((left - 1)) > "$TMP/dialog-unknown"; echo unknown; exit 1; fi
			gone
			echo none
			exit 0
		fi
		left=$(cat "$TMP/dialog-checks" 2> /dev/null || echo 0)
		if [ "$left" -gt 0 ]; then
			echo $((left - 1)) > "$TMP/dialog-checks"
			echo dialog
		else
			[ -e "$TMP/confirm-quit" ] && [ -e "$TMP/dialog-checks" ] && gone
			echo none
		fi ;;
	launch)
		echo launch >> "$TMP/app.log"
		[ -e "$TMP/no-launch" ] && exit 1
		[ -s "$TMP/installed" ] || { echo "Unable to find application named 'Ghostty'"; exit 1; }
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
# The hand-over: the job runs inline from its spec, with the spec's
# environment over this one, after $TMP/before-job if there is one.
cat > "$GHOSTTY_UPDATE_DETACH_BIN" << 'EOF'
#!/usr/bin/env bash
cp "$1" "$TMP/detached"
# Its output goes nowhere: a stand-in it starts would otherwise hold the
# test's $(...) open through the copy of stdout bash keeps around a
# redirected function call.
[ -f "$TMP/before-job" ] && bash "$TMP/before-job" > /dev/null 2>&1
mapfile -t argv < <(jq -r '.ProgramArguments[]' "$1")
mapfile -t envs < <(jq -r '.EnvironmentVariables | to_entries[] | "\(.key)=\(.value)"' "$1")
env "${envs[@]}" "${argv[@]}"
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
	rm -f "$CONFIG_DIR"/sessions/*.json "$TMP"/outside-* "$TMP"/nested-* "$TMP"/argv-* "$TMP"/typed-* "$TMP"/brew-fails-* \
		"$TMP/tab.log" "$TMP/opened" "$TMP/brew.log" "$TMP/app.log" "$TMP/notified" "$TMP/detached" \
		"$TMP/before-job" "$TMP/quit-refused" "$TMP/no-resume" "$TMP/outdated" "$TMP/procs-extra" "$TMP/restore" \
		"$TMP/on-fetch" "$TMP/quit-fails" "$TMP/dialog-checks" "$TMP/confirm-quit" "$TMP/no-launch" "$TMP/opener-fails" \
		"$TMP/quit-delivered" "$TMP/dialog-unknown" "$TMP/hs-down" "$TMP/no-ax" "$TMP/quit-kills-hs"
	rm -rf "$TMP/state"/*
	echo ghostty@tip > "$TMP/installed"
	touch "$TMP/running"
}
tabs() { printf 'T-%s\n' "$@" > "$TMP/terminals"; }

# A script line that marks the session with pid $1 busy, as a prompt
# arriving would.
busy_line() {
	printf "jq '.status = \"busy\"' '%s' > '%s' && mv '%s' '%s'\n" \
		"$CONFIG_DIR/sessions/$1.json" "$TMP/pf" "$TMP/pf" "$CONFIG_DIR/sessions/$1.json"
}
note() { tail -n 1 "$TMP/notified" 2> /dev/null; }
resume_file() { cat "$TMP"/state/logs/ghostty-update-*.resume 2> /dev/null; }
nothing_changed() { # description
	assert_eq "$1" "|ghostty@tip" "$(grep -v '^fetch' "$TMP/brew.log" 2> /dev/null)|$(cat "$TMP/installed")"
}

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

echo "=== Hammerspoon unreachable, or without Accessibility, refuses ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/hs-down"
run_update --dry-run --to ghostty
assert_eq "a dry run: exit 1" "1" "$rc"
assert_has "...saying Hammerspoon is not running" "Hammerspoon is not running, or its hs command cannot reach it (hs: can't access Hammerspoon message port" "$out"
run_update --to ghostty
assert_eq "the update: exit 1" "1" "$rc"
assert_has "...saying the same" "Hammerspoon is not running" "$out"
rm -f "$TMP/hs-down"
: > "$TMP/no-ax"
run_update --to ghostty
assert_eq "no Accessibility: exit 1" "1" "$rc"
assert_has "...saying so" "Hammerspoon has no Accessibility permission" "$out"
assert_eq "nothing stopped" "alive" "$(alive "$pa")"
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
assert_lacks "the session running the command is spared the idle check at first" "($b): not idle" "$out"
now_s=$(date +%s)
printf '{"type":"user","timestamp":"%s","toolUseResult":{"scheduledFor":%s}}\n' \
	"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$(((now_s + 600) * 1000))" >> "$TRANSCRIPTS/$b.jsonl"
CLAUDE_CODE_SESSION_ID="$b" run_update --dry-run --to ghostty
assert_has "...but not the check for what is scheduled in it" "($b): it has a wakeup due at" "$out"

echo "=== Claude Code under Ghostty that no reader reports refuses the update ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
echo "5555 8000 claude --model opus" > "$TMP/procs-extra"
run_update --dry-run --to ghostty
assert_eq "exit 1" "1" "$rc"
assert_has "it names the process" "pid 5555 (claude --model opus)" "$out"

echo "=== Claude Code inside another program's terminal in a tab refuses, saying so ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
touch "$TMP/nested-$pa"
tabs
run_update --dry-run --to ghostty
assert_eq "exit 1" "1" "$rc"
assert_has "it names the cause" "($a): runs under Ghostty inside another program's terminal" "$out"
assert_lacks "...not a config dir" "no reader reports" "$out"
assert_lacks "...nor calls it left alone" "not in a Ghostty tab" "$out"

echo "=== Claude Code under Ghostty with no terminal refuses, saying so ==="
fresh
a=$(uuid)
pa=$(spawn "$a" idle notty)
tabs
run_update --dry-run --to ghostty
assert_eq "exit 1" "1" "$rc"
assert_has "it names the cause" "($a): runs under Ghostty with no terminal, so it has no tab to come back in and the quit may end it" "$out"
assert_lacks "...not a config dir" "no reader reports" "$out"
assert_lacks "...nor calls it left alone" "($a): no terminal" "$out"

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
assert_eq "the job carries the documented overrides into its environment" "2|5" \
	"$(jq -r '.EnvironmentVariables | "\(.GHOSTTY_UPDATE_QUIT_SECS)|\(.GHOSTTY_UPDATE_TAB_TIMEOUT_SECS)"' "$TMP/detached")"
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
assert_eq "the notification is short: the versions, how many came back, the log" \
	"Ghostty updated: ghostty@tip b3dc3d794 (build 18248) -> ghostty 1.4.0. 2 of 2 sessions resumed. Log: $(ls "$TMP"/state/logs/ghostty-update-*.log)" "$(note)"
assert_has "the log says how each came back" "resumed  $(name_of "$a"): in its tab" "$(the_log)"
assert_has "...b in a new tab" "resumed  $(name_of "$b"): in a new tab" "$(the_log)"

echo "=== a session that turns busy during the fetch stops everything ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
busy_line "$pa" > "$TMP/on-fetch"
run_update --to ghostty
assert_eq "the session still runs" "alive" "$(alive "$pa")"
assert_eq "...Ghostty was not quit" "" "$(cat "$TMP/app.log" 2> /dev/null)"
nothing_changed "...and nothing installed"
assert_has "...the notification saying why" "Ghostty not updated: Nothing was done: $(name_of "$a") ($a) is no longer idle: not idle: its status is busy" "$(note)"

echo "=== a session started after the first look stops everything ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
n=$(uuid)
printf 'source "%s"; spawn %s > /dev/null\n' "$TMP/spawn.sh" "$n" > "$TMP/before-job"
run_update --to ghostty
assert_eq "both still run" "alive" "$(alive "$pa")"
assert_has "...the notification naming the new one" "outside the plan, which the quit would end: pid" "$(note)"
assert_has "...by its session" "session $n" "$(note)"
nothing_changed "...nothing installed"

echo "=== Hammerspoon gone by the second look stops everything ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf ': > "%s"\n' "$TMP/hs-down" > "$TMP/on-fetch"
run_update --to ghostty
assert_eq "the session still runs" "alive" "$(alive "$pa")"
assert_eq "...Ghostty was not quit" "" "$(cat "$TMP/app.log" 2> /dev/null)"
nothing_changed "...nothing installed"
assert_has "...the notification naming Hammerspoon" \
	"Ghostty not updated: Nothing was done: Hammerspoon is not running, or its hs command cannot reach it (hs: can't access Hammerspoon message port); start it and run ghostty-update again. Log: " "$(note)"

echo "=== the session that ran this is waited for ==="
fresh
a=$(uuid)
pa=$(spawn "$a" busy)
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
printf '(sleep 1; %s) > /dev/null 2>&1 &\n' "$(busy_line "$pa" | sed 's/"busy"/"idle"/')" > "$TMP/before-job"
CLAUDE_CODE_SESSION_ID="$a" run_update --to ghostty
assert_has "once idle, it was stopped and resumed with the rest" "Ghostty updated: " "$(note)"
assert_has "...in its tab" "type T-$pa 7000" "$(cat "$TMP/tab.log")"
fresh
a=$(uuid)
pa=$(spawn "$a" busy)
tabs "$pa"
CLAUDE_CODE_SESSION_ID="$a" run_update --to ghostty
assert_eq "never idle: still running" "alive" "$(alive "$pa")"
assert_has "...refused, saying so" "the session that ran this, did not go idle within 3s: not idle: its status is busy" "$(note)"
nothing_changed "...nothing installed"

echo "=== a quit confirmation is waited out ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
echo 2 > "$TMP/dialog-checks"
: > "$TMP/confirm-quit"
run_update --to ghostty
assert_has "the user is told it waits for the confirmation" "Ghostty update waiting: Ghostty is asking whether to quit." "$(cat "$TMP/notified")"
assert_has "...confirmed, the update went on" "Ghostty updated: " "$(note)"
assert_eq "...and installed" "ghostty" "$(cat "$TMP/installed")"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
echo 2 > "$TMP/dialog-checks"
run_update --to ghostty
nothing_changed "cancelled: nothing installed"
assert_has "...the session resumed in its own tab" "type T-$pa 7000" "$(cat "$TMP/tab.log")"
assert_has "...the notification saying nothing was updated" "Ghostty not updated: The quit was cancelled. Still ghostty@tip b3dc3d794 (build 18248). 1 of 1 sessions resumed." "$(note)"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
echo 1000 > "$TMP/dialog-checks"
run_update --to ghostty
nothing_changed "still asking when the wait runs out: nothing installed"
assert_eq "...nothing typed into Ghostty, which a later confirm would quit" "" "$(grep '^type' "$TMP/tab.log")"
assert_has "...the notification naming the session not resumed" "0 of 1 sessions resumed. Not resumed: $(name_of "$a"); commands in " "$(note)"
assert_has "...the file it names holds the exact command" "cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" "$(resume_file)"
assert_has "...and the log why" "still asking to confirm the quit" "$(the_log)"

echo "=== a quit call that fails is reported as that ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/quit-fails"
run_update --to ghostty
nothing_changed "nothing installed"
assert_has "...the log naming the failed call" "the quit call to Hammerspoon failed (hs did not return within 6s; killed)" "$(the_log)"
assert_has "...so does the notification" "Ghostty not updated: The quit call to Hammerspoon failed. Still ghostty@tip" "$(note)"
assert_has "...and the session resumed where it was" "type T-$pa 7000" "$(cat "$TMP/tab.log")"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
: > "$TMP/quit-delivered"
run_update --to ghostty
assert_has "a quit call that timed out after it was delivered: the update went on" "Ghostty updated: " "$(note)"
assert_eq "...installed" "ghostty" "$(cat "$TMP/installed")"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
: > "$TMP/quit-kills-hs"
started=$SECONDS
GHOSTTY_UPDATE_CONFIRM_WAIT_SECS=30 run_update --to ghostty
took=$((SECONDS - started))
nothing_changed "Hammerspoon gone at the quit: nothing installed"
assert_eq "...the wait ended well before its limit" "under 20s" "$([ "$took" -lt 20 ] && echo "under 20s" || echo "${took}s")"
assert_lacks "...no dialog claimed" "Ghostty update waiting" "$(cat "$TMP/notified")"
assert_eq "...nothing typed into Ghostty" "" "$(grep '^type' "$TMP/tab.log")"
assert_has "...the notification naming Hammerspoon and what to do" \
	"Ghostty not updated: Hammerspoon stopped answering and Ghostty has not quit; start Hammerspoon, answer Ghostty if it asks whether to quit, then resume the sessions by hand. Still ghostty@tip b3dc3d794 (build 18248). 0 of 1 sessions resumed. Not resumed: $(name_of "$a")" "$(note)"
assert_has "...the log the failed call" "Hammerspoon stopped answering (the quit call: hs: can't access Hammerspoon message port)" "$(the_log)"
assert_has "...the file why, and the command" "not resumed while Hammerspoon does not answer" "$(resume_file)"
assert_has "..." "cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" "$(resume_file)"

echo "=== a dialog that cannot be read counts as open ==="
# The fake answers for the dialog check; the Lua that reads Ghostty's
# windows is covered by hand only.
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/quit-refused"
: > "$TMP/dialog-unknown"
run_update --to ghostty
nothing_changed "nothing installed"
assert_eq "...nothing typed into Ghostty, which may still quit" "" "$(grep '^type' "$TMP/tab.log")"
assert_has "...the user told it waits, and that a cancel may not be seen" \
	"whether it is asking to cannot be read. If it is asking, confirm to go on with the update. A cancel may not be seen: the update then gives up within 8s of the quit" "$(cat "$TMP/notified")"
assert_has "...and at the end, why and what to do" "Ghostty not updated: Ghostty has not quit and may be asking whether to; answer it, then resume the sessions by hand." "$(note)"
assert_has "...the commands in the file" "cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" "$(resume_file)"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
: > "$TMP/quit-refused"
echo 2 > "$TMP/dialog-unknown"
GHOSTTY_UPDATE_QUIT_SECS=10 run_update --to ghostty
assert_lacks "unreadable while Ghostty shuts down: no waiting notification" "Ghostty update waiting" "$(cat "$TMP/notified")"
assert_has "...and the update went on" "Ghostty updated: " "$(note)"

echo "=== brew failing ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
echo ghostty > "$TMP/brew-fails-install"
run_update --to ghostty
assert_eq "an install that fails puts the old cask back" \
	"fetch ghostty|uninstall ghostty@tip|install ghostty|install ghostty@tip" "$(paste -sd'|' "$TMP/brew.log")"
assert_has "...the notification saying so" "Ghostty not updated: Installing ghostty failed, so ghostty@tip was put back. Still ghostty@tip" "$(note)"
assert_has "...the log why" "brew install --cask ghostty failed (exit 1); put ghostty@tip back" "$(the_log)"
assert_has "...and the session still came back" "type T-$pa 7000" "$(cat "$TMP/tab.log")"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
echo ghostty@tip > "$TMP/brew-fails-uninstall"
run_update --to ghostty
assert_eq "an uninstall that fails installs nothing" "fetch ghostty|uninstall ghostty@tip" "$(paste -sd'|' "$TMP/brew.log")"
assert_has "...saying so" "brew uninstall --cask ghostty@tip failed (exit 1), so ghostty was not installed" "$(the_log)"
assert_has "...and the session still came back" "type T-$pa 7000" "$(cat "$TMP/tab.log")"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'T-%s\n' "$pa" > "$TMP/restore"
: > "$TMP/outdated"
echo ghostty@tip > "$TMP/brew-fails-upgrade"
run_update
assert_eq "an upgrade that fails" "fetch ghostty@tip|upgrade ghostty@tip" "$(paste -sd'|' "$TMP/brew.log")"
assert_has "...is reported" "brew upgrade --cask ghostty@tip failed (exit 1)" "$(the_log)"
assert_has "...and the session still came back" "Ghostty not updated: brew upgrade failed. Still ghostty@tip b3dc3d794 (build 18248). 1 of 1 sessions resumed." "$(note)"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
printf 'ghostty\nghostty@tip\n' > "$TMP/brew-fails-install"
run_update --to ghostty
assert_has "both the install and the put-back failing: the notification says what to run" \
	"Ghostty not updated: Installing ghostty failed and putting ghostty@tip back did too; install Ghostty by hand: brew install --cask ghostty. No Ghostty is installed." "$(note)"
assert_eq "...no launch tried" "quit" "$(paste -sd'|' "$TMP/app.log")"
assert_has "...and why the session was not resumed" "no Ghostty is installed to resume it in" "$(resume_file)"

echo "=== Ghostty restoring nothing, or not coming back ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
b=$(uuid)
pb=$(spawn "$b")
tabs "$pa" "$pb"
run_update --to ghostty
assert_eq "restoring no tab: nothing typed" "" "$(grep '^type' "$TMP/tab.log")"
assert_eq "...both reopened in new tabs" "2" "$(grep -c 'claude --resume' "$TMP/opened")"
assert_has "...and counted, once live" "2 of 2 sessions resumed." "$(note)"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/no-launch"
run_update --to ghostty
assert_has "not relaunching: the update is still reported" "Ghostty updated: " "$(note)"
assert_has "...with the session not resumed" "0 of 1 sessions resumed. Not resumed: $(name_of "$a")" "$(note)"
assert_has "...its command in the file" "# $(name_of "$a"): Ghostty is not running after 2s" "$(resume_file)"
assert_eq "...and nothing opened" "" "$(cat "$TMP/opened" 2> /dev/null)"

echo "=== a reopen that does not take carries its resume command ==="
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/opener-fails"
run_update --to ghostty
assert_has "it is not counted as resumed" "0 of 1 sessions resumed. Not resumed: $(name_of "$a")" "$(note)"
assert_has "...the reason and the command in the file" "failed: opener failed" "$(resume_file)"
assert_has "..." "cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" "$(resume_file)"
fresh
a=$(uuid)
pa=$(spawn "$a")
tabs "$pa"
: > "$TMP/no-resume"
run_update --to ghostty
assert_has "a tab opened whose session never came up is not counted either" "0 of 1 sessions resumed. Not resumed: $(name_of "$a")" "$(note)"
assert_has "...its command in the file" "cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" "$(resume_file)"

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
assert_has "the notification names the one not resumed" "Not resumed: $(name_of "$a")" "$(note)"
assert_has "...its file the exact command" "typed into its tab but not live after 3s" "$(resume_file)"
assert_has "..." "cd '$PROJ_DIR' && CLAUDE_CONFIG_DIR='$CONFIG_DIR' claude --resume $a" "$(resume_file)"

echo "=== recorder never logged an error ==="
assert_eq "recorder log is empty" "" "$(cat "$CLAUDE_SESSION_RECORDER_LOG" 2> /dev/null)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
