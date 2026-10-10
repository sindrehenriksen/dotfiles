#!/usr/bin/env bash
# claude/desk-lib/sleep-inhibit.sh: on Linux a pass holds a sleep inhibitor
# from when it is known to do work until it ends, and goes on without one,
# saying so, when none can be taken. A stub `systemd-inhibit` stands in for
# the real one; no real inhibitor is taken.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"
DESK_RUN="$HERE/../../claude/desk-run"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}
alive() { [ -n "$1" ] && kill -0 "$1" 2> /dev/null && echo true || echo false; }
# A process killed or ended takes up to a second to go (tail --pid polls).
gone_within() { # <pid> <secs>
	local i
	for ((i = 0; i < $2 * 10; i++)); do
		kill -0 "$1" 2> /dev/null || { echo true; return; }
		sleep 0.1
	done
	echo false
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

if [ ! -r /proc/stat ]; then
	echo "skip: the inhibitor is Linux-only"
	echo "=== summary: 0 passed, 0 failed ==="
	exit 0
fi

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
ARGS="$ROOT/inhibit-args"
PIDFILE="$ROOT/inhibit-pid"
# Records its arguments and pid, drops its own options and runs the
# command in its place, as the real one does once it holds the inhibitor.
cat > "$FAKEBIN/inhibit-ok" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGS"
echo \$\$ > "$PIDFILE"
while [ "\${1#--}" != "\${1:-}" ]; do shift; done
exec "\$@"
STUB
printf '#!/usr/bin/env bash\necho "Failed to inhibit: Access denied" >&2\nexit 1\n' > "$FAKEBIN/inhibit-refuses"
printf '#!/usr/bin/env bash\necho $$ > "%s"\nexec sleep 30\n' "$PIDFILE" > "$FAKEBIN/inhibit-hangs"
chmod +x "$FAKEBIN"/*

export DESK_STATE_DIR="$ROOT/state"
for f in common lock sleep-inhibit; do
	# shellcheck source=/dev/null
	source "$LIB/$f.sh"
done

echo "=== taken, then released ==="
dir="$ROOT/d1"
mkdir -p "$dir"
DESK_INHIBIT_BIN="$FAKEBIN/inhibit-ok"
desk_sleep_inhibit p "$dir" 2> "$ROOT/ok.err"
assert_true "it says the inhibitor is taken" "$(grep -q 'sleep inhibitor taken' "$ROOT/ok.err" && echo true || echo false)"
assert_true "for sleep, idle and the lid switch" "$(grep -qx -- '--what=sleep:idle:handle-lid-switch' "$ARGS" && echo true || echo false)"
assert_true "blocking, not delaying" "$(grep -qx -- '--mode=block' "$ARGS" && echo true || echo false)"
holder="$(cat "$PIDFILE")"
assert_true "the holder is running" "$(alive "$holder")"
desk_sleep_inhibit_release
assert_true "release ends the holder" "$(gone_within "$holder" 2)"
assert_eq "and forgets it" "" "$DESK_INHIBIT_PID"

echo
echo "=== refused: logged, and the pass goes on ==="
DESK_INHIBIT_BIN="$FAKEBIN/inhibit-refuses"
out="$(desk_sleep_inhibit p "$dir" 2>&1)"
assert_eq "returns 0" "0" "$?"
assert_true "says none was taken, and why" \
	"$(grep -q 'no sleep inhibitor: .* did not take one (Failed to inhibit: Access denied)' <<< "$out" && echo true || echo false)"

echo
echo "=== not on PATH ==="
DESK_INHIBIT_BIN="$ROOT/no-such-inhibit"
out="$(desk_sleep_inhibit p "$dir" 2>&1)"
assert_true "says so" "$(grep -q 'no sleep inhibitor: .* is not on PATH' <<< "$out" && echo true || echo false)"

echo
echo "=== never says it holds one: given up on, and ended ==="
rm -rf "$dir" && mkdir -p "$dir"
DESK_INHIBIT_BIN="$FAKEBIN/inhibit-hangs"
DESK_INHIBIT_WAIT_SECS=1
desk_sleep_inhibit p "$dir" 2> "$ROOT/hang.err"
assert_true "says none was taken" "$(grep -q 'no sleep inhibitor' "$ROOT/hang.err" && echo true || echo false)"
assert_true "and the stuck holder is gone" "$(gone_within "$(cat "$PIDFILE")" 2)"
DESK_INHIBIT_WAIT_SECS=5

echo
echo "=== desk-run holds it for the pass, and only when the pass does work ==="
# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"
CALLS="$ROOT/calls.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
if kill -0 "\$(cat "$PIDFILE" 2> /dev/null)" 2> /dev/null; then echo held >> "$CALLS"; else echo not-held >> "$CALLS"; fi
echo '{"type":"result","subtype":"success"}'
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude
export DESK_INHIBIT_BIN="$FAKEBIN/inhibit-ok"
export DESK_STATUS_FILE="$DESK_STATE_DIR/status.json"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export CLAUDE_SESSION_STORE="$DESK_STATE_DIR/session-events"

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main
echo "a test prompt" > "$ROOT/prompt.md"
jq -n --arg repo "$repo" --arg prompt "$ROOT/prompt.md" '{
	notes_repo: $repo, timezone: "UTC", files: ["notes.md", "reading.md"],
	ticket_search_tool: "none", mail_search_tool: "none",
	ticket_status_step_id: "none", mail_fetch_step_id: "none",
	passes: { p: { weekdays_only: false, steps: [ { id: "F", kind: "fetch", prompt: $prompt, tools: [], connector: false, timeout: 30 } ] } }
}' > "$ROOT/config.json"
export DESK_CONFIG="$ROOT/config.json"

rm -f "$ARGS" "$PIDFILE"
"$DESK_RUN" p > "$ROOT/run1.out" 2>&1
assert_eq "the pass ran ok" "ok" "$(jq -r '.passes.p.result' "$DESK_STATUS_FILE")"
assert_eq "its model call ran while the inhibitor was held" "held" "$(cat "$CALLS" 2> /dev/null)"
assert_true "the inhibitor went with the runner" "$(gone_within "$(cat "$PIDFILE")" 3)"
rm -f "$ARGS"
"$DESK_RUN" p > "$ROOT/run2.out" 2>&1
assert_true "a run that finds the date done is a no-op" "$(grep -q 'already ok today' "$ROOT/run2.out" && echo true || echo false)"
assert_true "and takes no inhibitor" "$([ ! -e "$ARGS" ] && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
