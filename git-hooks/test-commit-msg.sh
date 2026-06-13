#!/usr/bin/env bash
# Tests for git-hooks/commit-msg.
# Run: bash git-hooks/test-commit-msg.sh
# Each case maps to a prior fix — see git log -- git-hooks/commit-msg.

set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/commit-msg"
pass=0
fail=0
total=0

# Reflow test: hook should pass AND output should match expected verbatim.
test_reflow() {
    local name="$1" input="$2" expected="$3"
    total=$((total + 1))
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$input" > "$tmp"
    if ! (cd /tmp && bash "$HOOK" "$tmp") >/dev/null 2>&1; then
        echo "FAIL [$name]: hook exited non-zero"
        fail=$((fail + 1))
        rm -f "$tmp"
        return
    fi
    local actual
    actual=$(cat "$tmp")
    if [ "$actual" != "$expected" ]; then
        echo "FAIL [$name]:"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /'
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
    rm -f "$tmp"
}

# Lint test: only check exit code. env_pfx is optional "KEY=VAL [KEY=VAL ...]".
test_lint() {
    local name="$1" expected_exit="$2" input="$3" env_pfx="${4:-}"
    total=$((total + 1))
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$input" > "$tmp"
    local actual
    (cd /tmp && env $env_pfx bash "$HOOK" "$tmp") >/dev/null 2>&1
    actual=$?
    if [ "$actual" != "$expected_exit" ]; then
        echo "FAIL [$name]: exit $actual, expected $expected_exit"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
    rm -f "$tmp"
}

# --- Title length (e1eac13, 91a0e53) ---
T50=$(printf 'a%.0s' {1..50})
T51=$(printf 'a%.0s' {1..51})
T72=$(printf 'a%.0s' {1..72})
T73=$(printf 'a%.0s' {1..73})

test_lint "title 50 chars passes"               0 "$T50"
test_lint "title 51 chars fails (hard at 50)"   1 "$T51"
test_lint "title 72 passes with override"       0 "$T72" "ALLOW_LONG_COMMIT_TITLE=1"
test_lint "title 73 fails even with override"   1 "$T73" "ALLOW_LONG_COMMIT_TITLE=1"

# --- Autosquash prefix stripping (ef349fc) ---
test_lint "fixup! prefix not counted"           0 "fixup! $T50"
test_lint "squash! prefix not counted"          0 "squash! $T50"
test_lint "amend! prefix not counted"           0 "amend! $T50"
test_lint "stacked prefixes (squash! fixup!)"   0 "squash! fixup! $T50"

# --- Bullet handling (64b863a) ---
test_reflow "two bullets stay separate" \
"Short title

- bullet one
- bullet two" \
"Short title

- bullet one

- bullet two"

test_reflow "indented continuation preserved" \
"Short title

- bullet with
  continuation" \
"Short title

- bullet with
  continuation"

test_reflow "numbered list bullets stay separate" \
"Short title

1. first item
2. second item" \
"Short title

1. first item

2. second item"

# --- BSD fmt double-space fix (a2ca3dc) ---
test_reflow "no double space after joined period" \
"Short title

First sentence.
Second sentence." \
"Short title

First sentence. Second sentence."

# --- Comment line preservation (c3fe319) ---
test_reflow "git comment lines preserved" \
"Short title

Body text.
# comment line one
# comment line two" \
"Short title

Body text.
# comment line one
# comment line two"

# --- Summary ---
echo
echo "Ran $total tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
