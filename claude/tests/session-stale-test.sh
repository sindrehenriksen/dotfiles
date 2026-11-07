#!/usr/bin/env bash
# claude/session-stale.sh: why a live session is worth restarting, and only
# where restart-session.sh would accept it. The session is a stand-in
# process named `claude` with a pid file written here; the home directory,
# config dir, recorder store and installed Claude Code are throwaway ones,
# and the process table is a file the test writes, as in
# restart-session-test.sh. Nothing live is read or touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"
STALE="$HERE/../session-stale.sh"

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
	for p in $(cat "$TMP/spawned" 2> /dev/null); do kill -KILL "$p" 2> /dev/null; done
	rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/config"
export CLAUDE_SESSION_STORE="$TMP/store"
export SESSION_STALE_CLAUDE_BIN="$TMP/local-bin/claude"
# These suites cover the tab path (macOS); the marker path is in restart-session-test.sh.
export RESTART_SESSION_MODE=tab
export RESTART_SESSION_PS="$TMP/ps"
export RESTART_SESSION_ARGV="$TMP/argv-of"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_SESSION_STORE" "$TMP/local-bin" "$TMP/versions" "$TMP/bin"
printf '#!/usr/bin/env bash\ncat "%s/procs"\n' "$TMP" > "$TMP/ps"
printf '#!/usr/bin/env bash\ncat "%s/argv"\n' "$TMP" > "$TMP/argv-of"
chmod +x "$TMP/ps" "$TMP/argv-of"
printf '%s\0' claude --settings /x.json --resume x > "$TMP/argv"

# Installed Claude Code: a link named for its version, as the installer
# leaves ~/.local/bin/claude.
: > "$TMP/versions/2.1.318"
ln -sfn "$TMP/versions/2.1.318" "$SESSION_STALE_CLAUDE_BIN"

old_stamp() { date -r $(($(date +%s) - $1)) +%Y%m%d%H%M.%S 2> /dev/null || date -d @$(($(date +%s) - $1)) +%Y%m%d%H%M.%S; }
for f in .zprofile .zshrc .profile .shellrc .shellrc.early .secrets.env; do
	echo "# $f" > "$HOME/$f"
done
# shellcheck source=../desk-lib/start-state.sh
source "$HERE/../desk-lib/start-state.sh"

uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
account() { jq -n --arg a "$1" '{oauthAccount:{accountUuid:$a, emailAddress:"someone@example.invalid"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"; }

# A live stand-in for session $1, started an hour ago as far as its pid file
# says, on version $2, its start recorded under account $3 (none if empty)
# with the shell files as they are now, or as $4 gives them (none if
# empty).
session() { # id version account [shell hashes] -> sets pid
	start_claude_stand_in "$TMP/bin" 300
	pid=$!
	echo "$pid" >> "$TMP/spawned"
	local started=$((($(date +%s) - 3600) * 1000))
	jq -n --argjson pid "$pid" --arg id "$1" --arg v "$2" --argjson t "$started" --arg cwd "$TMP" --arg ps "$(proc_start_of "$pid")" \
		'{pid:$pid, sessionId:$id, name:"stand-in", cwd:$cwd, startedAt:$t, procStart:$ps, version:$v, status:"idle"}' \
		> "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/-p"
	: > "$CLAUDE_CONFIG_DIR/projects/-p/$1.jsonl"
	local shell="${4-$(desk_shell_hashes)}"
	jq -cn --argjson pid "$pid" --arg a "$3" --arg shell "$shell" \
		'{event:"start", source:"startup", pid:$pid} + (if $a != "" then {account:$a} else {} end)
		+ (if $shell != "" then {shell: ($shell | fromjson)} else {} end)' \
		> "$CLAUDE_SESSION_STORE/$1.jsonl"
	tab "$pid"
}
# Its tab: claude typed into the user's login shell, unless given another
# parent. Its exact argv is $TMP/argv.
tab() { # pid [parent-args]
	{
		printf '9000 1 -/bin/zsh\n'
		printf '9001 9000 %s\n' "${2:-/bin/zsh -lic claude --resume x}"
		printf '%s 9001 claude --settings /x.json --resume x\n' "$1"
	} > "$TMP/procs"
}
run() { # id -> out, rc
	out="$("$STALE" "$1" 2> "$TMP/err")"
	rc=$?
}

echo "=== nothing changed ==="
account acct-a
s1=$(uuid)
session "$s1" 2.1.318 acct-a
run "$s1"
assert_eq "no reasons, exit 0" "0|" "$rc|$out"

echo "=== a new version ==="
s2=$(uuid)
session "$s2" 2.1.300 acct-a
run "$s2"
assert_eq "named, with both versions" "0|version: 2.1.300 running, 2.1.318 installed" "$rc|$out"
jq '.status = "busy"' "$CLAUDE_CONFIG_DIR/sessions/$pid.json" > "$TMP/pf" && mv "$TMP/pf" "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
out="$("$STALE" "$s2" "version: 2.1.300 running, 2.1.318 installed" 2> /dev/null)"
rc=$?
assert_eq "the reasons last offered, unchanged: exit 4, the heavy checks skipped (busy goes unseen)" \
	"4|version: 2.1.300 running, 2.1.318 installed" "$rc|$out"
out="$("$STALE" "$s2" "shell: ~/.zshrc changed since it started" 2> /dev/null)"
rc=$?
assert_eq "...changed since: checked in full" "1|" "$rc|$out"
jq '.status = "idle"' "$CLAUDE_CONFIG_DIR/sessions/$pid.json" > "$TMP/pf" && mv "$TMP/pf" "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
rm "$SESSION_STALE_CLAUDE_BIN"
printf '#!/usr/bin/env bash\necho "2.1.300 (Claude Code)"\n' > "$SESSION_STALE_CLAUDE_BIN"
chmod +x "$SESSION_STALE_CLAUDE_BIN"
run "$s2"
assert_eq "with no version link, claude --version says what is installed" "0|" "$rc|$out"
rm "$SESSION_STALE_CLAUDE_BIN"
ln -sfn "$TMP/versions/2.1.318" "$SESSION_STALE_CLAUDE_BIN"

echo "=== shell files changed since it started ==="
s3=$(uuid)
echo "# .shellrc" > "$TMP/shellrc-target"
ln -sfn "$TMP/shellrc-target" "$HOME/.shellrc"
session "$s3" 2.1.318 acct-a
echo "# .zshrc" > "$HOME/.zshrc"
touch "$HOME/.profile"
run "$s3"
assert_eq "a file rewritten with the same contents is no change" "0|" "$rc|$out"
echo "export X=1" >> "$HOME/.zshrc"
echo "export Y=1" >> "$TMP/shellrc-target"
rm "$HOME/.profile"
run "$s3"
assert_eq "changed contents are named, a linked file's by its target's, and so is a file now gone" \
	"0|shell: ~/.zshrc, ~/.profile, ~/.shellrc changed since it started" "$rc|$out"
echo "# .zshrc" > "$HOME/.zshrc"
echo "# .shellrc" > "$TMP/shellrc-target"
echo "# .profile" > "$HOME/.profile"
echo "alias x=y" > "$HOME/.bashrc"
run "$s3"
assert_eq "put back, with only a file that does not shape a login session changed: nothing" "0|" "$rc|$out"
touch -t "$(old_stamp 60)" "$HOME/.secrets.env"
run "$s3"
assert_eq "the secrets file, judged by size and mtime alone, counts as changed when only touched" \
	"0|shell: ~/.secrets.env changed since it started" "$rc|$out"
s3b=$(uuid)
session "$s3b" 2.1.318 acct-a ""
echo "export X=1" >> "$HOME/.zshrc"
run "$s3b"
assert_eq "a start that noted no hashes is not flagged" "0|" "$rc|$out"
echo "# .zshrc" > "$HOME/.zshrc"

echo "=== the account its connectors loaded under ==="
s4=$(uuid)
session "$s4" 2.1.318 acct-a
account acct-b
run "$s4"
assert_eq "another account logged in now: named" \
	"0|account: its connectors are another account's than the one logged in now" "$rc|$out"
case "$out" in *acct-* | *someone@*) bad "...without printing account details" ;; *) ok "...without printing account details" ;; esac
jq -cn --argjson pid "$pid" '{event:"start", source:"compact", pid:$pid, account:"acct-b"}' >> "$CLAUDE_SESSION_STORE/$s4.jsonl"
run "$s4"
assert_eq "a compaction since, which loads nothing, does not change what it loaded under" \
	"0|account: its connectors are another account's than the one logged in now" "$rc|$out"
account acct-a
run "$s4"
assert_eq "switched back: cleared" "0|" "$rc|$out"
s5=$(uuid)
session "$s5" 2.1.318 ""
account acct-b
run "$s5"
assert_eq "a start that recorded no account is not flagged" "0|" "$rc|$out"
account acct-a

echo "=== only where restart-session.sh would accept it ==="
s6=$(uuid)
session "$s6" 2.1.300 acct-a
jq '.status = "busy"' "$CLAUDE_CONFIG_DIR/sessions/$pid.json" > "$TMP/pf" && mv "$TMP/pf" "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
run "$s6"
assert_eq "busy: exit 1, nothing printed" "1|" "$rc|$out"
assert_eq "...why on stderr" "session-stale: not idle: its status is busy" "$(cat "$TMP/err")"
jq '.status = "idle"' "$CLAUDE_CONFIG_DIR/sessions/$pid.json" > "$TMP/pf" && mv "$TMP/pf" "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-p/$s6/subagents"
: > "$CLAUDE_CONFIG_DIR/projects/-p/$s6/subagents/agent-x.jsonl"
run "$s6"
assert_eq "a subagent writing: exit 1" "1|" "$rc|$out"
rm -r "$CLAUDE_CONFIG_DIR/projects/-p/$s6"
printf '%s\0' claude --resume x --dangerously-skip-permissions > "$TMP/argv"
run "$s6"
assert_eq "flags a restart will not carry: exit 1" "1|" "$rc|$out"
printf '%s\0' claude --settings /x.json --resume x > "$TMP/argv"
tab "$pid" "/bin/zsh -lic CLAUDE_CONFIG_DIR='/c' claude --resume x"
sed -i.bak 's|^9000 1 -/bin/zsh$|9000 1 /usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l /bin/zsh|' "$TMP/procs"
run "$s6"
assert_eq "a tab that would close with it: exit 3, with the reasons" "3|version: 2.1.300 running, 2.1.318 installed" "$rc|$out"
tab "$pid"
run "$s6"
assert_eq "all clear again: offered" "0|version: 2.1.300 running, 2.1.318 installed" "$rc|$out"

echo "=== sessions it cannot judge ==="
run "$(uuid)"
assert_eq "no live process: exit 1" "1|" "$rc|$out"
s7=$(uuid)
session "$s7" 2.1.300 acct-a
first=$pid
start_claude_stand_in "$TMP/bin" 300
echo "$!" >> "$TMP/spawned"
second=$!
jq --argjson p "$second" --arg ps "$(proc_start_of "$second")" '.pid = $p | .procStart = $ps' \
	"$CLAUDE_CONFIG_DIR/sessions/$first.json" > "$CLAUDE_CONFIG_DIR/sessions/$second.json"
run "$s7"
assert_eq "two live processes on it: exit 1" "1|session-stale: more than one process holds it" "$rc|$out$(cat "$TMP/err")"
echo "=== naming the session a pid holds ==="
out="$("$STALE" --pid "$first" /nonexistent "$CLAUDE_CONFIG_DIR")"
assert_eq "the session, its config dir and its name" "$s7	$CLAUDE_CONFIG_DIR	stand-in" "$out"
jq '.procStart = "Thu Jan 01 00:00:00 2015"' "$CLAUDE_CONFIG_DIR/sessions/$first.json" > "$TMP/pf" && mv "$TMP/pf" "$CLAUDE_CONFIG_DIR/sessions/$first.json"
"$STALE" --pid "$first" "$CLAUDE_CONFIG_DIR" > /dev/null
assert_eq "a pid file whose procStart is not that process's: no session" "1" "$?"
"$STALE" --pid 999999 "$CLAUDE_CONFIG_DIR" > /dev/null
assert_eq "a pid with no pid file: no session" "1" "$?"
rm "$CLAUDE_CONFIG_DIR/sessions/$second.json"
run "$s7"
assert_eq "...and the same check when asked by id: the reused pid is not its process" "1|" "$rc|$out"
run "not-an-id"
assert_eq "not an id: exit 1" "1" "$rc"
"$STALE" > /dev/null 2>&1
assert_eq "no argument: usage, exit 2" "2" "$?"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
