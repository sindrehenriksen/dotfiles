#!/usr/bin/env bash
# Exercises claude/hooks/input-bell.sh: a bell for the needs-you events,
# nothing for anything else. Pure stdin/stdout; touches no state.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
m="$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | test("input-bell")) | .matcher' "$SETTINGS")"
[ "$m" = "AskUserQuestion|ExitPlanMode" ] && ok "PreToolUse matcher is limited" || bad "PreToolUse matcher ([$m])"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
