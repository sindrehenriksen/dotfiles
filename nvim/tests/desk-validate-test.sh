#!/usr/bin/env bash
# claude/desk-lib/validate.sh, the cleaning desk-propose gives an item's
# text, and tool-results.sh's pairing of a call's tool uses with results
# past the argument limit, which the ticket cache reads. Fixtures only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}
assert_contains() {
	local desc=$1 haystack=$2 needle=$3
	if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"; else bad "$desc (expected to contain [$needle], got [$haystack])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

export DESK_STATE_DIR="$ROOT/state"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/validate.sh
source "$LIB/validate.sh"

echo "=== control/ANSI character stripping ==="
raw=$'plain\x1b[31mred\x1b[0m text\x07bell\tkept-tab\nkept-newline'
stripped="$(desk_strip_control_chars <<< "$raw")"
assert_true "ANSI color codes are gone" "$([[ "$stripped" != *$'\x1b'* ]] && echo true || echo false)"
assert_true "a bell control char is gone" "$([[ "$stripped" != *$'\x07'* ]] && echo true || echo false)"
assert_true "tabs and newlines survive" "$([[ "$stripped" == *$'\t'* && "$stripped" == *$'\n'* ]] && echo true || echo false)"

echo
echo "=== modeline stripping ==="
assert_true "a vim 'set' modeline is removed" \
	"$([[ "$(desk_strip_modelines <<< 'text // vim: set ts=2 sw=2: more')" != *'vim:'* ]] && echo true || echo false)"
assert_true "a bare vim: trailer is removed" \
	"$([[ "$(desk_strip_modelines <<< 'text /* vim:noai:ts=4 */')" != *'vim:'* ]] && echo true || echo false)"

echo
echo "=== an anchor quoted from a marked copy loses the mark ==="
clean() { desk_sanitize_item_text "$1" | jq -c .target; }
assert_eq "an under anchor" '{"under":"a-session"}' \
	"$(clean '{"id":"m1","kind":"add","target":{"under":"a-session  <<agent-suggested>>"},"before":"","after":"- x","headline":"h"}')"
assert_eq "both anchors of a move" '[{"at":"- line"},{"after":"- other"}]' \
	"$(clean '{"id":"m2","kind":"move","target":[{"at":"- line  <<agent-suggested>>"},{"after":"- other  <<agent-suggested>>"}],"before":"- line  <<agent-suggested>>","after":"- line","headline":"h"}')"

echo
echo "=== results past the argument limit are still paired with their calls ==="
# Over ARG_MAX (1 MiB on macOS; Linux caps one argument at 128 KiB), so a
# reader that handed jq the results as an argument would pair nothing.
big_dir="$ROOT/big"
mkdir -p "$big_dir"
big_size=1500000
cat > "$big_dir/F-big-tool-uses.jsonl" <<'JSONL'
{"type":"tool_use","id":"b1","name":"mcp__tickets__search","input":{"jql":"project = ABC"}}
{"type":"tool_use","id":"b2","name":"mcp__chat__read_channel","input":{"channel_id":"CBIG01"}}
{"type":"tool_use","id":"b3","name":"mcp__mail__get_thread","input":{"thread_id":"thBig"}}
JSONL
jq -nc --argjson n "$big_size" '
	{type: "tool_result", tool_use_id: "b1", content: [{type: "text", text: ("x" * $n)}]},
	{type: "tool_result", tool_use_id: "b2", content: [{type: "text", text: ("Message TS: 1700000500.000500\n" + ("y" * $n))}]},
	{type: "tool_result", tool_use_id: "b3", content: [{type: "text", text: ("z" * $n)}]}
' > "$big_dir/F-big-tool-results.jsonl"
assert_eq "desk_tool_call_pairs keeps the whole text" "$big_size" \
	"$(desk_tool_call_pairs "$big_dir/F-big-tool-uses.jsonl" "$big_dir/F-big-tool-results.jsonl" mcp__tickets__search | jq '.[0].text | length')"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
