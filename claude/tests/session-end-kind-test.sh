#!/usr/bin/env bash
# How a session's end is classified: whether claude/session-status.sh calls
# it deliberate (`end_deliberate`), and whether the session counts as left
# open (`left_open`, what a reopen after a restart keys off).
#
# The hook inputs under fixtures/session-end/ are the ones Claude Code
# 2.1.292 handed its SessionStart and SessionEnd hooks when an interactive
# session was ended each way at an idle prompt, in a pty driven from a
# script, with only the session id, paths and prompt id replaced:
#   end-ctrl-c-twice   Ctrl+C, Ctrl+C
#   end-ctrl-d         Ctrl+D
#   end-exit-command   /exit
#   end-clear          /clear (the session it moves away from)
#   end-tab-close      the pty's master closed under the shell (the kernel
#                      hangs up the terminal's processes)
#   end-app-quit       Ghostty's own teardown, emulated: SIGHUP to the
#                      shell's process group until it exits, then the
#                      master closed; three sessions torn down together
#   end-sighup         SIGHUP to the claude process
#   end-sigterm        SIGTERM to the claude process
# SIGKILL ran no SessionEnd hook at all, so it has no fixture.
#
# Each case is fed through the recorder by a stand-in process named
# `claude` (bash under that name) that runs the hooks as its own children,
# as Claude Code does. From-scratch state only, never real Claude Code
# state.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER="$HERE/../hooks/session-recorder.sh"
READER="$HERE/../session-status.sh"
FX="$HERE/fixtures/session-end"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

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

CONFIG_DIR="$TMP/config"
STORE_DIR="$TMP/store"
mkdir -p "$CONFIG_DIR/sessions" "$CONFIG_DIR/projects" "$STORE_DIR" "$TMP/cache" "$TMP/in"

export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$STORE_DIR"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"
unset DESK_HEADLESS

fakebin="$TMP/bin"
mkdir -p "$fakebin"
ln -sf "$(command -v bash)" "$fakebin/claude"

# One run of session $1 in a stand-in process: the SessionStart hook with
# the observed startup input ($2 "resume" reports the source a resume
# does), then, if $3 names one, the SessionEnd hook with that fixture (no
# $3: the process dies without one, as a SIGKILL leaves it). $4, if given,
# is a jq filter applied to the end input. Beyond those, only the session
# id is changed.
run() { # sid startup|resume [end-fixture] [end-filter]
    local sid=$1 source=$2 end=${3:-} filter=${4:-.} n=$RANDOM$RANDOM
    jq -c --arg sid "$sid" --arg source "$source" '.session_id = $sid | .source = $source' \
        "$FX/start-startup.json" > "$TMP/in/$n.start"
    : > "$TMP/in/$n.end"
    [ -n "$end" ] && jq -c --arg sid "$sid" ".session_id = \$sid | $filter" "$FX/$end.json" > "$TMP/in/$n.end"
    "$fakebin/claude" -c '
        "$1" start < "$2" > /dev/null
        [ -s "$3" ] && "$1" end < "$3"
        :' _ "$RECORDER" "$TMP/in/$n.start" "$TMP/in/$n.end"
}

read_field() { "$READER" | jq -r --arg id "$1" "select(.id == \$id) | $2"; }

# expect <sid> <ended> <end_reason> <end_deliberate> <left_open>
expect() {
    local sid=$1 line
    line=$("$READER" | jq -c --arg id "$sid" 'select(.id == $id) | [.ended, .end_reason, .end_deliberate, .left_open]')
    assert_eq "$sid: ended, end_reason, end_deliberate, left_open" "[$2,$3,$4,$5]" "$line"
}

echo "=== each probed way of ending a session ==="
run ctrl-c-twice startup end-ctrl-c-twice
expect ctrl-c-twice true '"prompt_input_exit"' true false
run ctrl-d startup end-ctrl-d
expect ctrl-d true '"prompt_input_exit"' true false
run exit-command startup end-exit-command
expect exit-command true '"prompt_input_exit"' true false
run clear startup end-clear
expect clear true '"clear"' true false
run tab-close startup end-tab-close
expect tab-close true '"other"' false true
run app-quit startup end-app-quit
expect app-quit true '"other"' false true
run sighup startup end-sighup
expect sighup true '"other"' false true
run sigterm startup end-sigterm
expect sigterm true '"other"' false true
run sigkill startup
expect sigkill false null null true

echo "=== reasons nobody observed ==="
run unknown-reason startup end-ctrl-c-twice '.reason = "some_later_reason"'
expect unknown-reason true '"some_later_reason"' false true
run no-reason startup end-ctrl-c-twice 'del(.reason)'
expect no-reason true '"other"' false true

echo "=== the latest run decides ==="
run shutdown-then-done startup end-sigterm
run shutdown-then-done resume end-ctrl-c-twice
expect shutdown-then-done true '"prompt_input_exit"' true false
run done-then-killed startup end-ctrl-c-twice
run done-then-killed resume
expect done-then-killed false null null true
run done-then-hup startup end-ctrl-c-twice
run done-then-hup resume end-sighup
expect done-then-hup true '"other"' false true

echo "=== a scheduled call is never left open ==="
DESK_HEADLESS=1 run desk-call startup end-sigterm
assert_eq "desk-call: recorded as desk-run" "desk-run" "$(read_field desk-call .source)"
expect desk-call true '"other"' false false
DESK_HEADLESS=1 run desk-call-resumed startup end-ctrl-c-twice
run desk-call-resumed resume end-tab-close
expect desk-call-resumed true '"other"' false true

echo "=== recorder never logged an error ==="
if [ -s "$TMP/recorder.log" ]; then
    bad "recorder log is empty"
    cat "$TMP/recorder.log"
else
    ok "recorder log is empty"
fi

printf '\n=== summary: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
