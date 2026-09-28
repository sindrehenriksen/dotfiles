#!/usr/bin/env bash
# D7's additions to claude/session-status.sh (design.md §9(a)): the `pid`
# and `tty` fields on a live session, and the `resolve <token>` mode the
# notes hotkey uses to turn a session name into exactly one session (or
# refuse). From-scratch fixtures only, never real Claude Code state — see
# claude/tests/session-recorder-test.sh for the reader's other fields.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
cleanup() {
    for p in "${live_pids[@]:-}"; do
        [ -n "$p" ] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

CONFIG_DIR="$TMP/config"
STORE_DIR="$TMP/store"
CACHE_DIR="$TMP/cache"
LOG_FILE="$TMP/recorder.log"
PROJ_ESCAPED="-tmp-fixture-project"
PROJ_DIR="$CONFIG_DIR/projects/$PROJ_ESCAPED"
mkdir -p "$CONFIG_DIR/sessions" "$PROJ_DIR" "$STORE_DIR" "$CACHE_DIR"

export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$STORE_DIR"
export CLAUDE_SESSION_READER_CACHE="$CACHE_DIR"
export CLAUDE_SESSION_RECORDER_LOG="$LOG_FILE"

fakebin="$TMP/bin"
mkdir -p "$fakebin"
ln -sf /bin/sleep "$fakebin/claude"

live_pids=()

# Starts a fake, genuinely alive `claude` process and writes its pid file —
# the same fixture shape session-recorder-test.sh uses for its one live
# session, here reused for several so resolve has real candidates to rank.
start_live() {  # sid name updated_at_epoch
    local sid=$1 name=$2 updated_epoch=$3
    # Redirected explicitly rather than left to inherit whatever fd this
    # function's caller happens to be capturing through (start_live is
    # always called as `pid=$(start_live ...)`): an unredirected background
    # job inherits the command substitution's own pipe, and bash then waits
    # for that pipe to close — i.e. for this 60s sleep to finish — before
    # the substitution can complete.
    "$fakebin/claude" 60 >/dev/null 2>&1 &
    local pid=$!
    live_pids+=("$pid")
    sleep 0.15
    local lstart lepoch procstart
    lstart=$(ps -o lstart= -p "$pid" | awk '{$1=$1; print}')
    if [ -r /proc/stat ]; then
        lepoch=$(date -d "$lstart" +%s)
        procstart=$(date -u -d "@$lepoch" +"%a %b %d %T %Y")
    else
        lepoch=$(date -j -f "%a %b %d %T %Y" "$lstart" +%s)
        procstart=$(date -u -r "$lepoch" +"%a %b %d %T %Y")
    fi
    jq -n --arg pid "$pid" --arg sid "$sid" --arg cwd "$PROJ_DIR" \
        --arg procstart "$procstart" --argjson updated "$((updated_epoch * 1000))" \
        --arg name "$name" \
        '{pid:($pid|tonumber), sessionId:$sid, cwd:$cwd, startedAt:$updated, procStart:$procstart,
          name:$name, nameSource:"user", status:"idle", updatedAt:$updated}' \
        > "$CONFIG_DIR/sessions/$pid.json"
    printf '%s' "$pid"
}

now=$(date +%s)

# Sets a file's mtime to an exact epoch second — last_activity is
# max(pid-file updatedAt, transcript mtime), so a transcript created "just
# now" (real wall-clock time) would silently override an intentionally
# backdated updatedAt unless its own mtime is backdated to match.
backdate() {  # file epoch
    if [ -r /proc/stat ]; then
        touch -d "@$2" "$1"
    else
        touch -t "$(date -r "$2" +%Y%m%d%H%M.%S)" "$1"
    fi
}

# --- alpha: one live session, a clean unique user-set name ------------------
tp_alpha="$PROJ_DIR/alpha.jsonl"
: > "$tp_alpha"
jq -cn --arg sid alpha --arg cwd "$PROJ_DIR" --arg tp "$tp_alpha" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start
pid_alpha=$(start_live alpha "Alpha Session" "$now")

# --- bravo: an ended session with a distinct custom-title name -------------
tp_bravo="$PROJ_DIR/bravo.jsonl"
printf '{"type":"custom-title","customTitle":"Bravo Session","sessionId":"bravo"}\n' > "$tp_bravo"
jq -cn --arg sid bravo --arg cwd "$PROJ_DIR" --arg tp "$tp_bravo" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start
jq -cn --arg sid bravo --arg reason prompt_input_exit \
    '{session_id:$sid, reason:$reason}' \
    | "$HERE/../hooks/session-recorder.sh" end

# --- charlie: an ai-title only, matching text never counts as user-set -----
tp_charlie="$PROJ_DIR/charlie.jsonl"
printf '{"type":"ai-title","aiTitle":"Auto Named","sessionId":"charlie"}\n' > "$tp_charlie"
jq -cn --arg sid charlie --arg cwd "$PROJ_DIR" --arg tp "$tp_charlie" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start

# --- dup-older / dup-newer: two live sessions sharing a name, distinct     --
# --- last_activity — resolve must prefer the more recent one --------------
tp_dup1="$PROJ_DIR/dup-older.jsonl"
: > "$tp_dup1"
jq -cn --arg sid dup-older --arg cwd "$PROJ_DIR" --arg tp "$tp_dup1" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start
backdate "$tp_dup1" "$((now - 3600))"
pid_dup_older=$(start_live dup-older "Dup Name" "$((now - 3600))")

tp_dup2="$PROJ_DIR/dup-newer.jsonl"
: > "$tp_dup2"
jq -cn --arg sid dup-newer --arg cwd "$PROJ_DIR" --arg tp "$tp_dup2" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start
backdate "$tp_dup2" "$now"
pid_dup_newer=$(start_live dup-newer "Dup Name" "$now")

# --- tie-a / tie-b: two live sessions, same name, same last_activity — a  --
# --- genuine tie that resolve can never narrow ----------------------------
tp_tie1="$PROJ_DIR/tie-a.jsonl"
: > "$tp_tie1"
jq -cn --arg sid tie-a --arg cwd "$PROJ_DIR" --arg tp "$tp_tie1" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start
backdate "$tp_tie1" "$now"
pid_tie_a=$(start_live tie-a "Tied Name" "$now")

tp_tie2="$PROJ_DIR/tie-b.jsonl"
: > "$tp_tie2"
jq -cn --arg sid tie-b --arg cwd "$PROJ_DIR" --arg tp "$tp_tie2" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' \
    | "$HERE/../hooks/session-recorder.sh" start
backdate "$tp_tie2" "$now"
pid_tie_b=$(start_live tie-b "Tied Name" "$now")

echo "=== pid / tty fields ==="
out=$("$READER")
field() { printf '%s' "$out" | jq -r "select(.id == \"$1\") | $2"; }

assert_eq "alpha: pid matches the live process" "$pid_alpha" "$(field alpha .pid)"
expected_tty=$(ps -o tty= -p "$pid_alpha" | tr -d ' ')
assert_eq "alpha: tty matches ps's own idea of it" "$expected_tty" "$(field alpha .tty)"
assert_eq "bravo: not live, pid is null" "null" "$(field bravo .pid)"
assert_eq "bravo: not live, tty is null" "null" "$(field bravo .tty)"

echo
echo "=== resolve: a unique user-set name ==="
resolved=$("$READER" resolve "Alpha Session")
status=$?
assert_eq "resolve exits 0 on a unique match" "0" "$status"
assert_eq "resolve returns exactly the alpha entry" "alpha" "$(printf '%s' "$resolved" | jq -r '.id')"
assert_eq "resolve's entry carries no internal field" "null" "$(printf '%s' "$resolved" | jq -r '._name_source // "null"')"

echo
echo "=== resolve: an ended session's own custom-title name ==="
resolved=$("$READER" resolve "Bravo Session")
status=$?
assert_eq "resolve exits 0 on the ended session's name" "0" "$status"
assert_eq "resolve returns the bravo entry" "bravo" "$(printf '%s' "$resolved" | jq -r '.id')"

echo
echo "=== resolve: an ai-title never counts as a user-set name ==="
"$READER" resolve "Auto Named" > /dev/null
status=$?
[ "$status" -ne 0 ] && ok "resolve refuses an ai-title match" || bad "resolve refuses an ai-title match (exited 0)"

echo
echo "=== resolve: no match at all lists no candidates and refuses ==="
out_none=$("$READER" resolve "Nobody Here")
status=$?
[ "$status" -ne 0 ] && ok "resolve exits non-zero for no match" || bad "resolve exits non-zero for no match (exited 0)"
assert_eq "resolve prints an empty candidate list" "[]" "$out_none"

echo
echo "=== resolve: prefers live, then the most recent, over a shared name ==="
resolved=$("$READER" resolve "Dup Name")
status=$?
assert_eq "resolve narrows a shared live name to the most recent" "0" "$status"
assert_eq "resolve picks dup-newer, not dup-older" "dup-newer" "$(printf '%s' "$resolved" | jq -r '.id')"

echo
echo "=== resolve: a genuine tie (same name, same activity) stays ambiguous ==="
out_tie=$("$READER" resolve "Tied Name")
status=$?
[ "$status" -ne 0 ] && ok "resolve refuses a genuine tie" || bad "resolve refuses a genuine tie (exited 0)"
tie_count=$(printf '%s' "$out_tie" | jq 'length')
assert_eq "resolve lists both tied candidates" "2" "$tie_count"
tie_ids=$(printf '%s' "$out_tie" | jq -r '.[].id' | sort | tr '\n' ',')
assert_eq "the tied candidates are exactly tie-a and tie-b" "tie-a,tie-b," "$tie_ids"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
