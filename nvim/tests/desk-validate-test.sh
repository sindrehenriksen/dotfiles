#!/usr/bin/env bash
# D8b test: claude/desk-lib/tool-results.sh and validate.sh — the item
# validation design.md hangs everything else on: only a source URL that
# genuinely appears in a call's raw tool_results survives (Slack rebuilt
# from channel+ts, Gmail/WebSearch literal), control/ANSI characters and
# modelines are stripped from item text, tier caps overflow to a dated
# brief, and 16:30's turn citations are checked against a real transcript
# tail and always stripped. Every raw tool_result here is a hand-built
# fixture, never a live call.
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
export DESK_BRIEF_DIR="$ROOT/state/briefs"

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
echo "=== URL stripping: only the allowed set survives ==="
allowed=$'https://example.com/allowed'
text="see https://example.com/allowed and also https://evil.example/phish"
out="$(desk_strip_disallowed_urls "$text" "$allowed")"
assert_contains "the allowed URL is untouched" "$out" "https://example.com/allowed"
assert_true "the disallowed URL is gone" "$([[ "$out" != *evil.example* ]] && echo true || echo false)"
assert_contains "the disallowed URL is replaced with a marker" "$out" "[url removed]"

echo
echo "=== desk_allowed_urls: Gmail literal + Slack rebuilt-from-raw ==="
results_file="$ROOT/tool-results.jsonl"
cat > "$results_file" <<'JSONL'
{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"{\"threads\":[{\"id\":\"th1\",\"viewUrl\":\"https://mail.google.com/mail/u/0/#thread/th1\"}]}"}]}
{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"{\"messages\":[{\"channel\":\"CEXAMPLEID\",\"ts\":\"1700000000.123456\",\"text\":\"hi\"}]}"}]}
JSONL
allowed_urls="$(desk_allowed_urls "https://example.slack.com" "$results_file")"
assert_true "Gmail's viewUrl is in the allowed set" \
	"$(grep -qxF 'https://mail.google.com/mail/u/0/#thread/th1' <<< "$allowed_urls" && echo true || echo false)"
assert_true "the Slack permalink is rebuilt from channel+ts" \
	"$(grep -qxF 'https://example.slack.com/archives/CEXAMPLEID/p1700000000123456' <<< "$allowed_urls" && echo true || echo false)"
assert_true "a URL never in the raw results is not allowed" \
	"$(grep -qxF 'https://evil.example/phish' <<< "$allowed_urls" && echo false || echo true)"

echo
echo "=== desk_validate_items: drops an item whose source URL isn't verifiable ==="
items='[
  {"id":"i1","file":"notes.md","kind":"new","target":"top","before":"","after":"a Slack item","source":"https://example.slack.com/archives/CEXAMPLEID/p1700000000123456","headline":"h1"},
  {"id":"i2","file":"notes.md","kind":"new","target":"top","before":"","after":"a fabricated item","source":"https://example.slack.com/archives/CFAKE/p9999999999000000","headline":"h2"},
  {"id":"i3","file":"notes.md","kind":"new","target":"top","before":"","after":"a non-url source","source":"notes","headline":"h3"}
]'
validated="$(desk_validate_items "$items" "$allowed_urls")"
assert_eq "two of the three items survive" "2" "$(jq 'length' <<< "$validated")"
assert_true "the verified Slack item survives" \
	"$(jq -e '[.[].id] | index("i1")' > /dev/null 2>&1 <<< "$validated" && echo true || echo false)"
assert_true "the fabricated-source item is dropped" \
	"$(jq -e '[.[].id] | index("i2")' > /dev/null 2>&1 <<< "$validated" && echo false || echo true)"
assert_true "the non-url source item survives untouched" \
	"$(jq -e '[.[].id] | index("i3")' > /dev/null 2>&1 <<< "$validated" && echo true || echo false)"

echo
echo "=== also_sources: invalid entries dropped, the item and valid entries kept ==="
slack_ok="https://example.slack.com/archives/CEXAMPLEID/p1700000000123456"
mail_ok="https://mail.google.com/mail/u/0/#thread/th1"
items="$(jq -n --arg s "$slack_ok" --arg m "$mail_ok" '[
  {id:"m1",file:"notes.md",kind:"new",target:"top",before:"",after:("see " + $m + " and https://evil.example/x"),
   source:$s, also_sources:[$m, "https://evil.example/fake", $s, $m], headline:"h"},
  {id:"m2",file:"notes.md",kind:"new",target:"top",before:"",after:"x",source:$s,also_sources:["https://evil.example/only"],headline:"h"},
  {id:"m3",file:"notes.md",kind:"new",target:"top",before:"",after:"x",source:$s,headline:"h"}
]')"
validated="$(desk_validate_items "$items" "$allowed_urls" 2> /dev/null)"
assert_eq "no item is dropped for a bad also_sources entry" "3" "$(jq 'length' <<< "$validated")"
assert_eq "only the verbatim fetched URL stays, deduped, source excluded" "[\"$mail_ok\"]" "$(jq -c '.[0].also_sources' <<< "$validated")"
assert_eq "an all-invalid also_sources is removed" "false" "$(jq '.[1] | has("also_sources")' <<< "$validated")"
assert_eq "an item without also_sources stays without" "false" "$(jq '.[2] | has("also_sources")' <<< "$validated")"
assert_contains "other URLs in item text are still stripped" "$(jq -r '.[0].after' <<< "$validated")" "[url removed]"
desk_validate_items "$items" "$allowed_urls" > /dev/null 2> "$ROOT/drop.err"
assert_contains "the drop count is reported" "$(cat "$ROOT/drop.err")" "dropped 4 invalid also_sources"

echo
echo "=== desk_apply_caps: overflow goes to the dated brief with a summary line ==="
five_act='[
  {"id":"a1","tier":"act","headline":"one","source":"notes"},
  {"id":"a2","tier":"act","headline":"two","source":"notes"},
  {"id":"a3","tier":"act","headline":"three","source":"notes"},
  {"id":"a4","tier":"act","headline":"four","source":"notes"},
  {"id":"a5","tier":"act","headline":"five","source":"notes"}
]'
caps='{"act": 3, "worth_knowing": 3, "wildcard": 1}'
result="$(desk_apply_caps "$five_act" "$caps" "morning")"
kept_n="$(jq '.kept | length' <<< "$result")"
overflow_n="$(jq '.overflow | length' <<< "$result")"
assert_eq "3 kept + 1 overflow-summary item = 4" "4" "$kept_n"
assert_eq "2 items overflowed" "2" "$overflow_n"
assert_true "the summary item names the overflow count" \
	"$(jq -e '[.kept[].headline] | any(test("\\+2 more act"))' > /dev/null 2>&1 <<< "$result" && echo true || echo false)"
brief_file="$DESK_BRIEF_DIR/$(date +%F).md"
assert_true "the dated brief file was written" "$([ -f "$brief_file" ] && echo true || echo false)"
assert_true "the brief holds the overflowing items' headlines" \
	"$(grep -q 'four' "$brief_file" && grep -q 'five' "$brief_file" && echo true || echo false)"

echo
echo "=== desk_verify_and_strip_turn_citations ==="
tail_file="$ROOT/transcript-tail.jsonl"
cat > "$tail_file" <<'JSONL'
{"uuid":"aaaaaaaa-1111-2222-3333-444444444444","type":"assistant"}
{"uuid":"bbbbbbbb-1111-2222-3333-444444444444","type":"user"}
JSONL
citation_items='[
  {"id":"c1","after":"stood: did the thing [turn aaaaaaaa]","before":""},
  {"id":"c2","after":"stood: fabricated [turn ffffffff]","before":""},
  {"id":"c3","after":"no citation at all","before":""}
]'
out="$(desk_verify_and_strip_turn_citations "$citation_items" "$tail_file")"
assert_eq "the valid and uncited items survive, the fabricated one is dropped" "2" "$(jq 'length' <<< "$out")"
assert_true "c1 survives" "$(jq -e '[.[].id] | index("c1")' > /dev/null 2>&1 <<< "$out" && echo true || echo false)"
assert_true "c2 (fabricated citation) is dropped" \
	"$(jq -e '[.[].id] | index("c2")' > /dev/null 2>&1 <<< "$out" && echo false || echo true)"
assert_true "the citation marker itself is stripped from surviving text" \
	"$(jq -r '.[] | select(.id == "c1") | .after' <<< "$out" | grep -q '\[turn' && echo false || echo true)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
