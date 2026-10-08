#!/usr/bin/env bash
# Tests for git-hooks/commit-msg.
# Run: bash git-hooks/test-commit-msg.sh
# Each case maps to a prior fix — see git log -- git-hooks/commit-msg.

set -u
# The hook reads core.commentChar, so keep the caller's own git config out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
HOOK="$(cd "$(dirname "$0")" && pwd)/commit-msg"
pass=0
fail=0
total=0

# Reflow test: hook should pass AND output should match expected verbatim.
# env_pfx is optional, as for test_lint.
test_reflow() {
    local name="$1" input="$2" expected="$3" env_pfx="${4:-}"
    total=$((total + 1))
    local tmp
    tmp=$(mktemp)
    printf '%s\n' "$input" > "$tmp"
    if ! (cd /tmp && env $env_pfx bash "$HOOK" "$tmp") >/dev/null 2>&1; then
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

# Rewrap test: assert the invariants rather than the break points. GNU fmt fills
# to ~93% of -w and BSD fmt fills to the width, so pinning exact line breaks
# makes a case that only passes on the platform it was written on.
test_rewrap() {
    local name="$1" input="$2" compact="${3:-}"
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
    local actual over lines
    actual=$(cat "$tmp")
    over=$(printf '%s\n' "$actual" | awk 'length($0) > 72')
    lines=$(printf '%s\n' "$actual" | tail -n +3 | grep -c .)
    if [ -n "$over" ]; then
        echo "FAIL [$name]: line over 72 columns:"
        printf '%s\n' "$over" | sed 's/^/  /'
        fail=$((fail + 1))
    elif [ "$lines" -lt 2 ]; then
        echo "FAIL [$name]: body did not wrap"
        fail=$((fail + 1))
    elif [ -n "$compact" ] && printf '%s\n' "$actual" | tail -n +3 | grep -q '^$'; then
        echo "FAIL [$name]: a blank line inside the body:"
        printf '%s\n' "$actual" | sed 's/^/  /'
        fail=$((fail + 1))
    elif [ "$(printf '%s\n' "$input" | tr -s '[:space:]' '\n')" \
         != "$(printf '%s\n' "$actual" | tr -s '[:space:]' '\n')" ]; then
        echo "FAIL [$name]: words changed:"
        diff <(printf '%s\n' "$input" | tr -s '[:space:]' '\n') \
             <(printf '%s\n' "$actual" | tr -s '[:space:]' '\n') | sed 's/^/  /'
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

test_reflow "a blank line already between bullets is kept" \
"Short title

- bullet one

- bullet two" \
"Short title

- bullet one

- bullet two"

test_reflow "labelled lists stay compact" \
"Short title

Taken:
- one
- two

Edited:
- three" \
"Short title

Taken:
- one
- two

Edited:
- three"

test_rewrap "long adjacent bullets wrap each on its own, no blank between" \
"Short title

- a first bullet long enough that it has to wrap past the seventy two column limit
- a second bullet also long enough that it has to wrap past the seventy two column limit" \
compact

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

# --- Trailer block held out of reflow (defect: fmt joins adjacent
# trailers when a line is short enough to pull the next one up) ---
test_reflow "short trailer followed by another trailer stays split" \
"Short title

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJ" \
"Short title

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJ"

test_reflow "two already-long trailers stay verbatim" \
"Short title

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJextralongvalueforgoodmeasure" \
"Short title

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJextralongvalueforgoodmeasure"

test_rewrap "final paragraph prose with a colon still reflows" \
"Short title

This explains the change: it fixes a parser bug that used to drop a trailing newline when wrapping long message bodies across multiple lines for readability."

test_rewrap "body with no trailers reflows normally" \
"Short title

This is a perfectly ordinary commit body with no trailers in it at all, just a normal sentence that is long enough to need wrapping at seventy two columns."

test_reflow "trailer block preceded by bullets: both mechanisms apply" \
"Short title

- bullet one
- bullet two

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJ" \
"Short title

- bullet one
- bullet two

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJ"

# --- Comment-char lines stay where they are. Git strips them only in
# its "strip" cleanup mode (the editor); with -F or -m the default is
# "whitespace", so a line starting with # is content. Either way the
# hook must not move it or join it into a neighbouring paragraph. ---
test_reflow "mid-body # line stays in place, neighbours reflow apart" \
"Short title

First line
joined.
#42 is content when committing with -F.
Second line
joined too." \
"Short title

First line joined.
#42 is content when committing with -F.
Second line joined too."

test_reflow "# line directly before trailers stays before them" \
"Short title

Body text.

#42 tracks the follow-up.
Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJ" \
"Short title

Body text.

#42 tracks the follow-up.
Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01SWWZ7hbheeGQfnc25rACWJ"

test_reflow "trailing editor template stays at the end, verbatim" \
"Short title

Body line one
continues here.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch main" \
"Short title

Body line one continues here.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch main"

SCISSORS_TAIL="# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
# Everything below it will be ignored.
diff --git a/f.sh b/f.sh
index 0000000..1111111 100644
--- a/f.sh
+++ b/f.sh
@@ -1,2 +1,2 @@
 # a shell comment in the diff context
-echo old
+echo a new line that is deliberately longer than seventy-two columns wide"
test_reflow "scissors line and the diff after it are verbatim" \
"Short title

Body line one
continues here.
# Please enter the commit message for your changes.
$SCISSORS_TAIL" \
"Short title

Body line one continues here.
# Please enter the commit message for your changes.
$SCISSORS_TAIL"

test_reflow "a list above the scissors stays compact, the diff verbatim" \
"Short title

Changes:
- one
- two
$SCISSORS_TAIL" \
"Short title

Changes:
- one
- two
$SCISSORS_TAIL"

test_reflow "custom core.commentChar is respected" \
"Short title

First line
joined.
; mid-body comment
Second line,
#42 included.

; Please enter the commit message for your changes." \
"Short title

First line joined.
; mid-body comment
Second line, #42 included.

; Please enter the commit message for your changes." \
"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.commentChar GIT_CONFIG_VALUE_0=;"

test_reflow "core.commentChar=auto takes the template's character" \
"Short title

Fixes
#42.

; Please enter the commit message for your changes." \
"Short title

Fixes #42.

; Please enter the commit message for your changes." \
"GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.commentChar GIT_CONFIG_VALUE_0=auto"

# --- Summary ---
echo
echo "Ran $total tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
