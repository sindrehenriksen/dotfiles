#!/usr/bin/env bash
# linux/desk's tab helpers keep the contract of the Hammerspoon ones they
# stand in for: the same arguments, and the exit codes their callers act on
# (the hotkey, the passes, reopen-sessions.sh, close-session.sh).
# `ghostty` is a stub that records its argv; nothing opens a window.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN="$HERE/../desk-open-tab.sh"
FOCUS="$HERE/../desk-focus-tab.sh"
CLOSE="$HERE/../desk-close-tab.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# A refusing `ghostty` on PATH as well, so a case that forgot
# DESK_GHOSTTY_BIN fails instead of opening a real window.
mkdir -p "$ROOT/bin"
printf '#!/usr/bin/env bash\necho "refusing stub" >&2\nexit 1\n' > "$ROOT/bin/ghostty"
chmod +x "$ROOT/bin/ghostty"
export PATH="$ROOT/bin:$PATH"

ARGV="$ROOT/argv"
stub() { # body
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n%s\n' "$ARGV" "$1" > "$ROOT/ghostty-stub"
	chmod +x "$ROOT/ghostty-stub"
	rm -f "$ARGV"
}
export DESK_GHOSTTY_BIN="$ROOT/ghostty-stub"
UUID=0b1c2d3e-4f50-4a61-8b72-9c8d7e6f5a4b

echo "=== open: a new window running the command through a login shell ==="
stub 'exit 0'
"$OPEN" "claude --resume $UUID" "$UUID" "$ROOT" < /dev/null
assert_eq "exit 0 when Ghostty took it" "0" "$?"
assert_eq "argv: +new-window, the cwd, then the command under zsh -lic" \
	"+new-window|--working-directory=$ROOT|-e|/bin/zsh|-lic|claude --resume $UUID; print -n \"\\n[exited \$?; press any key to close]\"; read -sk1" \
	"$(paste -sd'|' "$ARGV")"

stub 'exit 0'
"$OPEN" "true" "" "" background,close < /dev/null
assert_eq "background,close: no cwd, and nothing waits after the command" "+new-window|-e|/bin/zsh|-lic|true" \
	"$(paste -sd'|' "$ARGV")"

echo "=== open: refusals and failures ==="
stub 'exit 0'
"$OPEN" "claude --resume x" "not-a-uuid" "$ROOT" < /dev/null 2> "$ROOT/err"
assert_eq "a non-UUID session id exits 1" "1" "$?"
assert_eq "...without calling Ghostty" "false" "$([ -e "$ARGV" ] && echo true || echo false)"

"$OPEN" "true" "" "" sideways < /dev/null 2> /dev/null
assert_eq "an unknown flag is a usage error" "2" "$?"

stub 'echo "no running instance" >&2; exit 1'
"$OPEN" "true" < /dev/null 2> "$ROOT/err"
assert_eq "Ghostty failing exits 1" "1" "$?"
assert_eq "...passing on what it said" "no running instance" "$(cat "$ROOT/err")"

stub 'sleep 30'
start=$(date +%s)
DESK_TAB_TIMEOUT_SECS=1 "$OPEN" "true" < /dev/null 2> /dev/null
assert_eq "a Ghostty that never returns exits 124" "124" "$?"
assert_eq "...within the limit and its grace" "true" "$([ $(($(date +%s) - start)) -le 3 ] && echo true || echo false)"

echo "=== focus: never focuses, so the hotkey never resumes a live session ==="
"$FOCUS" pts/7 2> "$ROOT/err"
assert_eq "exits 1" "1" "$?"
assert_eq "...saying the session is running and its window cannot be brought forward" \
	"the session is running on pts/7; Ghostty on Linux cannot bring its window forward" "$(cat "$ROOT/err")"

echo "=== close: never names or closes a window ==="
"$CLOSE" find pts/7 1234 2> "$ROOT/err"
assert_eq "find exits 1, so close-session.sh leaves the window" "1" "$?"
assert_eq "...saying why" "Ghostty on Linux cannot name or close a window from outside" "$(cat "$ROOT/err")"
"$CLOSE" close T-1 2> /dev/null
assert_eq "close exits 1" "1" "$?"
"$CLOSE" find pts/7 2> /dev/null
assert_eq "find without a pid is a usage error" "2" "$?"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
