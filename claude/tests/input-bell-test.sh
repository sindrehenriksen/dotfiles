#!/usr/bin/env bash
# Exercises claude/hooks/input-bell.sh: a bell for the needs-you events,
# nothing for anything else. Pure stdin/stdout; touches no state.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XDG_STATE_HOME="$(mktemp -d)"
HOOK="${INPUT_BELL_HOOK:-$HERE/../hooks/input-bell.sh}"
SETTINGS="$HERE/../settings.json"
pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

BELL='{"terminalSequence":"\u0007"}'

expect() { # description expected json
	local out
	out="$(printf '%s' "$3" | "$HOOK")"
	if [ "$out" = "$2" ]; then ok "$1"; else bad "$1 (got [$out])"; fi
}

for t in permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input; do
	expect "Notification $t rings" "$BELL" "{\"hook_event_name\":\"Notification\",\"notification_type\":\"$t\"}"
done
for t in auth_success agent_completed elicitation_complete elicitation_response quota_auto_resume_fired ""; do
	expect "Notification [$t] is quiet" "" "{\"hook_event_name\":\"Notification\",\"notification_type\":\"$t\"}"
done
expect "PreToolUse AskUserQuestion rings" "$BELL" '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
expect "PreToolUse ExitPlanMode rings" "$BELL" '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode"}'
expect "PreToolUse Bash is quiet" "" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
expect "Stop is quiet" "" '{"hook_event_name":"Stop"}'
expect "garbage input is quiet" "" 'not json'
expect "empty input is quiet" "" ''

# Idle turns: the bell depends on the turn's last assistant text, read from
# a fixture transcript.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PID="11111111-aaaa-bbbb-cccc-000000000001"

# transcript <file> <assistant text> [origin kind]: one turn, with a tool
# round trip before the final text, as a real turn has.
transcript() {
	local f="$1" text="$2" origin="${3:-}"
	jq -nc --arg pid "$PID" --arg t "$text" --arg o "$origin" '
		({type:"user", promptId:$pid, message:{role:"user", content:"go"}}
		 | if $o != "" then .origin = {kind:$o} else . end),
		{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"working"},{type:"tool_use", id:"t1", name:"Bash", input:{}}]}},
		{type:"user", promptId:$pid, message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"x"}]}},
		{type:"assistant", message:{role:"assistant", content:[{type:"thinking", thinking:"hm"},{type:"text", text:$t}]}}' >"$f"
}
idle() { # transcript path
	jq -nc --arg p "$1" --arg pid "${2-$PID}" '{hook_event_name:"Notification", notification_type:"idle_prompt", prompt_id:$pid, transcript_path:$p}'
}
idle_case() { # description expected text [origin]
	transcript "$TMP/t.jsonl" "$3" "${4:-}"
	expect "idle: $1" "$2" "$(idle "$TMP/t.jsonl")"
}

idle_case "marker rings" "$BELL" "[needs-you] Which option do you want?"
idle_case "marker without a question rings" "$BELL" "  [needs-you] I need the API key."
idle_case "direct question rings" "$BELL" $'Done with the first part.\n\nShall I go ahead with option B?'
idle_case "question followed by blank lines rings" "$BELL" $'Ready.\nWhich one?\n\n'
idle_case "plain finish is quiet" "" "All done. Tests pass."
idle_case "question in a code block is quiet" "" $'Here is the query:\n\n```sql\nselect 1 where x = ?\n```'
idle_case "question in an unclosed code block is quiet" "" $'Here:\n```\nwhat?'
idle_case "question in an earlier paragraph is quiet" "" $'Did that work? It did.\n\nAll finished, nothing else to do.'
idle_case "quoted question is quiet" "" $'He asked:\n\n> Is it done?'
idle_case "marker mid-text is quiet" "" "Finished. Note [needs-you] is the marker."
idle_case "marker on a later line rings" "$BELL" $'Done with the refactor.\n\n[needs-you] Pick A or B before I push.'
idle_case "marker on a later line in a code block is quiet" "" $'Done.\n\n```\n[needs-you] example\n```\nThat is the format.'
idle_case "marker on a later quoted line is quiet" "" $'Done. The hook rings on:\n\n> [needs-you] Pick one\n\nNothing else.'
idle_case "peer-origin turn with the marker rings" "$BELL" "[needs-you] stuck" peer
idle_case "peer-origin plain finish is quiet" "" "Handled it." peer

# Only the turn named by prompt_id counts: a later turn's question must not ring this one.
transcript "$TMP/t.jsonl" "Finished, nothing to ask."
jq -nc --arg pid "22222222-aaaa-bbbb-cccc-000000000002" '{type:"user", promptId:$pid, message:{role:"user", content:"again"}}, {type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Anything else?"}]}}' >>"$TMP/t.jsonl"
expect "idle: earlier turn is judged by its own text" "" "$(idle "$TMP/t.jsonl")"

expect "idle: unknown prompt_id is quiet" "" "$(idle "$TMP/t.jsonl" nope)"
expect "idle: missing transcript is quiet" "" "$(idle "$TMP/none.jsonl")"
expect "idle: no transcript_path is quiet" "" "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"prompt_id\":\"$PID\"}"
printf 'not json\n{broken' >"$TMP/bad.jsonl"
expect "idle: garbage transcript is quiet" "" "$(idle "$TMP/bad.jsonl")"
printf '%s' x >"$TMP/locked.jsonl"; chmod 000 "$TMP/locked.jsonl"
expect "idle: unreadable transcript is quiet" "" "$(idle "$TMP/locked.jsonl")"
printf '%s' "$(idle "$TMP/locked.jsonl")" | "$HOOK" >/dev/null; [ $? -eq 0 ] && ok "idle: unreadable transcript exits 0" || bad "idle: unreadable transcript exits 0"

# A ~20 MB transcript: the turn sits at the end, so only the tail is read.
big="$TMP/big.jsonl"
jq -nc '{type:"user", promptId:"old", message:{role:"user", content:"old"}}, {type:"assistant", message:{role:"assistant", content:[{type:"text", text:("filler " * 2000)}]}}' >"$TMP/chunk"
for _ in $(seq 1 1450); do cat "$TMP/chunk"; done >"$big"
transcript "$TMP/turn.jsonl" $'Done.\n\nWant me to continue?'
cat "$TMP/turn.jsonl" >>"$big"
size=$(wc -c <"$big")
[ "$size" -gt 18000000 ] && ok "large fixture is ~20 MB ($size bytes)" || bad "large fixture too small ($size)"
start=$(date +%s)
out="$(idle "$big" | "$HOOK")"
elapsed=$(( $(date +%s) - start ))
[ "$out" = "$BELL" ] && ok "large transcript: question rings" || bad "large transcript (got [$out])"
[ "$elapsed" -lt 5 ] && ok "large transcript finishes inside the 5s timeout (${elapsed}s)" || bad "large transcript took ${elapsed}s"

# Mid-turn: a marker rings on the tool event that follows it, once.
SID="sess-1"
STATE="$XDG_STATE_HOME/claude/input-bell-$SID"
mid() { # event [transcript]
	jq -nc --arg ev "$1" --arg p "${2:-$TMP/m.jsonl}" --arg s "$SID" '{hook_event_name:$ev, tool_name:"Bash", session_id:$s, transcript_path:$p}'
}
arec() { jq -nc --arg u "$1" --arg t "$2" '{type:"assistant", uuid:$u, message:{role:"assistant", content:[{type:"text", text:$t},{type:"tool_use", id:"x", name:"Bash", input:{}}]}}'; }
rm -f "$STATE"; : >"$TMP/m.jsonl"
expect "mid: first call on an empty transcript is quiet" "" "$(mid PreToolUse)"
arec u1 "Checking things." >>"$TMP/m.jsonl"
expect "mid: no marker is quiet" "" "$(mid PreToolUse)"
off1="$(head -n 1 "$STATE")"
arec u2 $'[needs-you] Need the API key, carrying on meanwhile.' >>"$TMP/m.jsonl"
expect "mid: marker rings" "$BELL" "$(mid PreToolUse)"
off2="$(head -n 1 "$STATE")"
[ "$off2" -gt "$off1" ] && [ "$off2" = "$(wc -c <"$TMP/m.jsonl" | tr -d ' ')" ] && ok "mid: offset advanced to the end" || bad "mid: offset ($off1 -> $off2)"
expect "mid: second call on unchanged input is quiet" "" "$(mid PreToolUse)"
printf '%s\n' "$(cat "$STATE")" >"$TMP/state.before"
expect "mid: unchanged input again is quiet" "" "$(mid PreToolUse)"
cmp -s "$STATE" "$TMP/state.before" && ok "mid: unchanged input leaves state untouched" || bad "mid: state changed"
# Same turn: a final reply repeating the ask does not ring at turn end.
{ jq -nc --arg pid "$PID" '{type:"user", promptId:$pid, message:{role:"user", content:"go"}}'
  arec u2 $'[needs-you] Need the API key, carrying on meanwhile.'
  jq -nc '{type:"assistant", uuid:"u3", message:{role:"assistant", content:[{type:"text", text:"[needs-you] Still need the API key. Which one?"}]}}'
} >"$TMP/turn2.jsonl"
expect "mid: final reply repeating the ask does not ring again" "" "$(idle "$TMP/turn2.jsonl" | jq -c --arg s "$SID" '.session_id=$s')"
# A new turn with a new marker rings.
{ jq -nc '{type:"user", promptId:"new-turn", message:{role:"user", content:"next"}}'
  jq -nc '{type:"assistant", uuid:"u9", message:{role:"assistant", content:[{type:"text", text:"[needs-you] Different question."}]}}'
} >"$TMP/turn3.jsonl"
expect "mid: new turn with a new marker rings at turn end" "$BELL" "$(idle "$TMP/turn3.jsonl" new-turn | jq -c --arg s "$SID" '.session_id=$s')"
# Code blocks and quotes do not count.
arec u4 $'Example:\n```\n[needs-you] inside code\n```' >>"$TMP/m.jsonl"
arec u5 $'He wrote:\n> [needs-you] quoted' >>"$TMP/m.jsonl"
expect "mid: marker in a code block or quote is quiet" "" "$(mid PreToolUse)"
# Truncated/rotated transcript: offset past EOF recovers quietly, then works.
arec r1 "fresh start" >"$TMP/m.jsonl"
expect "mid: offset past EOF recovers quietly" "" "$(mid PreToolUse)"
[ "$(head -n 1 "$STATE")" = "$(wc -c <"$TMP/m.jsonl" | tr -d ' ')" ] && ok "mid: offset reset to the new end" || bad "mid: offset after rotation"
arec r2 "[needs-you] after rotation" >>"$TMP/m.jsonl"
expect "mid: marker after rotation rings" "$BELL" "$(mid PreToolUse)"
# First call: a marker followed by a lot of attachment records still rings.
rm -f "$STATE"
{ arec f1 "[needs-you] Blocked on a test question."
  for i in $(seq 1 400); do jq -nc --arg x "$(head -c 500 /dev/zero | tr '\0' a)" '{type:"attachment", attachment:{text:$x}}'; done
} >"$TMP/first.jsonl"
[ "$(wc -c <"$TMP/first.jsonl")" -gt 65536 ] && ok "mid: first-call fixture puts the marker over 64 KB back" || bad "mid: first-call fixture too small"
expect "mid: first call rings for a marker far back in the turn" "$BELL" "$(mid PreToolUse "$TMP/first.jsonl")"
expect "mid: unreadable state dir is quiet, exit 0" "" "$(mid PreToolUse "$TMP/none.jsonl")"
# Blocked-tool events still ring and a missing session id is quiet.
expect "mid: no session id is quiet" "" "$(mid PreToolUse | jq -c 'del(.session_id)')"

# Per-call cost on a ~20 MB transcript.
bigsz=$(wc -c <"$big")
cp "$big" "$TMP/bigm.jsonl"; SID=big; STATE="$XDG_STATE_HOME/claude/input-bell-big"
t0=$(date +%s%N 2>/dev/null || echo 0)
out="$(mid PreToolUse "$TMP/bigm.jsonl" | "$HOOK")"; t1=$(date +%s%N 2>/dev/null || echo 0)
out2="$(mid PreToolUse "$TMP/bigm.jsonl" | "$HOOK")"; t2=$(date +%s%N 2>/dev/null || echo 0)
arec b1 "[needs-you] big" >>"$TMP/bigm.jsonl"
out3="$(mid PreToolUse "$TMP/bigm.jsonl" | "$HOOK")"; t3=$(date +%s%N 2>/dev/null || echo 0)
[ -z "$out" ] && [ -z "$out2" ] && [ "$out3" = "$BELL" ] && ok "mid: large transcript behaves ($bigsz bytes)" || bad "mid: large transcript ([$out] [$out2] [$out3])"
echo "# mid-turn cost: first call $(( (t1 - t0) / 1000000 )) ms, unchanged $(( (t2 - t1) / 1000000 )) ms, one new record $(( (t3 - t2) / 1000000 )) ms"
[ $(( (t3 - t0) / 1000000 )) -lt 5000 ] && ok "mid: all large-transcript calls inside the timeout" || bad "mid: too slow"

# First call whose 4 MB window starts 200 KB inside one long line (a big
# attachment record): dropping that partial line must stay cheap.
SID=longline; STATE="$XDG_STATE_HOME/claude/input-bell-longline"; rm -f "$STATE"
ll="$TMP/longline.jsonl"
head -c 300000 /dev/zero | tr '\0' a | jq -Rc '{type:"attachment", attachment:{text:.}}' >"$ll"
jq -nc --arg x "$(head -c 10000 /dev/zero | tr '\0' b)" '{type:"attachment", attachment:{text:$x}}' >"$TMP/rec10k"
tailsz=$((4194304 - 200000))
: >"$TMP/tailpart"
while [ "$(wc -c <"$TMP/tailpart")" -lt $((tailsz - 20000)) ]; do cat "$TMP/rec10k" >>"$TMP/tailpart"; done
arec ll1 "[needs-you] behind a long line" >>"$TMP/tailpart"
pad=$((tailsz - $(wc -c <"$TMP/tailpart") - 1))
{ head -c $((pad - 40)) /dev/zero | tr '\0' c | jq -Rc '{type:"attachment", attachment:{text:.}}' | head -c "$pad"; printf '\n'; cat "$TMP/tailpart"; } >>"$ll"
partial=$(( $(wc -c <"$ll") - 4194304 ))
partial=$(( $(head -n 1 "$ll" | wc -c) - partial ))
[ "$partial" -gt 150000 ] && ok "mid: long-line fixture starts the window ${partial} bytes inside a line" || bad "mid: long-line fixture (partial $partial)"
s0=$(date +%s)
out="$(mid PreToolUse "$ll" | "$HOOK")"
el=$(( $(date +%s) - s0 ))
[ "$out" = "$BELL" ] && ok "mid: first call behind a long partial line rings" || bad "mid: long partial line (got [$out])"
[ "$el" -lt 3 ] && ok "mid: long partial line costs under 3s (${el}s)" || bad "mid: long partial line took ${el}s"

# The emitted value must decode to exactly BEL.
decoded="$(printf '%s' '{"hook_event_name":"Notification","notification_type":"permission_prompt"}' | "$HOOK" | jq -r .terminalSequence | od -An -c | tr -d ' ')"
[ "$decoded" = '\a\n' ] && ok "bell decodes to BEL" || bad "bell decodes to BEL (got [$decoded])"

# Wiring: Stop must never carry the hook; Notification is matcher-limited.
jq -e '.hooks | has("Stop") | not' "$SETTINGS" >/dev/null && ok "no Stop hook wired" || bad "Stop hook wired"
m="$(jq -r '.hooks.Notification[] | select(.hooks[].command | test("input-bell")) | .matcher' "$SETTINGS")"
case "$m" in
	*permission_prompt*idle_prompt*|*idle_prompt*permission_prompt*) ok "Notification matcher is limited ($m)" ;;
	*) bad "Notification matcher missing or unlimited ([$m])" ;;
esac
for ev in PreToolUse; do
	n="$(jq -r --arg ev "$ev" '[.hooks[$ev][] | select(.hooks[].command | test("input-bell"))] | length' "$SETTINGS")"
	m="$(jq -r --arg ev "$ev" '.hooks[$ev][] | select(.hooks[].command | test("input-bell")) | .matcher // "all"' "$SETTINGS")"
	[ "$n" = 1 ] && [ "$m" = all ] && ok "$ev wired once for all tools" || bad "$ev wiring (n=$n matcher=[$m])"
done
jq -e '.hooks | has("PostToolUse") | not' "$SETTINGS" >/dev/null && ok "no PostToolUse hook wired" || bad "PostToolUse hook wired"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
