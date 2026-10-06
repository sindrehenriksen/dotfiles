#!/usr/bin/env bash
# the `nvim -l` entry point onto desk.block (nvim/lua/desk/cli.lua)
# — exercised as the actual subprocess a non-Lua caller (the private
# regression test, the runner) would run, against from-scratch fixtures.
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

echo "=== blocks: a mix of a plain block, a dash-continued one, and a separator ==="
fixture="$TMP/mixed.md"
cat > "$fixture" <<'EOF'
Alpha Session: doing stuff
  indented line
  another indented line

Beta note here
- a dash item
- another dash item

———

Gamma: final block
EOF
out=$(nvim -l "$CLI" blocks "$fixture")
assert_eq "exit code 0" "0" "$?"
assert_eq "valid JSON" "true" "$(printf '%s' "$out" | jq empty > /dev/null 2>&1 && echo true || echo false)"
assert_eq "three blocks found" "3" "$(printf '%s' "$out" | jq 'length')"
assert_eq "block 1: the plain block with its indented continuation" '{"end":3,"start":1}' \
    "$(printf '%s' "$out" | jq -c -S '.[0]')"
assert_eq "block 2: the dash-continued block, stopping at the blank line" '{"end":7,"start":5}' \
    "$(printf '%s' "$out" | jq -c -S '.[1]')"
assert_eq "the separator line is skipped, never its own block" '{"end":11,"start":11}' \
    "$(printf '%s' "$out" | jq -c -S '.[2]')"

echo
echo "=== blocks: an empty file yields an empty array, not an error ==="
empty="$TMP/empty.md"
: > "$empty"
out=$(nvim -l "$CLI" blocks "$empty")
assert_eq "exit code 0 on an empty file" "0" "$?"
assert_eq "an empty JSON array" "[]" "$out"

echo
echo "=== blocks: a missing file fails loudly, not silently ==="
nvim -l "$CLI" blocks "$TMP/does-not-exist.md" > /dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && ok "a missing file exits non-zero" || bad "a missing file exits non-zero (exited 0)"

echo
echo "=== an unknown verb fails loudly ==="
nvim -l "$CLI" bogus-verb "$fixture" > /dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && ok "an unknown verb exits non-zero" || bad "an unknown verb exits non-zero (exited 0)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
