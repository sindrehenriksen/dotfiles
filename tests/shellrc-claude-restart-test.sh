#!/usr/bin/env bash
# .shellrc's `claude` function and the restart marker (claude/restart-session.sh,
# Linux): once claude has ended, the function finds the marker left for its
# shell, removes it and runs the resume in the same shell; with no marker, a
# marker whose claude still runs, or a stale one, it behaves as it always did.
# In bash and zsh. HOME is a temp dir, so no ~/.shellrc.early, secrets file or
# mise is read, and `claude` is a stub that prints what it was started with,
# says whether the function's shell pid reached its environment, and, when
# the test asks, leaves the marker as restart-session.sh would while it runs.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELLRC="$HERE/../.shellrc"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home" "$ROOT/bin" "$ROOT/markers"

# The stub: the marker is written for the shell that ran it ($PPID) with its
# own pid (dead once it ends), a session id and what to run. $STUB_MARKER
# says what the command is; it leaves a marker only on its first run.
cat > "$ROOT/bin/claude" << 'STUB'
#!/usr/bin/env bash
echo "ran $* shell-ok=$([ "${__CLAUDE_FN_SHELL:-}" = "$PPID" ] && echo yes || echo no)"
n=$(cat "$STUB_COUNT" 2> /dev/null || echo 0)
echo $((n + 1)) > "$STUB_COUNT"
if [ "$n" -eq 0 ] && [ -n "${STUB_MARKER:-}" ]; then
	printf '%s\n%s\n%s\n' "${STUB_MARKER_PID:-$$}" 0000 "$STUB_MARKER" > "$CLAUDE_RESTART_DIR/$PPID"
	[ -z "${STUB_MARKER_AGE:-}" ] || touch -d "$STUB_MARKER_AGE" "$CLAUDE_RESTART_DIR/$PPID"
fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$ROOT/bin/claude"

# in_shell <shell> <script> [VAR=value ...]
in_shell() {
	local sh=$1 script=$2
	shift 2
	rm -f "$ROOT/count" "$ROOT"/markers/*
	env -i HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" TERM=dumb STUB_COUNT="$ROOT/count" \
		CLAUDE_RESTART_DIR="$ROOT/markers" "$@" \
		"$sh" -c ". '$SHELLRC' > /dev/null 2>&1; $script" 2> /dev/null
}

for sh in bash zsh; do
	command -v "$sh" > /dev/null || { echo "skipped: no $sh"; continue; }
	echo "=== $sh ==="
	assert_eq "$sh: no marker: claude runs once, with its shell's pid in its environment, and its status is the function's" \
		"ran --model x shell-ok=yes
rc=7" "$(in_shell "$sh" 'claude --model x; echo rc=$?' STUB_RC=7)"
	assert_eq "$sh: a marker left while it ran: the resume runs in the same shell, through the function again" \
		"ran a shell-ok=yes
ran --resume abc shell-ok=yes
rc=0" "$(in_shell "$sh" 'claude a; echo rc=$?' STUB_MARKER="claude --resume abc")"
	assert_eq "$sh: ...in the directory the resume changes into, which the shell stays in" \
		"ran a shell-ok=yes
ran --resume abc shell-ok=yes
/" "$(in_shell "$sh" 'claude a; pwd' STUB_MARKER="cd / && claude --resume abc")"
	assert_eq "$sh: ...and the resume's own status is the function's" \
		"ran a shell-ok=yes
ran --resume abc shell-ok=yes
rc=5" "$(in_shell "$sh" 'claude a; echo rc=$?' STUB_MARKER="claude --resume abc; (exit 5)")"
	assert_eq "$sh: the marker is consumed: nothing is left to resume a later claude" \
		"0" "$(in_shell "$sh" 'claude a > /dev/null; ls "$CLAUDE_RESTART_DIR" | wc -l | tr -d " "' STUB_MARKER="true")"
	assert_eq "$sh: a marker whose claude still runs is left for when it ends" \
		"ran a shell-ok=yes
rc=0
1" "$(in_shell "$sh" 'sleep 30 & STUB_MARKER_PID=$! claude a; echo rc=$?; ls "$CLAUDE_RESTART_DIR" | wc -l | tr -d " "; kill $!' STUB_MARKER="claude --resume abc")"
	assert_eq "$sh: a marker older than five minutes is ignored, and removed" \
		"ran a shell-ok=yes
rc=0
0" "$(in_shell "$sh" 'claude a; echo rc=$?; ls "$CLAUDE_RESTART_DIR" | wc -l | tr -d " "' STUB_MARKER="claude --resume abc" STUB_MARKER_AGE="1 hour ago")"
	assert_eq "$sh: a marker for another shell's pid is not touched" \
		"ran a shell-ok=yes
rc=0
1" "$(in_shell "$sh" 'printf "1\n2\nclaude --resume z\n" > "$CLAUDE_RESTART_DIR/1"; claude a; echo rc=$?; ls "$CLAUDE_RESTART_DIR" | wc -l | tr -d " "')"
done

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
