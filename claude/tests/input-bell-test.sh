#!/usr/bin/env bash
# Exercises claude/hooks/input-bell.sh: a bell for the needs-you events,
# nothing for anything else. Pure stdin/stdout; touches no state.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/input-bell.sh"
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

for t in permission_prompt idle_prompt elicitation_dialog elicitation_url_dialog agent_needs_input; do
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

# The emitted value must decode to exactly BEL.
decoded="$(printf '%s' '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' | "$HOOK" | jq -r .terminalSequence | od -An -c | tr -d ' ')"
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
