#!/usr/bin/env bash
# The live canary's own checks (desk-run-canary.sh), offline: the canary
# runs against a fake `claude` replaying a transcript, so what it judges is
# known. A Bash call that ran must fail it even when the Slack call beside
# it was refused, and so must an echo whose output arrives as a content
# array; both refused passes.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANARY="$HERE/desk-run-canary.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/fakebin" "$ROOT/claude-config" "$ROOT/tmp"
# The canary keeps its scratch for inspection when a check fails.
export TMPDIR="$ROOT/tmp"
cat > "$ROOT/fakebin/claude" << 'FAKE'
#!/usr/bin/env bash
cat "$CANARY_REPLAY"
FAKE
chmod +x "$ROOT/fakebin/claude"

# transcript <bash result content json> <bash is_error> <slack result content json> <slack is_error>
transcript() {
	jq -nc --argjson bc "$1" --argjson be "$2" --argjson sc "$3" --argjson se "$4" '
		{type:"assistant",message:{content:[{type:"tool_use",id:"b1",name:"Bash",input:{command:"echo canary"}}]}},
		{type:"user",message:{content:[{type:"tool_result",tool_use_id:"b1",is_error:$be,content:$bc}]}},
		{type:"assistant",message:{content:[{type:"tool_use",id:"s1",name:"mcp__claude_ai_Slack__slack_send_message",input:{channel:"x",text:"y"}}]}},
		{type:"user",message:{content:[{type:"tool_result",tool_use_id:"s1",is_error:$se,content:$sc}]}},
		{type:"result",subtype:"success"}'
}
run_canary() {
	CANARY_REPLAY="$1" DESK_CANARY_LIVE=1 DESK_CLAUDE_BIN="$ROOT/fakebin/claude" \
		CLAUDE_CONFIG_DIR="$ROOT/claude-config" bash "$CANARY" > "$1.out" 2>&1
	echo $?
}

refusal='"Permission to use this tool was denied."'
transcript '[{"type":"text","text":"canary\n"}]' false "$refusal" true > "$ROOT/ran.jsonl"
assert_eq "a Bash echo that ran fails the canary, beside a refused Slack call" "1" "$(run_canary "$ROOT/ran.jsonl")"

transcript "$refusal" true "$refusal" true > "$ROOT/refused.jsonl"
assert_eq "both refused passes" "0" "$(run_canary "$ROOT/refused.jsonl")"

transcript "$refusal" true '"sent"' false > "$ROOT/slack-sent.jsonl"
assert_eq "a Slack send that went through fails it, beside a refused Bash call" "1" "$(run_canary "$ROOT/slack-sent.jsonl")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
