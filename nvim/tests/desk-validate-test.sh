#!/usr/bin/env bash
# claude/desk-lib/tool-results.sh and validate.sh — the item
# validation everything else rests on: only a source URL that
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
echo "=== URL stripping: labelled links ==="
out="$(desk_strip_disallowed_urls "- WK: a thread [Slack thread](https://example.com/allowed) worth a look" "$allowed")"
assert_eq "a labelled link to an allowed source survives whole" \
	"- WK: a thread [Slack thread](https://example.com/allowed) worth a look" "$out"
out="$(desk_strip_disallowed_urls "- WK: see [the post](https://evil.example/phish) now" "$allowed")"
assert_eq "a disallowed one keeps its label and loses its URL and link syntax" \
	"- WK: see the post [url removed] now" "$out"
out="$(desk_strip_disallowed_urls $'[ok](https://example.com/allowed) and [bad](https://evil.example/x)\nbare https://evil.example/y' "$allowed")"
assert_eq "mixed, over several lines" \
	$'[ok](https://example.com/allowed) and bad [url removed]\nbare [url removed]' "$out"
validated="$(desk_validate_items '[{"id":"l1","file":"notes.md","kind":"new","target":"top","before":"","after":"- WK: x [Slack thread](https://example.com/allowed)","source":"https://example.com/allowed","headline":"h"}]' "$allowed")"
assert_eq "an item citing its source as a labelled link is kept intact" \
	"- WK: x [Slack thread](https://example.com/allowed)" "$(jq -r '.[0].after' <<< "$validated")"

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
echo "=== desk_allowed_urls: Slack's prose result, channel only in the call's arguments ==="
# The shape the Slack connector returns: `{"messages": "<prose>"}`, one
# `Message TS:` line per message, and no channel anywhere in the result.
slack_dir="$ROOT/slack"
mkdir -p "$slack_dir"
cat > "$slack_dir/F-chat-tool-uses.jsonl" <<'JSONL'
{"type":"tool_use","id":"s1","name":"mcp__chat__read_channel","input":{"channel_id":"CCHANA01","oldest":"1700000000","latest":"1700090000.000000","limit":100,"response_format":"detailed"}}
{"type":"tool_use","id":"s2","name":"mcp__chat__read_thread","input":{"channel_id":"CCHANA01","message_ts":"1700000200.000200"}}
{"type":"tool_use","id":"s3","name":"mcp__chat__read_channel","input":{"channel_id":"CCHANB02","oldest":"1700000000","latest":"1700090000"}}
JSONL
jq -c . > "$slack_dir/F-chat-tool-results.jsonl" <<'JSON'
{"type":"tool_result","tool_use_id":"s1","content":[{"type":"text","text":"{\"messages\": \"=== Message from Ada (U0001) at 2023-11-14 22:15:00 ===\\nMessage TS: 1700000100.000100\\nA short note.\\n\\n=== Message from Bo (U0002) at 2023-11-14 22:16:40 ===\\nMessage TS: 1700000200.000200\\nThread replies: 2\\nAn opening post.\"}"}]}
{"type":"tool_result","tool_use_id":"s2","content":[{"type":"text","text":"{\"messages\": \"=== Message from Bo (U0002) ===\\nMessage TS: 1700000200.000200\\nAn opening post.\\n\\n=== Reply from Ada (U0001) ===\\nMessage TS: 1700000300.000300\\nA reply.\"}"}]}
{"type":"tool_result","tool_use_id":"s3","content":[{"type":"text","text":"{\"messages\": \"=== Message from Cy (U0003) ===\\nMessage TS: 1700000400.000400\\nElsewhere.\"}"}]}
JSON
slack_allowed="$(desk_allowed_urls "https://example.slack.com" "$slack_dir/F-chat-tool-results.jsonl")"
allowed_has() { grep -qxF "$1" <<< "$slack_allowed" && echo true || echo false; }
allowed_lacks() { grep -qxF "$1" <<< "$slack_allowed" && echo false || echo true; }
assert_true "a channel message's Message TS pairs with the channel_id it was read from" \
	"$(allowed_has https://example.slack.com/archives/CCHANA01/p1700000100000100)"
assert_true "a thread reply's ts pairs with the thread call's channel" \
	"$(allowed_has https://example.slack.com/archives/CCHANA01/p1700000300000300)"
assert_true "the thread parent the call named is allowed" \
	"$(allowed_has https://example.slack.com/archives/CCHANA01/p1700000200000200)"
assert_true "each call's ts pairs with its own channel" \
	"$(allowed_has https://example.slack.com/archives/CCHANB02/p1700000400000400)"
assert_true "a ts is never paired with a channel another call read" \
	"$(allowed_lacks https://example.slack.com/archives/CCHANB02/p1700000100000100)"
assert_true "a window bound in the arguments is not a message" \
	"$(allowed_lacks https://example.slack.com/archives/CCHANA01/p1700090000000000)"

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
echo "=== the user's own URL on an edited line is neither stripped nor reported as agent-added ==="
# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"
own='see https://own.example/own for notes'
notes_repo="$ROOT/notes"
desk_test_assert_repo_under_root "$notes_repo" "$ROOT"
mkdir -p "$notes_repo"
git -C "$notes_repo" init -q
git -C "$notes_repo" config user.email test@example.invalid
git -C "$notes_repo" config user.name "Desk Test"
printf 'Section A\n%s\n' "$own" > "$notes_repo/notes.md"
git -C "$notes_repo" add notes.md
git -C "$notes_repo" commit -q -m initial
items="$(jq -n --arg b "$own" --arg s "$slack_ok" '[
  {id:"e1",file:"notes.md",kind:"edit",target:{at:$b},before:$b,after:($b + " (done) https://evil.example/new"),source:$s,headline:"h"}]')"
validated="$(desk_validate_items "$items" "$allowed_urls" "$notes_repo" 2> /dev/null)"
assert_eq "before is left exactly as quoted" "$own" "$(jq -r '.[0].before' <<< "$validated")"
assert_contains "after keeps the URL that was already on the user's line" "$(jq -r '.[0].after' <<< "$validated")" "https://own.example/own"
assert_true "a URL the agent added to after is still stripped" \
	"$([[ "$(jq -r '.[0].after' <<< "$validated")" != *evil.example* ]] && echo true || echo false)"

echo
echo "=== a URL quoted in before counts as the user's only when before is really in the notes ==="
leak='https://evil.example/x?d=notes-text'
items="$(jq -n --arg u "$leak" --arg s "$slack_ok" '[
  {id:"b1",file:"notes.md",kind:"add",target:{under:"Section A"},before:$u,after:("- see " + $u),source:$s,headline:"h"},
  {id:"b2",file:"notes.md",kind:"edit",target:{at:("made up " + $u)},before:("made up " + $u),after:("made up " + $u + " (done)"),source:$s,headline:"h"},
  {id:"b3",file:"reading.md",kind:"move",target:[{at:("see " + $u)},"top"],before:("see " + $u),after:("see " + $u),source:$s,headline:"h"}]')"
validated="$(desk_validate_items "$items" "$allowed_urls" "$notes_repo" 2> /dev/null)"
for i in 0 1 2; do
	assert_true "item $((i + 1)): a URL only the model's before carries is stripped from after" \
		"$([[ "$(jq -r ".[$i].after" <<< "$validated")" != *evil.example* ]] && echo true || echo false)"
done
validated="$(desk_validate_items "$(jq -c '.[0:1]' <<< "$items")" "$allowed_urls" 2> /dev/null)"
assert_true "with no notes repo to check against, before grants nothing" \
	"$([[ "$(jq -r '.[0].after' <<< "$validated")" != *evil.example* ]] && echo true || echo false)"

echo
echo "=== desk_apply_caps: overflow is held back for the follow-up summary, never proposed ==="
five_act='[
  {"id":"a1","tier":"act","headline":"one","source":"notes"},
  {"id":"a2","tier":"act","headline":"two","source":"notes"},
  {"id":"a3","tier":"act","headline":"three","source":"notes"},
  {"id":"a4","tier":"act","headline":"four","source":"notes"},
  {"id":"a5","tier":"act","headline":"five","source":"notes"}
]'
caps='{"act": 3, "worth_knowing": 3, "wildcard": 1}'
result="$(desk_apply_caps "$five_act" "$caps")"
kept_n="$(jq '.kept | length' <<< "$result")"
overflow_n="$(jq '.overflow | length' <<< "$result")"
assert_eq "exactly the 3 capped items are kept, no summary item" "3" "$kept_n"
assert_eq "2 items overflowed" "2" "$overflow_n"
assert_true "no kept item is an overflow summary" \
	"$(jq -e '[.kept[].headline] | any(test("more act")) | not' > /dev/null 2>&1 <<< "$result" && echo true || echo false)"
assert_true "no brief file is written any more" "$([ -e "$ROOT/state/briefs" ] && echo false || echo true)"
PASS_SCRATCH="$ROOT/pass-scratch"
mkdir -p "$PASS_SCRATCH"
desk_record_capped "$(jq -c '.overflow' <<< "$result")"
desk_record_capped '[{"tier":"act","headline":"six","source":"session:x","session_id":"x"}]'
assert_eq "capped items from every step add up, headline and tier kept" '["four","five","six"]' \
	"$(jq -c '[.[].headline]' "$PASS_SCRATCH/capped.json")"
assert_eq "a field the summary does not need is left out" "false" "$(jq '[.[] | has("session_id")] | any' "$PASS_SCRATCH/capped.json")"

echo
echo "=== desk_near_misses: the judge's below-the-bar list, cleaned ==="
near="$(desk_near_misses '{"items": [], "near_misses": [
	{"headline": "a\u0007b\nc", "why_not": "routine"}, {"headline": 3}, "bare", {"headline": ""},
	{"headline": "two"}, {"headline": "three"}, {"headline": "four"}, {"headline": "five"}, {"headline": "six"}]}')"
assert_eq "control characters and newlines become spaces, non-entries go, five at most" \
	'["a b c","two","three","four","five"]' "$(jq -c '[.[].headline]' <<< "$near")"
assert_eq "why_not defaults to empty" '["routine",""]' "$(jq -c '[.[0:2][].why_not]' <<< "$near")"
assert_eq "a bare array reply has none" "[]" "$(desk_near_misses '[]')"
assert_eq "a long headline is cut" "120" "$(desk_near_misses "{\"near_misses\": [{\"headline\": \"$(printf 'x%.0s' {1..300})\"}]}" | jq '.[0].headline | length')"

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
