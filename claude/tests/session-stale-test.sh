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
export RESTART_SESSION_PS="$TMP/ps"
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/sessions" "$CLAUDE_SESSION_STORE" "$TMP/local-bin" "$TMP/versions" "$TMP/bin"
printf '#!/usr/bin/env bash\ncat "%s/procs"\n' "$TMP" > "$TMP/ps"
chmod +x "$TMP/ps"

# Installed Claude Code: a link named for its version, as the installer
# leaves ~/.local/bin/claude.
: > "$TMP/versions/2.1.318"
ln -sfn "$TMP/versions/2.1.318" "$SESSION_STALE_CLAUDE_BIN"

old_stamp() { date -r $(($(date +%s) - $1)) +%Y%m%d%H%M.%S 2> /dev/null || date -d @$(($(date +%s) - $1)) +%Y%m%d%H%M.%S; }
for f in .zprofile .zshrc .profile .shellrc .shellrc.early .secrets.env; do
	: > "$HOME/$f"
	touch -t "$(old_stamp 7200)" "$HOME/$f"
done

uuid() { uuidgen | tr '[:upper:]' '[:lower:]'; }
account() { jq -n --arg a "$1" '{oauthAccount:{accountUuid:$a, emailAddress:"someone@example.invalid"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"; }

# A live stand-in for session $1, started an hour ago as far as its pid file
# says, on version $2, its start recorded under account $3 (none if empty).
session() { # id version account -> sets pid
	start_claude_stand_in "$TMP/bin" 300
	pid=$!
	echo "$pid" >> "$TMP/spawned"
	local started=$((($(date +%s) - 3600) * 1000))
	jq -n --argjson pid "$pid" --arg id "$1" --arg v "$2" --argjson t "$started" --arg cwd "$TMP" \
		'{pid:$pid, sessionId:$id, cwd:$cwd, startedAt:$t, version:$v, status:"idle"}' \
		> "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
	mkdir -p "$CLAUDE_CONFIG_DIR/projects/-p"
	: > "$CLAUDE_CONFIG_DIR/projects/-p/$1.jsonl"
	jq -cn --argjson pid "$pid" --arg a "$3" \
		'{event:"start", source:"startup", pid:$pid} + (if $a != "" then {account:$a} else {} end)' \
		> "$CLAUDE_SESSION_STORE/$1.jsonl"
	tab "$pid"
}
# Its tab: claude typed into the user's login shell, unless given another
# parent; its argv, $CLAUDE_ARGV or a plain resume.
tab() { # pid [parent-args]
	{
		printf '9000 1 -/bin/zsh\n'
		printf '9001 9000 %s\n' "${2:-/bin/zsh -lic claude --resume x}"
		printf '%s 9001 %s\n' "$1" "${CLAUDE_ARGV:-claude --settings /x.json --resume x}"
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
rm "$SESSION_STALE_CLAUDE_BIN"
printf '#!/usr/bin/env bash\necho "2.1.300 (Claude Code)"\n' > "$SESSION_STALE_CLAUDE_BIN"
chmod +x "$SESSION_STALE_CLAUDE_BIN"
run "$s2"
assert_eq "with no version link, claude --version says what is installed" "0|" "$rc|$out"
rm "$SESSION_STALE_CLAUDE_BIN"
ln -sfn "$TMP/versions/2.1.318" "$SESSION_STALE_CLAUDE_BIN"

echo "=== shell files changed since it started ==="
s3=$(uuid)
session "$s3" 2.1.318 acct-a
touch "$HOME/.zshrc"
: > "$TMP/shellrc-target"
ln -sfn "$TMP/shellrc-target" "$HOME/.shellrc"
touch -h -t "$(old_stamp 7200)" "$HOME/.shellrc"
run "$s3"
assert_eq "named, a linked file by its target's time" "0|shell: ~/.zshrc, ~/.shellrc changed since it started" "$rc|$out"
touch -t "$(old_stamp 7200)" "$HOME/.zshrc" "$TMP/shellrc-target"
touch "$HOME/.bashrc" "$HOME/.fzf_config"
run "$s3"
assert_eq "files that do not shape a login session do not count" "0|" "$rc|$out"

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
CLAUDE_ARGV="claude --resume x --chrome" tab "$pid"
run "$s6"
assert_eq "flags a restart cannot carry: exit 1" "1|" "$rc|$out"
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
jq --argjson p "$!" '.pid = $p' "$CLAUDE_CONFIG_DIR/sessions/$first.json" > "$CLAUDE_CONFIG_DIR/sessions/$!.json"
run "$s7"
assert_eq "two live processes on it: exit 1" "1|session-stale: more than one process holds it" "$rc|$out$(cat "$TMP/err")"
run "not-an-id"
assert_eq "not an id: exit 1" "1" "$rc"
"$STALE" > /dev/null 2>&1
assert_eq "no argument: usage, exit 2" "2" "$?"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
