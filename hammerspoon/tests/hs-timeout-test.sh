#!/usr/bin/env bash
# The Hammerspoon helpers (desk-open-tab.sh, desk-focus-tab.sh,
# desk-close-tab.sh, desk-window.sh) never hang on `hs`, report the Lua
# call's own answer as their exit status, and pass nothing unchecked to it:
#   - hs gets /dev/null on stdin, so a caller whose own stdin never closes
#     (an agent's shell) cannot leave it waiting for more commands;
#   - an hs that never returns is killed after DESK_HS_TIMEOUT_SECS and
#     reported as a failure (exit 124), not waited on.
# `hs` is a stub on PATH; nothing reaches Hammerspoon.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN_TAB_SH="$HERE/../desk-open-tab.sh"
FOCUS_TAB_SH="$HERE/../desk-focus-tab.sh"
CLOSE_TAB_SH="$HERE/../desk-close-tab.sh"
WINDOW_SH="$HERE/../desk-window.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
assert_true() {
	if [ "$2" = "true" ]; then ok "$1"; else bad "$1 (got [$2])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"
export DESK_HS_TIMEOUT_SECS=1

stub_hs() {
	printf '#!/usr/bin/env bash\n%s\n' "$1" > "$FAKEBIN/hs"
	chmod +x "$FAKEBIN/hs"
}

# Runs "$@" and prints "<exit status> <whole seconds taken>". Bounded at 8s
# itself (status 137 then), so a regression fails here instead of hanging.
timed() {
	local start status pid
	start=$(date +%s)
	# 0<&0: without an explicit redirect, bash gives a background command
	# /dev/null as stdin, which would hide the pipe the first case is about.
	"$@" 0<&0 > "$ROOT/out" 2> "$ROOT/err" &
	pid=$!
	( sleep 8; kill -KILL "$pid" 2> /dev/null ) > /dev/null 2>&1 &
	local guard=$!
	wait "$pid"
	status=$?
	kill "$guard" 2> /dev/null
	printf '%s %s\n' "$status" "$(($(date +%s) - start))"
}

echo "=== an hs that reads stdin to EOF, under a stdin that never closes ==="
stub_hs 'cat > /dev/null; echo true'
mkfifo "$ROOT/stdin"
# Opened read-write here so it stays open (no EOF) for the whole section.
exec 3<> "$ROOT/stdin"
read -r status secs < <(timed "$FOCUS_TAB_SH" ttys001 <&3)
assert_eq "focus-tab returns success" "0" "$status"
assert_true "...promptly (hs saw /dev/null, not the open pipe)" "$([ "$secs" -le 2 ] && echo true || echo false)"
read -r status secs < <(timed "$OPEN_TAB_SH" "echo hi" "" "" background <&3)
assert_eq "open-tab returns success" "0" "$status"
assert_true "...promptly" "$([ "$secs" -le 2 ] && echo true || echo false)"
exec 3<&-

echo
echo "=== an hs that never returns is killed and reported ==="
# exec, so the stub is one process like the real hs.
stub_hs 'exec sleep 30'
for cmd in "$FOCUS_TAB_SH ttys001" "$OPEN_TAB_SH x" "$CLOSE_TAB_SH close T1" "$WINDOW_SH tall ttys009 4242"; do
	# shellcheck disable=SC2086
	read -r status secs < <(timed $cmd < /dev/null)
	assert_eq "$(basename "${cmd%% *}"): exit 124" "124" "$status"
	assert_true "...within the limit plus the kill grace" "$([ "$secs" -le 4 ] && echo true || echo false)"
done

echo
echo "=== an answer in time is the exit status ==="
stub_hs 'echo false'
read -r status _ < <(timed "$OPEN_TAB_SH" "echo hi" < /dev/null)
assert_eq "a false from DeskOpenTab is exit 1, so the caller never counts it opened" "1" "$status"
stub_hs 'for a in "$@"; do last=$a; done; printf "%s\n" "$last" > "'"$ROOT"'/expr"; echo "terminal T 1"'
"$CLOSE_TAB_SH" find ttys007 4242 < /dev/null > "$ROOT/out" 2> /dev/null
assert_eq "find prints the terminal's id" "T 1" "$(cat "$ROOT/out")"
stub_hs 'for a in "$@"; do last=$a; done; printf "%s\n" "$last" > "'"$ROOT"'/expr"; echo true'
"$CLOSE_TAB_SH" close 'T"1' < /dev/null > /dev/null 2>&1
assert_eq "close quotes the id for Lua" 'DeskCloseTerminalTab("T\"1")' "$(cat "$ROOT/expr")"

echo
echo "=== nothing malformed reaches hs ==="
stub_hs 'printf called > "'"$ROOT"'/called"; echo true'
rm -f "$ROOT/called"
"$WINDOW_SH" restore 'ttys009"); os.exit(' 4242 < /dev/null > /dev/null 2>&1
assert_eq "a tty that is not one is a usage error" "2" "$?"
"$CLOSE_TAB_SH" find ttys007 notapid < /dev/null > /dev/null 2>&1
assert_eq "a pid that is not a number is a usage error" "2" "$?"
"$OPEN_TAB_SH" "echo hi" "" "" bogus < /dev/null > /dev/null 2>&1
assert_eq "an unknown flag is refused" "2" "$?"
assert_eq "...none of them reaching hs" "false" "$([ -e "$ROOT/called" ] && echo true || echo false)"
/bin/bash "$OPEN_TAB_SH" "echo hi" < /dev/null > /dev/null 2>&1
assert_eq "macOS's bash 3.2 runs the opener" "0" "$?"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
