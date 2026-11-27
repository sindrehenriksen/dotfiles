#!/usr/bin/env bash
# Exercises claude/statusline.sh's strong-tier share segment against a fake
# claude-usage-tally and a throwaway state directory.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="$HERE/../statusline.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

if ! command -v jq >/dev/null; then
    echo "FAIL - jq is not on PATH"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

unset CLAUDE_CONFIG_DIR
export XDG_STATE_HOME="$TMP/state"
STATE="$XDG_STATE_HOME/claude"
CACHE="$STATE/strong-share"

# A tally that counts its runs, stays running until $TMP/hold is removed (a
# case that renders again while a refresh is in flight must not depend on how
# fast its renders are), and prints $FAKE_SHARE.
cat >"$TMP/tally" <<EOF
#!/usr/bin/env bash
echo run >>"$TMP/runs"
for _ in \$(seq 1 200); do [ -e "$TMP/hold" ] || break; sleep 0.05; done
[ "\${1:-}" = --strong-share ] && printf '%s\n' "\${FAKE_SHARE:-}"
EOF
chmod +x "$TMP/tally"
export CLAUDE_USAGE_TALLY="$TMP/tally"
export FAKE_SHARE=42

INPUT='{"cwd":"/","context_window":{"total_input_tokens":1,"total_output_tokens":1},"rate_limits":{"five_hour":{"used_percentage":99},"seven_day":{"used_percentage":18}},"model":{"display_name":"Claude Fable 5.2"}}'
render() { bash "$LINE" <<<"$INPUT"; }
runs() { [ -f "$TMP/runs" ] && wc -l <"$TMP/runs" | tr -d ' ' || echo 0; }
settle() { local i; rm -f "$TMP/hold"; for i in $(seq 1 50); do [ -d "$STATE/strong-share.lock" ] || return 0; sleep 0.1; done; }
reset() { rm -rf "$STATE" "$TMP/runs"; : >"$TMP/hold"; }

reset
out=$(render)
check "no cache: the line has no share segment" '[[ $out == "t:2 | 5h:1% w:82% | fable 5.2 | /" ]]'
settle
check "no cache: one refresh was started, and filled the cache" '[ "$(runs)" = 1 ] && [[ $(cat "$CACHE") == *" 42" ]]'
out=$(render)
check "after the refresh: the segment shows after the weekly figure" '[[ $out == "t:2 | 5h:1% w:82% f:42% | fable 5.2 | /" ]]'
settle
check "a fresh cache starts no refresh" '[ "$(runs)" = 1 ]'

reset
mkdir -p "$STATE"
echo "$(date +%s) 60" >"$CACHE"
out=$(render)
check "share above 50% is marked" '[[ $out == *" !f:60% | "* ]]'
echo "$(date +%s) 50" >"$CACHE"
out=$(render)
check "exactly 50% is not marked" '[[ $out == *" f:50% | "* ]]'

reset
mkdir -p "$STATE"
echo "1000 33" >"$CACHE"
out=$(render)
out2=$(render)
out3=$(render)
check "stale cache: the old value is still shown" '[[ $out == *" f:33% | "* && $out3 == *" f:33% | "* ]]'
settle
check "stale cache: renders in a row start one refresh" '[ "$(runs)" = 1 ]'
check "stale cache: the refresh replaced the value" '[[ $(cat "$CACHE") == *" 42" ]]'

reset
mkdir -p "$STATE"
echo "1000 33" >"$CACHE"
FAKE_SHARE= render >/dev/null
settle
check "failed refresh: keeps the old value with a new time, so it retries hourly" '[ "$(cut -d" " -f2 "$CACHE")" = 33 ] && [ "$(cut -d" " -f1 "$CACHE")" -gt 1000 ]'

reset
mkdir -p "$STATE/strong-share.lock"
render >/dev/null
sleep 0.2
check "a refresh already running: none is started" '[ "$(runs)" = 0 ]'

reset
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude-work-2" render)
check "seat 2 is named before the token count" '[[ $out == "w2 t:"* ]]'
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude-work" render)
check "seat 1 is named" '[[ $out == "w1 t:"* ]]'
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude" render)
check "the personal dir is not named" '[[ $out == "t:"* ]]'

reset
mkdir -p "$STATE"
echo "1000 33" >"$CACHE"
out=$(CLAUDE_CONFIG_DIR="$HOME/.claude-work-2" render)
rm -f "$TMP/hold"
for _ in $(seq 1 50); do [ -d "$STATE/strong-share-.claude-work-2.lock" ] || break; sleep 0.1; done
check "a seat has its own cache, not the shared one" '[[ $out != *" f:33%"* && $(cat "$CACHE") == "1000 33" && -f "$STATE/strong-share-.claude-work-2" ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
