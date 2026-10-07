#!/usr/bin/env bash
# hammerspoon/desk-open-tab.sh and desk-focus-tab.sh never hang on `hs`,
# and report the Lua call's own true/false as their exit status:
#   - hs gets /dev/null on stdin, so a caller whose own stdin never closes
#     (an agent's shell) cannot leave it waiting for more commands;
#   - an hs that never returns is killed after DESK_HS_TIMEOUT_SECS and
#     reported as a failure (exit 124), not waited on.
# `hs` is a stub on PATH; nothing reaches Hammerspoon.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN_TAB_SH="$HERE/../desk-open-tab.sh"
FOCUS_TAB_SH="$HERE/../desk-focus-tab.sh"

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
echo "=== an hs that never returns ==="
# exec, so the stub is one process like the real hs.
stub_hs 'exec sleep 30'
read -r status secs < <(timed "$FOCUS_TAB_SH" ttys001 < /dev/null)
assert_eq "focus-tab reports the timeout as a failure" "124" "$status"
assert_true "...within the limit plus the kill grace" "$([ "$secs" -le 4 ] && echo true || echo false)"
assert_true "...and says so" "$(grep -q 'did not return within 1s' "$ROOT/err" && echo true || echo false)"
read -r status secs < <(timed "$OPEN_TAB_SH" "echo hi" < /dev/null)
assert_eq "open-tab reports the timeout as a failure" "124" "$status"
assert_true "...within the limit plus the kill grace" "$([ "$secs" -le 4 ] && echo true || echo false)"

echo
echo "=== an hs that answers in time is unaffected ==="
stub_hs 'echo "DeskFocusTab: no Ghostty tab is running ttys001"; echo false'
read -r status _ < <(timed "$FOCUS_TAB_SH" ttys001 < /dev/null)
assert_eq "a false from DeskFocusTab is still exit 1" "1" "$status"
stub_hs 'echo "DeskOpenTab: not opening"; echo false'
read -r status _ < <(timed "$OPEN_TAB_SH" "echo hi" < /dev/null)
assert_eq "a false from DeskOpenTab is exit 1, so the runner never stamps it opened" "1" "$status"
stub_hs 'echo true'
read -r status _ < <(timed "$OPEN_TAB_SH" "echo hi" < /dev/null)
assert_eq "a true from DeskOpenTab is exit 0" "0" "$status"
stub_hs 'printf "%s\n" "$@" > "'"$ROOT"'/argv"; echo true'
read -r status _ < <(timed "$FOCUS_TAB_SH" ttys001 < /dev/null)
assert_eq "a true from DeskFocusTab is exit 0" "0" "$status"
assert_eq "hs is given its own IPC timeout too" "-t" "$(head -n1 "$ROOT/argv")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
