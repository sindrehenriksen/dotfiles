#!/usr/bin/env bash
# the `nvim -l` entry point onto desk.tokens/desk.annotate
# (nvim/lua/desk/cli.lua's `tokens` verb) — for the private regression test
# to call, exercised here the same way: as the actual subprocess, against a
# from-scratch fixture file and $DESK_CONFIG.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../lua/desk/cli.lua"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then
		ok "$desc"
	else
		bad "$desc (expected [$expected], got [$actual])"
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CONFIG="$TMP/config.json"
cat > "$CONFIG" <<'EOF'
{
  "tokens": [
    { "pattern": "TICKET%-([0-9]+)", "handler": "url", "template": "https://jira.example.com/browse/TICKET-{1}" },
    { "pattern": "sess%-[0-9]+", "handler": "session" }
  ]
}
EOF

FIXTURE="$TMP/notes.md"
cat > "$FIXTURE" <<'EOF'
sess-1 and TICKET-42 both mentioned here
  a plain indented line, no tokens of interest
sess-2 on its own line
EOF

echo "=== tokens: classifies every session/url token, in file order, url ones carry their url ==="
export DESK_CONFIG="$CONFIG"
out=$(nvim -l "$CLI" tokens "$FIXTURE")
assert_eq "exit code 0" "0" "$?"
assert_eq "valid JSON" "true" "$(printf '%s' "$out" | jq empty > /dev/null 2>&1 && echo true || echo false)"
assert_eq "three tokens found (sess-1, TICKET-42, sess-2)" "3" "$(printf '%s' "$out" | jq 'length')"
assert_eq "first hit is sess-1, a session token on line 1" '{"handler":"session","line":1,"token":"sess-1"}' \
	"$(printf '%s' "$out" | jq -c -S '.[0]')"
assert_eq "the url token carries its templated url" \
	"https://jira.example.com/browse/TICKET-42" \
	"$(printf '%s' "$out" | jq -r '.[] | select(.token == "TICKET-42") | .url')"
assert_eq "sess-2 (line 3) is the last hit" "3" "$(printf '%s' "$out" | jq '.[-1].line')"
assert_eq "the indented prose line contributes nothing" "0" \
	"$(printf '%s' "$out" | jq '[.[] | select(.line == 2)] | length')"

echo
echo "=== tokens: no \$DESK_CONFIG at all -- nothing classifies, never an error ==="
unset DESK_CONFIG
out2=$(nvim -l "$CLI" tokens "$FIXTURE")
assert_eq "exit code 0" "0" "$?"
assert_eq "an empty JSON array" "[]" "$out2"

echo
echo "=== tokens: a missing file fails loudly ==="
export DESK_CONFIG="$CONFIG"
nvim -l "$CLI" tokens "$TMP/does-not-exist.md" > /dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && ok "a missing file exits non-zero" || bad "a missing file exits non-zero (exited 0)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
