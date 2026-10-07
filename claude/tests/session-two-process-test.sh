#!/usr/bin/env bash
# One session id open in two Claude Code processes at once (a session
# resumed in a second window while the first still runs): what the recorder
# writes for each process, and what claude/session-status.sh concludes from
# it. Each "process" is a real, alive stand-in named `claude` (bash under
# that name) that fires the recorder the way a hook does, as its own child,
# so the recorder's pid lookup is exercised for real. From-scratch fixtures
# only, never real Claude Code state.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORDER="$HERE/../hooks/session-recorder.sh"
READER="$HERE/../session-status.sh"

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
# Stand-ins are started inside `$(...)`, so they are not this shell's
# children: their pids go to a file for cleanup, and exits are polled rather
# than waited on.
cleanup() {
    local p
    for p in $(cat "$TMP/spawned" 2>/dev/null); do
        kill "$p" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

CONFIG_DIR="$TMP/config"
STORE_DIR="$TMP/store"
PROJ_DIR="$CONFIG_DIR/projects/-tmp-fixture-project"
mkdir -p "$CONFIG_DIR/sessions" "$PROJ_DIR" "$STORE_DIR" "$TMP/cache" "$TMP/ctl"

export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$STORE_DIR"
export CLAUDE_SESSION_READER_CACHE="$TMP/cache"
export CLAUDE_SESSION_RECORDER_LOG="$TMP/recorder.log"

fakebin="$TMP/bin"
mkdir -p "$fakebin"
ln -sf "$(command -v bash)" "$fakebin/claude"

wait_gone() { # pid, up to ~5s
    local i
    for i in $(seq 1 100); do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.05
    done
    return 1
}

wait_for() { # file, up to ~5s
    local i
    for i in $(seq 1 100); do
        [ -e "$1" ] && return 0
        sleep 0.05
    done
    return 1
}

# Starts a stand-in Claude Code process for session $1 and prints its pid.
# It writes its own pid file first (as Claude Code does), then waits for
# `fire_start`, runs the SessionStart hook, waits for `fire_end`, runs the
# SessionEnd hook with reason $2 and exits. The trailing `:` keeps bash from
# exec'ing its last command, which would rename the process.
spawn_claude() { # sid end_reason
    local sid=$1 reason=$2 tag
    tag="$TMP/ctl/$sid-$RANDOM$RANDOM"
    jq -cn --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg tp "$PROJ_DIR/$sid.jsonl" \
        '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"resume", hook_event_name:"SessionStart"}' \
        > "$tag.start.json"
    jq -cn --arg sid "$sid" --arg reason "$reason" \
        '{session_id:$sid, reason:$reason, hook_event_name:"SessionEnd"}' > "$tag.end.json"
    "$fakebin/claude" -c '
        while [ ! -e "$1.go" ] && [ ! -e "$1.stop" ]; do sleep 0.05; done
        [ -e "$1.go" ] && "$2" start < "$1.start.json" > "$1.start.out"
        : > "$1.started"
        while [ ! -e "$1.stop" ]; do sleep 0.05; done
        "$2" end < "$1.end.json"
        :' _ "$tag" "$RECORDER" > /dev/null 2>&1 &
    local pid=$!
    echo "$pid" >> "$TMP/spawned"
    printf '%s\n' "$tag" > "$TMP/ctl/$pid.tag"
    sleep 0.15
    local lstart lepoch procstart now_ms
    lstart=$(ps -o lstart= -p "$pid" | awk '{$1=$1; print}')
    if [ -r /proc/stat ]; then
        lepoch=$(date -d "$lstart" +%s)
        procstart=$(date -u -d "@$lepoch" +"%a %b %d %T %Y")
    else
        lepoch=$(date -j -f "%a %b %d %T %Y" "$lstart" +%s)
        procstart=$(date -u -r "$lepoch" +"%a %b %d %T %Y")
    fi
    now_ms=$(( $(date +%s) * 1000 ))
    jq -n --argjson pid "$pid" --arg sid "$sid" --arg cwd "$PROJ_DIR" --arg procstart "$procstart" \
        --argjson now "$now_ms" \
        '{pid:$pid, sessionId:$sid, cwd:$cwd, startedAt:$now, procStart:$procstart,
          nameSource:"none", status:"idle", updatedAt:$now}' \
        > "$CONFIG_DIR/sessions/$pid.json"
    printf '%s' "$pid"
}
tag_of() { cat "$TMP/ctl/$1.tag"; }
fire_start() { local t; t=$(tag_of "$1"); : > "$t.go"; wait_for "$t.started"; }
# A clean exit: the SessionEnd hook runs, the process exits, and Claude Code
# removes its pid file.
fire_end() {
    local t; t=$(tag_of "$1"); : > "$t.stop"
    wait_gone "$1"
    rm -f "$CONFIG_DIR/sessions/$1.json"
}
# A crash: no SessionEnd, and the pid file is left behind.
crash() { kill -9 "$1" 2>/dev/null; wait_gone "$1"; }

read_field() { "$READER" | jq -r --arg id "$1" "select(.id == \$id) | $2"; }

echo "=== the recorder records the hook's own Claude Code pid ==="
: > "$PROJ_DIR/twin.jsonl"
p1=$(spawn_claude twin other)
fire_start "$p1"
assert_eq "start event carries the pid of the process that fired the hook" "$p1" \
    "$(jq -rs 'map(select(.event=="start")) | last | .pid' "$STORE_DIR/twin.jsonl")"

echo "=== two live processes on one session ==="
p2=$(spawn_claude twin prompt_input_exit)
fire_start "$p2"
assert_eq "the first start warned of nothing" "" "$(cat "$(tag_of "$p1").start.out")"
p1_tty=$(ps -o tty= -p "$p1" | tr -d ' ')
case "$p1_tty" in ''|'?'|'??') p1_tty="no tty" ;; esac
assert_eq "the second start tells the user where the session is already open" \
    "This session is already open in another Claude Code process ($p1_tty, pid $p1). Both write the same transcript; close one of them." \
    "$(jq -r '.systemMessage' "$(tag_of "$p2").start.out")"
assert_eq "both live: live" "true" "$(read_field twin .live)"
assert_eq "both live: duplicate_pids (two live pid files)" "true" "$(read_field twin .duplicate_pids)"
assert_eq "both live: not left open" "false" "$(read_field twin .left_open)"

echo "=== the first process exits; the second still runs ==="
fire_end "$p1"
assert_eq "end event carries the exiting process's pid" "$p1" \
    "$(jq -rs 'map(select(.event=="end")) | last | .pid' "$STORE_DIR/twin.jsonl")"
assert_eq "still live" "true" "$(read_field twin .live)"
assert_eq "not ended while the other process runs" "false" "$(read_field twin .ended)"
assert_eq "no end_reason while not ended" "null" "$(read_field twin .end_reason)"
assert_eq "no end_deliberate while not ended" "null" "$(read_field twin .end_deliberate)"
assert_eq "not left open while the other process runs" "false" "$(read_field twin .left_open)"
assert_eq "pid is the process still running" "$p2" "$(read_field twin .pid)"
assert_eq "duplicate_pids clears once only one pid file is left" "false" "$(read_field twin .duplicate_pids)"

echo "=== the second process exits too ==="
fire_end "$p2"
assert_eq "ended once no process is left" "true" "$(read_field twin .ended)"
assert_eq "end_reason is the last exit's" "prompt_input_exit" "$(read_field twin .end_reason)"
assert_eq "status ended" "ended" "$(read_field twin .status)"
assert_eq "the last exit was deliberate" "true" "$(read_field twin .end_deliberate)"
assert_eq "not left open" "false" "$(read_field twin .left_open)"

echo "=== an end ends only its own process: the other one later crashes ==="
: > "$PROJ_DIR/split.jsonl"
q1=$(spawn_claude split other)
fire_start "$q1"
q2=$(spawn_claude split other)
fire_start "$q2"
fire_end "$q1"
crash "$q2"
assert_eq "not live" "false" "$(read_field split .live)"
assert_eq "not ended: the crashed process never recorded an end" "false" "$(read_field split .ended)"
assert_eq "status orphaned" "orphaned" "$(read_field split .status)"
assert_eq "left open: the crashed process never ended" "true" "$(read_field split .left_open)"

echo "=== records from before events carried a pid: liveness still wins ==="
# The shape of the session that prompted this: two starts and an end, none
# with a pid, while one process still runs. Its start predates pids, so it
# only ever fires its end hook.
: > "$PROJ_DIR/legacy.jsonl"
r1=$(spawn_claude legacy prompt_input_exit)
legacy_start() { # sid
    jq -cn --arg sid "$1" --arg cwd "$PROJ_DIR" --arg tp "$PROJ_DIR/$1.jsonl" \
        '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"resume"}' | "$RECORDER" start
}
legacy_start legacy
legacy_start legacy
jq -cn '{session_id:"legacy", reason:"other"}' | "$RECORDER" end
assert_eq "no pid recorded without a hook" "0" \
    "$(jq -rs 'map(select(.pid != null)) | length' "$STORE_DIR/legacy.jsonl")"
assert_eq "live" "true" "$(read_field legacy .live)"
assert_eq "not ended while a process is live" "false" "$(read_field legacy .ended)"
assert_eq "status from the live pid file" "idle" "$(read_field legacy .status)"
fire_end "$r1"
assert_eq "ended once the live process exits" "true" "$(read_field legacy .ended)"

echo "=== an end with a pid closes a start recorded without one ==="
: > "$PROJ_DIR/upgrade.jsonl"
u1=$(spawn_claude upgrade prompt_input_exit)
legacy_start upgrade
fire_end "$u1"
assert_eq "ended" "true" "$(read_field upgrade .ended)"
assert_eq "end_reason from the pid-carrying end" "prompt_input_exit" "$(read_field upgrade .end_reason)"

echo "=== a close, then the process's own SessionEnd: the first end wins ==="
: > "$PROJ_DIR/closed.jsonl"
s1=$(spawn_claude closed other)
fire_start "$s1"
"$RECORDER" close closed
fire_end "$s1"
assert_eq "end_reason stays closed-by-pass" "closed-by-pass" "$(read_field closed .end_reason)"
assert_eq "a close is deliberate" "true" "$(read_field closed .end_deliberate)"
assert_eq "a closed session is not left open" "false" "$(read_field closed .left_open)"

echo "=== a close from outside still wins over runs left open before it ==="
# Event logs in the shapes real sessions had when a close was followed by
# the process's own SessionEnd: earlier runs that never recorded an end
# (starts with no pid, a SIGKILL, a shutdown) used to take that SessionEnd,
# which then overwrote the close as the session's end.
events() { # sid, then one event per argument
    local sid=$1
    shift
    printf '%s\n' "$@" > "$STORE_DIR/$sid.jsonl"
    : > "$PROJ_DIR/$sid.jsonl"
}
start_ev() { # source [pid]
    jq -cn --arg s "$1" --arg p "${2:-}" --arg cwd "$PROJ_DIR" \
        '{event:"start", time:1, source:$s, cwd:$cwd, boot:"1"} + (if $p == "" then {} else {pid: ($p | tonumber)} end)'
}
end_ev() { # reason [pid]
    jq -cn --arg r "$1" --arg p "${2:-}" \
        '{event:"end", time:2, reason:$r} + (if $p == "" then {} else {pid: ($p | tonumber)} end)'
}
expect_closed() { # sid desc
    assert_eq "$2: end_reason is the close" "closed-by-pass" "$(read_field "$1" .end_reason)"
    assert_eq "$2: deliberate" "true" "$(read_field "$1" .end_deliberate)"
    assert_eq "$2: not left open" "false" "$(read_field "$1" .left_open)"
}
events resumed-no-pid "$(start_ev resume)" "$(start_ev resume)" "$(start_ev resume)" \
    "$(end_ev closed-by-pass)" "$(end_ev other 991001)"
expect_closed resumed-no-pid "latest start had no pid"
events compacted "$(start_ev resume)" "$(start_ev resume)" "$(end_ev other)" \
    "$(start_ev compact 991002)" "$(end_ev closed-by-pass)" "$(end_ev other 991002)"
expect_closed compacted "latest start had a pid, earlier ones none"
events compacted-same-pid "$(start_ev startup 991003)" "$(start_ev compact 991003)" \
    "$(end_ev closed-by-pass)" "$(end_ev other 991003)"
expect_closed compacted-same-pid "the same process recorded two starts"
events late-close "$(start_ev resume)" "$(start_ev startup 991004)" "$(end_ev other 991004)" "$(end_ev closed-by-pass)"
assert_eq "a close after the process already ended does not replace its end" "other" "$(read_field late-close .end_reason)"
assert_eq "so that session is still left open" "true" "$(read_field late-close .left_open)"
events stale-then-exit "$(start_ev startup 991005)" "$(start_ev resume)" "$(end_ev prompt_input_exit 991006)"
assert_eq "an end with an unrecorded pid closes the latest run, never an older one" \
    "prompt_input_exit" "$(read_field stale-then-exit .end_reason)"
assert_eq "...so the session is ended" "true" "$(read_field stale-then-exit .ended)"

echo "=== recorder never logged an error ==="
if [ -s "$TMP/recorder.log" ]; then
    bad "recorder log is empty"
    cat "$TMP/recorder.log"
else
    ok "recorder log is empty"
fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
