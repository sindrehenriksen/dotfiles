#!/usr/bin/env bash
# Exercises claude/hooks/session-recorder.sh and claude/session-status.sh
# against a from-scratch fixture (invented session ids and names, a fake
# config dir) — never against real Claude Code state. The last section
# points the reader at this machine's real ~/.claude-work instead, but stays
# read-only and prints counts only, never names.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/platform.sh
source "$HERE/lib/platform.sh"
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
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

CONFIG_DIR="$TMP/config"
STORE_DIR="$TMP/store"
CACHE_DIR="$TMP/cache"
LOG_FILE="$TMP/recorder.log"
PROJ_ESCAPED="-tmp-fixture-project"
PROJ_DIR="$CONFIG_DIR/projects/$PROJ_ESCAPED"
mkdir -p "$CONFIG_DIR/sessions" "$PROJ_DIR/subagents" "$STORE_DIR" "$CACHE_DIR"

export CLAUDE_CONFIG_DIR="$CONFIG_DIR"
export CLAUDE_SESSION_STORE="$STORE_DIR"
export CLAUDE_SESSION_READER_CACHE="$CACHE_DIR"
export CLAUDE_SESSION_RECORDER_LOG="$LOG_FILE"

rec_start() {  # sid cwd transcript source
    jq -cn --arg sid "$1" --arg cwd "$2" --arg tp "$3" --arg src "$4" \
        '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:$src}' \
        | "$RECORDER" start
}
rec_end() {  # sid reason
    jq -cn --arg sid "$1" --arg reason "$2" '{session_id:$sid, reason:$reason}' \
        | "$RECORDER" end
}

echo "=== recorder scenarios ==="

# --- sess-a: clean exit (start -> end prompt_input_exit) -------------------
tp_a="$PROJ_DIR/sess-a.jsonl"
printf '{"type":"custom-title","customTitle":"Invented Name A","sessionId":"sess-a"}\n' > "$tp_a"
rec_start sess-a "$PROJ_DIR" "$tp_a" startup
rec_end sess-a prompt_input_exit
log_a="$STORE_DIR/sess-a.jsonl"
assert_eq "sess-a: two events logged" "2" "$(wc -l < "$log_a" | tr -d ' ')"
assert_eq "sess-a: end reason recorded" "prompt_input_exit" \
    "$(jq -rs 'map(select(.event=="end")) | last | .reason' "$log_a")"

# --- sess-b: killed, no end event ------------------------------------------
tp_b="$PROJ_DIR/sess-b.jsonl"
printf '{"type":"ai-title","aiTitle":"Auto Title B","sessionId":"sess-b"}\n' > "$tp_b"
rec_start sess-b "$PROJ_DIR" "$tp_b" startup
log_b="$STORE_DIR/sess-b.jsonl"
assert_eq "sess-b: one start event logged" "1" \
    "$(jq -rs 'map(select(.event=="start")) | length' "$log_b")"
assert_eq "sess-b: no end event logged" "0" \
    "$(jq -rs 'map(select(.event=="end")) | length' "$log_b")"

# --- sess-c: end(other) then a fresh start makes it live again -------------
tp_c="$PROJ_DIR/sess-c.jsonl"
: > "$tp_c"   # no title events yet
rec_start sess-c "$PROJ_DIR" "$tp_c" startup
rec_end sess-c other
rec_start sess-c "$PROJ_DIR" "$tp_c" resume
log_c="$STORE_DIR/sess-c.jsonl"
assert_eq "sess-c: three events (start, end, start)" "3" "$(wc -l < "$log_c" | tr -d ' ')"

# A real, alive process claiming to be `claude`, for the liveness join.
fakebin="$TMP/bin"; mkdir -p "$fakebin"
ln -sf /bin/sleep "$fakebin/claude"
"$fakebin/claude" 60 &
c_pid=$!
sleep 0.2
c_procstart=$(proc_start_of "$c_pid")
now_ms=$(( $(date +%s) * 1000 ))
jq -n --arg pid "$c_pid" --arg sid "sess-c" --arg cwd "$PROJ_DIR" \
    --arg procstart "$c_procstart" --argjson updatedAt "$now_ms" --argjson startedAt "$now_ms" \
    '{pid:($pid|tonumber), sessionId:$sid, cwd:$cwd, startedAt:$startedAt, procStart:$procstart,
      name:"Invented Name C", nameSource:"user", status:"busy", updatedAt:$updatedAt}' \
    > "$CONFIG_DIR/sessions/$c_pid.json"

# --- sess-d: close, then a later SessionEnd — first end wins ---------------
tp_d="$PROJ_DIR/sess-d.jsonl"
: > "$tp_d"
rec_start sess-d "$PROJ_DIR" "$tp_d" startup
"$RECORDER" close sess-d
rec_end sess-d other
log_d="$STORE_DIR/sess-d.jsonl"
# Both ends are recorded; the reader's sess-d assertions below check that
# the first one is the one that counts.
assert_eq "sess-d: the close and the later SessionEnd are both recorded" "closed-by-pass,other" \
    "$(jq -rs 'map(select(.event=="end") | .reason) | join(",")' "$log_d")"

# --- sess-g: close, then close-failed — a survivor's own event -------------
tp_g="$PROJ_DIR/sess-g.jsonl"
: > "$tp_g"
rec_start sess-g "$PROJ_DIR" "$tp_g" startup
"$RECORDER" close sess-g
"$RECORDER" close-failed sess-g
log_g="$STORE_DIR/sess-g.jsonl"
assert_eq "sess-g: three events (start, end, close-failed)" "3" "$(wc -l < "$log_g" | tr -d ' ')"
assert_eq "sess-g: the 'end' event is untouched (still closed-by-pass)" "closed-by-pass" \
    "$(jq -rs 'map(select(.event=="end")) | last | .reason' "$log_g")"
assert_eq "sess-g: exactly one close-failed event" "1" \
    "$(jq -rs 'map(select(.event=="close-failed")) | length' "$log_g")"

# --- sess-h: DESK_HEADLESS=1 tags source desk-run regardless of the hook's
# own reported source ----------------------------------
tp_h="$PROJ_DIR/sess-h.jsonl"
: > "$tp_h"
DESK_HEADLESS=1 rec_start sess-h "$PROJ_DIR" "$tp_h" startup
log_h="$STORE_DIR/sess-h.jsonl"
assert_eq "sess-h: DESK_HEADLESS overrides source to desk-run" "desk-run" \
    "$(jq -rs 'map(select(.event=="start")) | last | .source' "$log_h")"

# --- sess-i: without DESK_HEADLESS, the hook's own reported source stands --
tp_i="$PROJ_DIR/sess-i.jsonl"
: > "$tp_i"
rec_start sess-i "$PROJ_DIR" "$tp_i" startup
log_i="$STORE_DIR/sess-i.jsonl"
assert_eq "sess-i: no DESK_HEADLESS, source is the hook's own" "startup" \
    "$(jq -rs 'map(select(.event=="start")) | last | .source' "$log_i")"

# --- sess-e: rename history (older_names) -----------------------------------
tp_e="$PROJ_DIR/sess-e.jsonl"
{
    printf '{"type":"custom-title","customTitle":"First Name E","sessionId":"sess-e"}\n'
    printf '{"type":"custom-title","customTitle":"Second Name E","sessionId":"sess-e"}\n'
} > "$tp_e"
rec_start sess-e "$PROJ_DIR" "$tp_e" startup

# --- sess-f: pre-recorder transcript, no event-log record at all ----------
tp_f="$PROJ_DIR/sess-f.jsonl"
printf '{"type":"ai-title","aiTitle":"Old Auto F","sessionId":"sess-f"}\n' > "$tp_f"
# deliberately: no rec_start call, so $STORE_DIR/sess-f.jsonl never exists.

# --- a subagent transcript one level deeper: must never surface -------------
printf '{"type":"ai-title","aiTitle":"Ghost","sessionId":"sess-ghost"}\n' \
    > "$PROJ_DIR/subagents/sess-ghost.jsonl"

# --- sess-w: resumed from another directory, the hook names a transcript in
# that directory's project folder that doesn't exist; the real one stays in
# the folder it was started in ----------------------------------------------
tp_w="$PROJ_DIR/sess-w.jsonl"
printf '{"type":"ai-title","aiTitle":"Auto W","sessionId":"sess-w"}\n' > "$tp_w"
rec_start sess-w "$PROJ_DIR" "$tp_w" startup
rec_start sess-w /tmp/fixture "$CONFIG_DIR/projects/-tmp-fixture/sess-w.jsonl" resume

# --- sess-x: a transcript under a config dir the reader doesn't scan (a
# desk-run call's own) -------------------------------------------------------
tp_x="$TMP/other-config/projects/-tmp-x/sess-x.jsonl"
mkdir -p "$(dirname "$tp_x")"
: > "$tp_x"
rec_start sess-x /tmp/x "$tp_x" startup

echo "=== recorder never logged an error ==="
if [ -s "$LOG_FILE" ]; then
    bad "recorder log is empty (nothing swallowed)"
    cat "$LOG_FILE"
else
    ok "recorder log is empty (nothing swallowed)"
fi

echo "=== reader on the fixture dir ==="
out=$("$READER")
echo "$out" | while IFS= read -r line; do
    printf '%s' "$line" | jq empty || echo "INVALID JSON: $line"
done

get() { printf '%s' "$out" | jq -c "select(.id == \"$1\")"; }
field() { printf '%s' "$out" | jq -r "select(.id == \"$1\") | $2"; }

assert_eq "sess-a: name from custom-title" "Invented Name A" "$(field sess-a .name)"
assert_eq "sess-a: status ended" "ended" "$(field sess-a .status)"
assert_eq "sess-a: ended true" "true" "$(field sess-a .ended)"
assert_eq "sess-a: end_reason" "prompt_input_exit" "$(field sess-a .end_reason)"
assert_eq "sess-a: not live" "false" "$(field sess-a .live)"
assert_eq "sess-a: close_failed false (never a close-failed event)" "false" "$(field sess-a .close_failed)"
assert_eq "sess-a: close_failed_at null" "null" "$(field sess-a .close_failed_at)"
assert_eq "sess-a: source from its start event" "startup" "$(field sess-a .source)"

assert_eq "sess-b: name from ai-title fallback" "Auto Title B" "$(field sess-b .name)"
assert_eq "sess-b: status orphaned (start, no end, not live)" "orphaned" "$(field sess-b .status)"
assert_eq "sess-b: has_start_event" "true" "$(field sess-b .has_start_event)"
assert_eq "sess-b: name_source ai_or_none (never a custom title)" "ai_or_none" "$(field sess-b .name_source)"

assert_eq "sess-c: live via matching pid file" "true" "$(field sess-c .live)"
assert_eq "sess-c: status from pid file (busy)" "busy" "$(field sess-c .status)"
assert_eq "sess-c: ended false (resumed after the end)" "false" "$(field sess-c .ended)"
assert_eq "sess-c: name falls back to live pid file (nameSource user)" "Invented Name C" "$(field sess-c .name)"
assert_eq "sess-c: source is the latest start's own (resume, not the first startup)" "resume" "$(field sess-c .source)"

assert_eq "sess-d: end_reason survives as closed-by-pass" "closed-by-pass" "$(field sess-d .end_reason)"
assert_eq "sess-d: status ended" "ended" "$(field sess-d .status)"
assert_eq "sess-d: close_failed false (SIGTERM was never followed by close-failed)" "false" "$(field sess-d .close_failed)"

assert_eq "sess-g: a close it survived does not end it" "false null true" \
    "$(field sess-g '"\(.ended) \(.end_reason) \(.left_open)"')"
assert_eq "sess-g: close_failed true (the SIGTERM'd session survived)" "true" "$(field sess-g .close_failed)"
assert_eq "sess-g: close_failed_at is a number" "true" "$(field sess-g '(.close_failed_at | type == "number")')"

assert_eq "sess-e: name is the latest rename" "Second Name E" "$(field sess-e .name)"
assert_eq "sess-e: name_source user (a custom title)" "user" "$(field sess-e .name_source)"
assert_eq "sess-e: older_names carries the earlier one" '["First Name E"]' \
    "$(printf '%s' "$out" | jq -c 'select(.id == "sess-e") | .older_names')"

assert_eq "sess-f: no recorder events at all -> unknown" "unknown" "$(field sess-f .status)"
assert_eq "sess-f: has_start_event false" "false" "$(field sess-f .has_start_event)"
assert_eq "sess-f: name still comes from its transcript's ai-title" "Old Auto F" "$(field sess-f .name)"
assert_eq "sess-f: source null (no recorder event at all)" "null" "$(field sess-f .source)"

assert_eq "sess-h: reader surfaces the DESK_HEADLESS-overridden source" "desk-run" "$(field sess-h .source)"
assert_eq "sess-i: reader surfaces the hook's own source untouched" "startup" "$(field sess-i .source)"

assert_eq "subagent transcript never surfaces as its own session" "" "$(get sess-ghost)"

assert_eq "sess-w: transcript_path is the one that exists, not the hook's" "$tp_w" "$(field sess-w .transcript_path)"
assert_eq "sess-x: an existing recorded path outside the scanned config dir stands" "$tp_x" "$(field sess-x .transcript_path)"
assert_eq "sess-b: an existing recorded path stands" "$tp_b" "$(field sess-b .transcript_path)"

echo "=== procStart in either platform's shape, and a reused pid ==="
c_pidfile="$CONFIG_DIR/sessions/$c_pid.json"
cp "$c_pidfile" "$TMP/c-pidfile.json"
with_procstart() { # procStart -> sess-c's liveness with it
    jq --arg ps "$1" '.procStart = $ps' "$TMP/c-pidfile.json" > "$c_pidfile"
    "$READER" | jq -r 'select(.id == "sess-c") | .live'
}
assert_eq "a UTC ctime procStart (macOS's shape) that matches the process: live" "true" \
    "$(with_procstart "$(proc_start_ctime_of "$c_pid")")"
assert_eq "a ctime procStart years off (a reused pid): not live" "false" \
    "$(with_procstart "Mon Jan  1 00:00:00 2024")"
if [ -r /proc/stat ]; then
    assert_eq "a clock-tick procStart (Linux's shape) that matches: live" "true" "$(with_procstart "$c_procstart")"
    assert_eq "a clock-tick procStart one tick off (a reused pid): not live" "false" \
        "$(with_procstart "$((c_procstart + 1))")"
fi
cp "$TMP/c-pidfile.json" "$c_pidfile"

echo "=== reader cache actually caches (second run reuses it, doesn't grow) ==="
cache_files_before=$(find "$CACHE_DIR" -type f | wc -l | tr -d ' ')
"$READER" > /dev/null
cache_files_after=$(find "$CACHE_DIR" -type f | wc -l | tr -d ' ')
assert_eq "cache file count stable across a second run" "$cache_files_before" "$cache_files_after"

echo "=== prune keeps a record whose recorded path is wrong but whose transcript exists ==="
# A stale boot marker makes the next start run the once-per-boot prune.
printf 'stale' > "$STORE_DIR/.last-pruned-boot"
jq -cn '{event:"start", time:1, source:"startup", cwd:"/gone", transcript_path:"/nonexistent/projects/-gone/sess-gone.jsonl", boot:"0"}' \
    > "$STORE_DIR/sess-gone.jsonl"
# Every record so far is old; one written moments ago (another session
# starting at the same time, its transcript not on disk yet) is not.
touch -t 202001010000 "$STORE_DIR"/*.jsonl
jq -cn '{event:"start", time:1, source:"startup", cwd:"/fresh", transcript_path:"/nonexistent/projects/-fresh/sess-fresh.jsonl", boot:"0"}' \
    > "$STORE_DIR/sess-fresh.jsonl"
# A jq shim notes the marker each time the scan reads a record, so a start
# that begins mid-scan can be shown to skip it.
mkdir -p "$TMP/shim"
cat > "$TMP/shim/jq" <<SHIM
#!/usr/bin/env bash
case "\$*" in *'select(.event=="start") | .transcript_path'*) cat "$STORE_DIR/.last-pruned-boot" >> "$TMP/marker-during-scan"; echo >> "$TMP/marker-during-scan" ;; esac
exec "$(command -v jq)" "\$@"
SHIM
chmod +x "$TMP/shim/jq"
jq -cn --arg sid sess-prune-trigger --arg cwd "$PROJ_DIR" --arg tp "$PROJ_DIR/sess-prune-trigger.jsonl" \
    '{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:"startup"}' | PATH="$TMP/shim:$PATH" "$RECORDER" start
assert_eq "the boot is claimed before the scan reads any record" "" \
    "$([ -s "$TMP/marker-during-scan" ] || echo "no scan seen"; grep -vx "$(cat "$STORE_DIR/.last-pruned-boot")" "$TMP/marker-during-scan" | sort -u)"
assert_eq "sess-w's record survives the prune" "true" "$([ -f "$STORE_DIR/sess-w.jsonl" ] && echo true || echo false)"
assert_eq "a record whose transcript is gone everywhere is pruned" "false" "$([ -f "$STORE_DIR/sess-gone.jsonl" ] && echo true || echo false)"
assert_eq "a record written moments ago is left alone" "true" "$([ -f "$STORE_DIR/sess-fresh.jsonl" ] && echo true || echo false)"

kill "$c_pid" 2>/dev/null
wait "$c_pid" 2>/dev/null

echo
echo "=== reader on this machine's real ~/.claude-work (read-only, counts only) ==="
REAL_CONFIG="$HOME/.claude-work"
if [ -d "$REAL_CONFIG" ]; then
    REAL_CACHE=$(mktemp -d)
    REAL_STORE=$(mktemp -d)   # empty: do not touch the real event-log store
    t0=$(date +%s%N 2>/dev/null || date +%s)
    real_out=$(CLAUDE_CONFIG_DIR="$REAL_CONFIG" CLAUDE_SESSION_STORE="$REAL_STORE" \
        CLAUDE_SESSION_READER_CACHE="$REAL_CACHE" "$READER")
    t1=$(date +%s%N 2>/dev/null || date +%s)
    total=$(printf '%s\n' "$real_out" | grep -c .)
    live_count=$(printf '%s\n' "$real_out" | jq -s 'map(select(.live == true)) | length')
    ended_count=$(printf '%s\n' "$real_out" | jq -s 'map(select(.ended == true)) | length')
    named_count=$(printf '%s\n' "$real_out" | jq -s 'map(select(.name != "")) | length')
    invalid=$(printf '%s\n' "$real_out" | while IFS= read -r l; do printf '%s' "$l" | jq empty 2>/dev/null || echo x; done | wc -l | tr -d ' ')
    printf 'sessions found: %s (live=%s ended=%s named=%s), invalid JSON lines: %s\n' \
        "$total" "$live_count" "$ended_count" "$named_count" "$invalid"
    if [ "$invalid" = "0" ]; then ok "every line is valid JSON"; else bad "some lines are not valid JSON"; fi
    if [ -n "${t0:-}" ] && [ -n "${t1:-}" ] && [ "${#t0}" -gt 10 ]; then
        printf 'cold run took %d ms\n' $(( (t1 - t0) / 1000000 ))
    fi
    t2=$(date +%s%N 2>/dev/null || date +%s)
    CLAUDE_CONFIG_DIR="$REAL_CONFIG" CLAUDE_SESSION_STORE="$REAL_STORE" \
        CLAUDE_SESSION_READER_CACHE="$REAL_CACHE" "$READER" > /dev/null
    t3=$(date +%s%N 2>/dev/null || date +%s)
    if [ "${#t2}" -gt 10 ]; then
        printf 'warm run took %d ms\n' $(( (t3 - t2) / 1000000 ))
    fi
    rm -rf "$REAL_CACHE" "$REAL_STORE"
else
    echo "(no ~/.claude-work on this machine — skipped)"
fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
