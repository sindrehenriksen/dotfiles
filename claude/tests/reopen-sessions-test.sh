#!/usr/bin/env bash
# claude/reopen-sessions.sh: which sessions count as open at the last
# shutdown, the idle split, and the guards around each open (a UUID-shaped
# id only, stdin never reaching the opener, a hard timeout per open, a
# liveness re-check just before it, and always a background open). The
# reader, the opener, the clock and the boot time are all stubbed; event
# records are written by hand into a temp store. Nothing here opens a tab.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../reopen-sessions.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export TZ=UTC
export CLAUDE_CONFIG_DIR="$TMP/config"
export CLAUDE_SESSION_STORE="$TMP/store"
export REOPEN_NOW=1791367200 # Wed 2026-10-07 10:00 UTC
export REOPEN_BOOT_TIME=1791300000
export REOPEN_CONFIRM_SECS=0
export REOPEN_TAB_TIMEOUT_SECS=2
unset DESK_CONFIG
PREV_BOOT=1790000000
OLDER_BOOT=1780000000
WORK="$TMP/work"
PROJ="$CLAUDE_CONFIG_DIR/projects/-work"
mkdir -p "$CLAUDE_SESSION_STORE" "$PROJ" "$WORK"

# --- stubs ------------------------------------------------------------------

# The reader: the fixture lines, with `live` switched on for any id the
# opener stub has opened, or from the Nth call on for a line carrying
# `_live_from_call`.
cat > "$TMP/reader" <<EOF
#!/usr/bin/env bash
[ -f "$TMP/reader-fail" ] && exit 1
n=\$(( \$(cat "$TMP/reader-calls" 2> /dev/null || echo 0) + 1 ))
echo "\$n" > "$TMP/reader-calls"
touch "$TMP/opened-ids"
jq -c --argjson n "\$n" --rawfile opened "$TMP/opened-ids" '
	(\$opened | split("\n")) as \$o
	| if (._live_from_call // null) != null and \$n >= ._live_from_call then .live = true else . end
	| if (.id as \$i | \$o | index(\$i)) then .live = true else . end
	| if .live then .left_open = false else . end
	| del(._live_from_call)
' "$TMP/reader.jsonl"
EOF
chmod +x "$TMP/reader"
export DESK_READER="$TMP/reader"

# The opener: logs its argv (tab-separated, one call per line), and by mode
# reads stdin, blocks on it like `hs` does, hangs, or declines.
cat > "$TMP/opener" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\n' "\$1" "\${2:-}" "\${3:-}" "\${4:-}" >> "$TMP/opener-calls"
mode=\$(cat "$TMP/opener-mode" 2> /dev/null)
case "\$mode" in
	read-stdin) if IFS= read -r -t 1 line; then printf 'STDIN:%s\n' "\$line" >> "$TMP/opener-stdin"; fi ;;
	block-on-stdin) cat > /dev/null ;;
	hang-first)
		if [ ! -f "$TMP/hung" ]; then echo \$\$ > "$TMP/hung"; sleep 60; fi ;;
	decline) echo "DeskOpenTab: no ultrawide screen and no frontmost Ghostty window"; echo false; exit 0 ;;
esac
printf '%s\n' "\${2:-}" >> "$TMP/opened-ids"
echo true
EOF
chmod +x "$TMP/opener"
export DESK_OPEN_TAB_BIN="$TMP/opener"

# --- fixtures ---------------------------------------------------------------

ev_start() { jq -cn --arg b "$1" --argjson t "$2" --arg s "${3:-resume}" '{event:"start", time:$t, source:$s, cwd:"", transcript_path:"", boot:$b}'; }
ev_end() { jq -cn --argjson t "$1" --arg r "${2:-other}" '{event:"end", time:$t, reason:$r}'; }
epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2> /dev/null || date -u -d "$1" +%s; }

# reader_line <id> <last human ISO> [live] [left_open] [cwd] [end reason] [end_deliberate]
# left_open defaults to "not live"; the real reader works it out, the stub
# is told.
reader_line() {
	local id="$1" lh live="${3:-false}" cwd="${5:-$WORK}" tp="$PROJ/$1.jsonl" left
	left="${4:-}"
	[ -n "$left" ] || { [ "$live" = true ] && left=false || left=true; }
	lh=$(epoch "$2")
	: > "$tp"
	jq -cn --arg id "$id" --argjson lh "$lh" --argjson live "$live" --argjson left "$left" \
		--arg cwd "$cwd" --arg tp "$tp" --arg reason "${6:-}" --arg deliberate "${7:-}" '
		{id: $id, name: ("name-" + $id[0:4]), cwd: $cwd, live: $live, has_start_event: true,
		 ended: ($reason != ""), end_reason: (if $reason == "" then null else $reason end),
		 end_deliberate: (if $deliberate == "" then null else ($deliberate == "true") end),
		 left_open: $left,
		 last_human_message: $lh, last_activity: $lh, transcript_path: $tp, pid: (if $live then 4242 else null end)}
	' >> "$TMP/reader.jsonl"
}

reset_fixtures() {
	rm -rf "$CLAUDE_SESSION_STORE" "$TMP/reader.jsonl" "$TMP/reader-calls" "$TMP/opener-calls" \
		"$TMP/opener-stdin" "$TMP/opener-mode" "$TMP/opened-ids" "$TMP/hung" "$TMP/reader-fail"
	mkdir -p "$CLAUDE_SESSION_STORE"
	: > "$TMP/reader.jsonl"
}

ACTIVE=aaaaaaaa-0000-4000-8000-000000000001
ACTIVE2=aaaaaaaa-0000-4000-8000-000000000002
IDLE=bbbbbbbb-0000-4000-8000-000000000001
LIVE=cccccccc-0000-4000-8000-000000000001
ENDED=dddddddd-0000-4000-8000-000000000001
OLD=eeeeeeee-0000-4000-8000-000000000001
CLOSED_SINCE=ffffffff-0000-4000-8000-000000000001
SCHEDULED=99999999-0000-4000-8000-000000000001
THIS_BOOT=88888888-0000-4000-8000-000000000001
EDGE_IDLE=77777777-0000-4000-8000-000000000001
EDGE_ACTIVE=77777777-0000-4000-8000-000000000002
SHUTDOWN_OTHER=66666666-0000-4000-8000-000000000001
TODAY_LIVE=55555555-0000-4000-8000-000000000001

standard_fixtures() {
	reset_fixtures
	local S="$CLAUDE_SESSION_STORE"
	# Open when the previous boot ended, last message yesterday: reopen.
	ev_start "$PREV_BOOT" 1790100000 > "$S/$ACTIVE.jsonl"
	reader_line "$ACTIVE" 2026-10-06T09:00:00Z
	# Open at shutdown, last message twelve days ago: idle.
	ev_start "$PREV_BOOT" 1790100000 > "$S/$IDLE.jsonl"
	reader_line "$IDLE" 2026-09-25T09:00:00Z
	# Open at shutdown, already resumed and live again.
	{ ev_start "$PREV_BOOT" 1790100000; ev_start "$REOPEN_BOOT_TIME" 1791301000; } > "$S/$LIVE.jsonl"
	reader_line "$LIVE" 2026-10-06T09:00:00Z true
	# Ended by the user before the shutdown.
	{ ev_start "$PREV_BOOT" 1790100000; ev_end 1790200000 prompt_input_exit; } > "$S/$ENDED.jsonl"
	reader_line "$ENDED" 2026-10-06T09:00:00Z false false "" prompt_input_exit true
	# Ended at the shutdown, but not by the user: left open.
	{ ev_start "$PREV_BOOT" 1790100000; ev_end 1790200000 other; } > "$S/$SHUTDOWN_OTHER.jsonl"
	reader_line "$SHUTDOWN_OTHER" 2026-10-06T07:00:00Z false true "" other false
	# Started and still live this boot: nothing to do with the shutdown.
	ev_start "$REOPEN_BOOT_TIME" 1791301000 > "$S/$TODAY_LIVE.jsonl"
	reader_line "$TODAY_LIVE" 2026-10-07T08:00:00Z true
	# Left open by a boot before the previous one: an old orphan.
	ev_start "$OLDER_BOOT" 1780100000 > "$S/$OLD.jsonl"
	reader_line "$OLD" 2026-10-06T08:00:00Z
	# Open at shutdown, resumed after the restart and closed again.
	{ ev_start "$PREV_BOOT" 1790100000; ev_start "$REOPEN_BOOT_TIME" 1791301000; ev_end 1791302000 prompt_input_exit; } > "$S/$CLOSED_SINCE.jsonl"
	reader_line "$CLOSED_SINCE" 2026-10-06T09:00:00Z false false "" prompt_input_exit true
	# A scheduled pass's own call, open at shutdown.
	ev_start "$PREV_BOOT" 1790100000 desk-run > "$S/$SCHEDULED.jsonl"
	reader_line "$SCHEDULED" 2026-10-06T09:00:00Z false false
	# Stopped during this boot with no end (a crash, the terminal quitting):
	# counts too. Its boot id is a little off the current one, as
	# kern.boottime can be after a clock step.
	ev_start "$((REOPEN_BOOT_TIME - 40))" 1791301000 > "$S/$THIS_BOOT.jsonl"
	reader_line "$THIS_BOOT" 2026-10-07T08:00:00Z
	# The idle boundary, as the close step counts it: Friday's message is 3
	# working days old on Wednesday, Monday's is 2.
	ev_start "$((PREV_BOOT + 20))" 1790100000 > "$S/$EDGE_IDLE.jsonl"
	reader_line "$EDGE_IDLE" 2026-10-02T15:00:00Z
	ev_start "$PREV_BOOT" 1790100000 > "$S/$EDGE_ACTIVE.jsonl"
	reader_line "$EDGE_ACTIVE" 2026-10-05T15:00:00Z
	# A record with no start event at all is ignored.
	ev_end 1790200000 > "$S/12345678-0000-4000-8000-00000000dead.jsonl"
}

status_of() { awk -F'\t' -v id="$2" '$2 == id {print $1}' <<< "$1"; }
detail_of() { awk -F'\t' -v id="$2" '$2 == id {print $7}' <<< "$1"; }
summary_field() { sed -n "s/.*[[:space:]]$2=\([^ ]*\).*/\1/p" <<< "$1"; }
opener_calls() { [ -f "$TMP/opener-calls" ] && wc -l < "$TMP/opener-calls" | tr -d ' ' || echo 0; }
store_hash() { find "$CLAUDE_SESSION_STORE" -type f -exec shasum {} + | sort | shasum; }

echo "=== dry run: which sessions count, and nothing is opened or written ==="
standard_fixtures
before=$(store_hash)
out=$("$CLI" --dry-run)
rc=$?
assert_eq "dry run exits 0" 0 "$rc"
assert_eq "open at shutdown, recent message: would open" would-open "$(status_of "$out" "$ACTIVE")"
assert_eq "open at shutdown, old message: idle" idle "$(status_of "$out" "$IDLE")"
assert_eq "already live: running" running "$(status_of "$out" "$LIVE")"
assert_eq "ended by the user before shutdown: not listed" "" "$(status_of "$out" "$ENDED")"
assert_eq "ended with reason other at shutdown: would open" would-open "$(status_of "$out" "$SHUTDOWN_OTHER")"
assert_eq "and says why it counts" true "$(detail_of "$out" "$SHUTDOWN_OTHER" | grep -q 'ended without the user (reason other)' && echo true || echo false)"
assert_eq "live session started this boot: not listed" "" "$(status_of "$out" "$TODAY_LIVE")"
assert_eq "end_deliberate true: never reopened" "" "$(status_of "$out" "$ENDED")"
assert_eq "left_open true: reopened" would-open "$(status_of "$out" "$SHUTDOWN_OTHER")"
assert_eq "old orphan from an earlier boot: not listed" "" "$(status_of "$out" "$OLD")"
assert_eq "closed again after the restart: not listed" "" "$(status_of "$out" "$CLOSED_SINCE")"
assert_eq "scheduled pass's call: not listed" "" "$(status_of "$out" "$SCHEDULED")"
assert_eq "stopped this boot without an end: would open" would-open "$(status_of "$out" "$THIS_BOOT")"
assert_eq "Friday's message is idle on Wednesday" idle "$(status_of "$out" "$EDGE_IDLE")"
assert_eq "Monday's message is not" would-open "$(status_of "$out" "$EDGE_ACTIVE")"
assert_eq "idle line carries the last-message date" "2026-09-25 09:00" \
	"$(awk -F'\t' -v id="$IDLE" '$2 == id {print $3}' <<< "$out")"
assert_eq "opener never called on a dry run" 0 "$(opener_calls)"
assert_eq "store untouched on a dry run" "$before" "$(store_hash)"
summary=$(tail -n 1 <<< "$out")
assert_eq "summary line last" summary "$(cut -f1 <<< "$summary")"
assert_eq "summary counts older orphans" 1 "$(summary_field "$summary" older_orphans)"
assert_eq "summary counts sessions ended deliberately" 2 "$(summary_field "$summary" ended_deliberately)"
assert_eq "summary shows the default threshold" "3(default)" "$(summary_field "$summary" idle_after_working_days)"
assert_eq "would-open lines come first" would-open "$(head -n 1 <<< "$out" | cut -f1)"

echo
echo "=== --all-boots brings old orphans in ==="
out=$("$CLI" --dry-run --all-boots)
assert_eq "old orphan listed with --all-boots" would-open "$(status_of "$out" "$OLD")"

echo
echo "=== --json ==="
json=$("$CLI" --dry-run --json)
assert_eq "json summary would_open" 4 "$(jq '.summary.would_open' <<< "$json")"
assert_eq "json summary idle" 2 "$(jq '.summary.idle' <<< "$json")"
assert_eq "json summary running" 1 "$(jq '.summary.running' <<< "$json")"
assert_eq "json session carries idle_working_days" 1 \
	"$(jq --arg id "$ACTIVE" '.sessions[] | select(.id == $id) | .idle_working_days' <<< "$json")"

echo
echo "=== the threshold comes from the desk config when one is set ==="
printf '{"close_after_working_days": 20}\n' > "$TMP/config.json"
out=$(DESK_CONFIG="$TMP/config.json" "$CLI" --dry-run)
assert_eq "twelve-day-old message is active under a 20-day threshold" would-open "$(status_of "$out" "$IDLE")"
assert_eq "summary names the config as the source" "20(config)" "$(summary_field "$(tail -n 1 <<< "$out")" idle_after_working_days)"

echo
echo "=== a real run opens the active ones, in the background, resumed in their cwd ==="
standard_fixtures
out=$("$CLI")
rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "active session opened" opened "$(status_of "$out" "$ACTIVE")"
assert_eq "idle session still only listed" idle "$(status_of "$out" "$IDLE")"
assert_eq "one opener call per active session" 4 "$(opener_calls)"
call=$(grep -F "$ACTIVE" "$TMP/opener-calls")
assert_eq "asks for a background open" background "$(cut -f4 <<< "$call")"
assert_eq "resumes that session id" "CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR' claude --resume '$ACTIVE'" "$(cut -f1 <<< "$call")"
assert_eq "passes the id for the opener's own check" "$ACTIVE" "$(cut -f2 <<< "$call")"
assert_eq "in the recorded cwd" "$WORK" "$(cut -f3 <<< "$call")"
assert_eq "live session never handed to the opener" "" "$(grep -F "$LIVE" "$TMP/opener-calls")"
assert_eq "idle session never handed to the opener" "" "$(grep -F "$IDLE" "$TMP/opener-calls")"

echo
echo "=== a malformed id is refused, never opened ==="
reset_fixtures
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/not-a-uuid.jsonl"
reader_line not-a-uuid 2026-10-06T09:00:00Z
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/ .jsonl"
reader_line " " 2026-10-06T09:00:00Z
out=$("$CLI")
rc=$?
assert_eq "exit 1 when a session is refused" 1 "$rc"
assert_eq "malformed id reported failed" failed "$(status_of "$out" not-a-uuid)"
assert_eq "blank id reported failed" failed "$(status_of "$out" " ")"
assert_eq "opener never called" 0 "$(opener_calls)"
"$CLI" --session "" > /dev/null 2>&1
assert_eq "an empty --session is a usage error" 2 "$?"
assert_eq "opener still never called" 0 "$(opener_calls)"

echo
echo "=== the opener never sees the caller's stdin ==="
reset_fixtures
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/$ACTIVE.jsonl"
reader_line "$ACTIVE" 2026-10-06T09:00:00Z
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/$ACTIVE2.jsonl"
reader_line "$ACTIVE2" 2026-10-06T08:00:00Z
echo read-stdin > "$TMP/opener-mode"
out=$(printf 'line one\nline two\nline three\n' | "$CLI")
assert_eq "opener read nothing from the caller's stdin" "" "$(cat "$TMP/opener-stdin" 2> /dev/null)"
assert_eq "both opened" "opened opened" "$(status_of "$out" "$ACTIVE") $(status_of "$out" "$ACTIVE2")"

rm -f "$TMP/opener-calls" "$TMP/opened-ids"
echo block-on-stdin > "$TMP/opener-mode"
start=$(date +%s)
# The pipeline as a whole waits out the writer, so time the CLI itself.
(sleep 12; echo late) | { "$CLI" > "$TMP/out"; date +%s > "$TMP/done"; }
out=$(cat "$TMP/out")
elapsed=$(( $(cat "$TMP/done") - start ))
assert_eq "an opener reading stdin to EOF (as hs does) does not block on an open pipe" \
	"opened opened" "$(status_of "$out" "$ACTIVE") $(status_of "$out" "$ACTIVE2")"
assert_eq "and the run did not wait for the pipe" true "$([ "$elapsed" -lt 10 ] && echo true || echo false)"

echo
echo "=== a hung opener times out, fails that session, and the run carries on ==="
rm -f "$TMP/opener-calls" "$TMP/opened-ids" "$TMP/hung"
echo hang-first > "$TMP/opener-mode"
start=$(date +%s)
out=$("$CLI")
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "the first session fails" failed "$(status_of "$out" "$ACTIVE")"
assert_eq "with a timeout reason" true "$(detail_of "$out" "$ACTIVE" | grep -q 'timed out' && echo true || echo false)"
assert_eq "the next one still opens" opened "$(status_of "$out" "$ACTIVE2")"
assert_eq "exit 1" 1 "$rc"
assert_eq "well before the hang would have ended" true "$([ "$elapsed" -lt 20 ] && echo true || echo false)"
hung_pid=$(cat "$TMP/hung" 2> /dev/null)
assert_eq "the hung opener was killed" false "$([ -n "$hung_pid" ] && kill -0 "$hung_pid" 2> /dev/null && echo true || echo false)"

echo
echo "=== liveness is re-checked just before opening ==="
reset_fixtures
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/$ACTIVE.jsonl"
reader_line "$ACTIVE" 2026-10-06T09:00:00Z
jq -c '._live_from_call = 2' "$TMP/reader.jsonl" > "$TMP/r" && mv "$TMP/r" "$TMP/reader.jsonl"
out=$("$CLI")
assert_eq "a session that came up meanwhile reports running" running "$(status_of "$out" "$ACTIVE")"
assert_eq "and is not opened" 0 "$(opener_calls)"

echo
echo "=== the opener declining (DeskOpenTab returned false) is a failure ==="
reset_fixtures
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/$ACTIVE.jsonl"
reader_line "$ACTIVE" 2026-10-06T09:00:00Z
echo decline > "$TMP/opener-mode"
out=$("$CLI")
rc=$?
assert_eq "reported failed" failed "$(status_of "$out" "$ACTIVE")"
assert_eq "with the opener's message" true "$(detail_of "$out" "$ACTIVE" | grep -q 'no ultrawide' && echo true || echo false)"
assert_eq "exit 1" 1 "$rc"

echo
echo "=== --session opens a chosen idle one; an unknown one fails ==="
standard_fixtures
out=$("$CLI" --session "${IDLE:0:8}")
assert_eq "idle session opened when asked for" opened "$(status_of "$out" "$IDLE")"
assert_eq "nothing else opened" 1 "$(opener_calls)"
out=$("$CLI" --session 00000000-0000-4000-8000-000000000000)
assert_eq "unknown session reported failed" failed "$(status_of "$out" 00000000-0000-4000-8000-000000000000)"
rm -f "$TMP/opener-calls"
out=$("$CLI" --session "$ENDED")
assert_eq "a session ended deliberately is refused even when asked for" failed "$(status_of "$out" "$ENDED")"
assert_eq "and not opened" 0 "$(opener_calls)"
out=$("$CLI" --dry-run --session 77777777)
assert_eq "a prefix matching two sessions is ambiguous" failed "$(status_of "$out" 77777777)"

echo
echo "=== an opened session is confirmed live when it comes up ==="
reset_fixtures
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/$ACTIVE.jsonl"
reader_line "$ACTIVE" 2026-10-06T09:00:00Z
json=$(REOPEN_CONFIRM_SECS=3 "$CLI" --json)
assert_eq "confirmed_live true" true "$(jq '.sessions[0].confirmed_live' <<< "$json")"

echo
echo "=== preflight failures ==="
reset_fixtures
ev_start "$PREV_BOOT" 1790100000 > "$CLAUDE_SESSION_STORE/$ACTIVE.jsonl"
reader_line "$ACTIVE" 2026-10-06T09:00:00Z false true "$TMP/gone"
out=$("$CLI" --dry-run)
assert_eq "a missing cwd fails even on a dry run" failed "$(status_of "$out" "$ACTIVE")"
touch "$TMP/reader-fail"
"$CLI" --dry-run > /dev/null 2>&1
assert_eq "a failing reader exits 3" 3 "$?"
rm -f "$TMP/reader-fail"
CLAUDE_SESSION_STORE="$TMP/nowhere" "$CLI" --dry-run > /dev/null 2>&1
assert_eq "a missing store exits 3" 3 "$?"
jq -c 'del(.left_open)' "$TMP/reader.jsonl" > "$TMP/r" && mv "$TMP/r" "$TMP/reader.jsonl"
"$CLI" --dry-run > /dev/null 2>&1
assert_eq "a reader without left_open exits 3 rather than opening nothing" 3 "$?"

echo
echo "reopen-sessions: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
