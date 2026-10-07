#!/usr/bin/env bash
# claude/desk-lib/retention.sh: the cutoff read from a temp settings file,
# which sessions are selected (fake transcripts with set mtimes in a temp
# CLAUDE_CONFIG_DIR, against a fixed clock), the item a capture reply becomes,
# the move guard, caps, dedup on a decline, and that no transcript is written.
# The reader is faked for selection and the real one is run once against the
# same temp config dir; `claude` is a fake that replies per session.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$REPO_ROOT/claude/desk-lib"

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

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export DESK_BRIEF_DIR="$STATE/briefs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export CLAUDE_SESSION_STORE="$ROOT/session-events"
export CLAUDE_SESSION_READER_CACHE="$ROOT/reader-cache"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-p" "$CLAUDE_SESSION_STORE"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
SESSION_STATUS_FIXTURE="$ROOT/sessions.jsonl"
cat > "$FAKEBIN/session-status.sh" << FAKE
#!/usr/bin/env bash
cat "$SESSION_STATUS_FIXTURE" 2> /dev/null
FAKE
chmod +x "$FAKEBIN/session-status.sh"

# Replies with $REPLIES/<session id>.json, the session read from the
# session.json the runner seeded into the call's cwd.
REPLIES="$ROOT/replies"
CALLS="$ROOT/calls.log"
mkdir -p "$REPLIES"
: > "$CALLS"
cat > "$FAKEBIN/claude" << FAKE
#!/usr/bin/env bash
id="\$(jq -r .id session.json)"
echo "\$id" >> "$CALLS"
cp prompt.txt "$ROOT/prompt-\$id.txt" 2> /dev/null
jq -nc --rawfile t "$REPLIES/\$id.json" '{type:"assistant",message:{content:[{type:"text",text:\$t}]}}'
echo '{"type":"result","subtype":"success","total_cost_usd":0}'
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
for f in status timeout model-call git-ops tool-results validate lock steps retention; do
	# shellcheck disable=SC1090
	source "$LIB/$f.sh"
done

NOW=1800000000
desk_now() { echo "$NOW"; }
day=86400
date_of() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%d", localtime($ARGV[0]))' "$1"; }
set_mtime() { perl -e 'utime($ARGV[1], $ARGV[1], $ARGV[0]) or die' "$1" "$2"; }

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
cat > "$repo/notes.md" << 'NOTES'
Inbox
  something to sort
- alpha-work: the thing
  - waiting on review
- beta-work: other thing
- gamma-work, live-work, deskrun-work, done-work, past-work, elsewhere-work
- an unnamed one: 0000aaaa
NOTES
printf 'To read\n  edge-work\n' > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
files=(notes.md reading.md)

transcript() { # id age_days -> path
	local p="$CLAUDE_CONFIG_DIR/projects/-p/$1.jsonl"
	printf '{"uuid":"%s-turn","type":"user","message":{"role":"user","content":"hi"}}\n' "${1:0:8}" > "$p"
	set_mtime "$p" $((NOW - $2 * day))
	printf '%s' "$p"
}
entry() { # id name age_days [extra-json]
	local tp
	tp="$(transcript "$1" "$3")"
	jq -cn --arg id "$1" --arg n "$2" --arg tp "$tp" --argjson x "${4:-{\}}" \
		'{id:$id, name:$n, name_source:"user", live:false, has_start_event:true, ended:false, end_reason:null, transcript_path:$tp} + $x'
}

echo "=== the cutoff, from the settings file ==="
assert_eq "no settings file: the documented default" "30" "$(desk_cleanup_period_days)"
echo '{"model":"x"}' > "$CLAUDE_CONFIG_DIR/settings.json"
assert_eq "unset in the file: the documented default" "30" "$(desk_cleanup_period_days)"
echo '{"cleanupPeriodDays": 120}' > "$CLAUDE_CONFIG_DIR/settings.json"
assert_eq "set in the file: that value" "120" "$(desk_cleanup_period_days)"
echo '{"cleanupPeriodDays": 0}' > "$CLAUDE_CONFIG_DIR/settings.json"
assert_true "0 is refused" "$(desk_cleanup_period_days > /dev/null 2>&1 && echo false || echo true)"
echo '{not json' > "$CLAUDE_CONFIG_DIR/settings.json"
assert_true "an unparseable file is refused" "$(desk_cleanup_period_days > /dev/null 2>&1 && echo false || echo true)"
echo '{"cleanupPeriodDays": 120}' > "$CLAUDE_CONFIG_DIR/settings.json"

echo
echo "=== selection: cutoff 120, margin 14 ==="
outside_tp="$ROOT/elsewhere.jsonl"
printf '{}\n' > "$outside_tp"
set_mtime "$outside_tp" $((NOW - 110 * day))
{
	entry aaaaaaaa-0001 alpha-work 110          # 10 days left
	entry bbbbbbbb-0002 beta-work 100           # 20 days left
	entry eeeeeeee-0003 edge-work 106           # exactly 14 days left, named in reading.md
	entry cccccccc-0004 gamma-work 110 '{"live":true}'
	entry dddddddd-0005 deskrun-work 110 '{"any_desk_run_start":true}'
	entry ffffffff-0006 done-work 110 '{"ended":true,"end_reason":"prompt_input_exit"}'
	entry 99999999-0007 unmentioned-work 110
	entry 0000aaaa-0008 "Some auto title" 111 '{"name_source":"ai_or_none"}'
	entry 77777777-0009 past-work 125           # already past due
	jq -cn --arg tp "$outside_tp" '{id:"88888888-0010", name:"elsewhere-work", name_source:"user", live:false, transcript_path:$tp}'
} > "$SESSION_STATUS_FIXTURE"
hash_transcripts() {
	find "$CLAUDE_CONFIG_DIR/projects" "$outside_tp" -type f -exec perl -e 'for (@ARGV) { my @s = stat; print "$_ $s[9]\n" }' {} + | sort
	find "$CLAUDE_CONFIG_DIR/projects" -type f -exec shasum {} + | sort
}
before_hash="$(hash_transcripts)"
sel="$(desk_retention_candidates 120 14 "$repo" "${files[@]}")"
ids="$(jq -r '[.[].id] | join(" ")' <<< "$sel")"
assert_eq "soonest first: past due, prefix-named, inside, edge" \
	"77777777-0009 0000aaaa-0008 aaaaaaaa-0001 eeeeeeee-0003" "$ids"
assert_eq "inside the margin: deletion date is mtime + 120 days" \
	"$(date_of $((NOW - 110 * day + 120 * day)))" "$(jq -r '.[] | select(.id == "aaaaaaaa-0001") | .deletion_date' <<< "$sel")"
assert_eq "inside the margin: days left" "10" "$(jq -r '.[] | select(.id == "aaaaaaaa-0001") | .days_left' <<< "$sel")"
assert_eq "exactly at the edge: 14 days left, included" "14" "$(jq -r '.[] | select(.id == "eeeeeeee-0003") | .days_left' <<< "$sel")"
assert_eq "already past due: today, 0 days left" "$(date_of "$NOW") 0" \
	"$(jq -r '.[] | select(.id == "77777777-0009") | "\(.deletion_date) \(.days_left)"' <<< "$sel")"
for x in bbbbbbbb-0002:"outside the margin" cccccccc-0004:"live" dddddddd-0005:"the runner's own" \
	ffffffff-0006:"ended as done" 99999999-0007:"not in the notes" 88888888-0010:"transcript outside the config dir"; do
	assert_true "left out: ${x#*:}" "$(jq -e --arg id "${x%%:*}" 'map(.id) | index($id) == null' > /dev/null <<< "$sel" && echo true || echo false)"
done
sel13="$(desk_retention_candidates 120 13 "$repo" "${files[@]}")"
assert_true "one day less margin drops the edge" "$(jq -e 'map(.id) | index("eeeeeeee-0003") == null' > /dev/null <<< "$sel13" && echo true || echo false)"

echo
echo "=== the real reader finds the same transcript ==="
real_tp="$CLAUDE_CONFIG_DIR/projects/-p/abcdef12-0000-0000-0000-000000000000.jsonl"
printf '%s\n' '{"type":"custom-title","customTitle":"alpha-work","sessionId":"abcdef12-0000-0000-0000-000000000000"}' > "$real_tp"
set_mtime "$real_tp" $((NOW - 110 * day))
real_sel="$(PATH="${PATH#"$FAKEBIN:"}" desk_retention_candidates 120 14 "$repo" "${files[@]}")"
assert_true "an unrecorded transcript named in the notes is selected" \
	"$(jq -e 'map(.id) | index("abcdef12-0000-0000-0000-000000000000") != null' > /dev/null <<< "$real_sel" && echo true || echo false)"
rm -f "$real_tp"

echo
echo "=== the step: items, guard, caps, dedup ==="
reply() { # id item-json
	jq -cn --argjson it "$2" '{items: [$it]}' > "$REPLIES/$1.json"
}
alpha_date="$(date_of $((NOW + 10 * day)))"
reply aaaaaaaa-0001 "$(jq -cn --arg d "$alpha_date" '{id:"r1", file:"notes.md", kind:"move",
	target:[{at:"- alpha-work: the thing"}, "top"],
	before:"- alpha-work: the thing\n  - waiting on review",
	after:("- alpha-work: the thing (transcript deleted " + $d + " unless resumed)\n  - waiting on review\n  - review requested, nothing merged yet [turn aaaaaaaa]"),
	source:"session:x", headline:"h"}')"
# A move that rewrites the user's line: guarded into a new item on top.
reply 0000aaaa-0008 '{"id":"r1","file":"notes.md","kind":"move","target":[{"at":"- an unnamed one: 0000aaaa"},"top"],"before":"- an unnamed one: 0000aaaa","after":"- unnamed: rewritten\n  - where it stood [turn 0000aaaa]","source":"session:x","headline":"h"}'
reply eeeeeeee-0003 '{"id":"r1","file":"notes.md","kind":"new","target":"top","before":"","after":"edge-work\n  - it stood here [turn eeeeeeee]","source":"session:x","headline":"h"}'
reply 77777777-0009 '{"id":"r1","file":"notes.md","kind":"new","target":"top","before":"","after":"past-work\n  - done-ish [turn 77777777]","source":"session:x","headline":"h"}'


PASS_SCRATCH="$(mktemp -d "$ROOT/pass.XXXX")"
step_json='{"id":"1630-retention","kind":"retention","prompt":"prompt.md","tools":["Read"],"cap":50,"timeout":30}'
printf 'session {{session_name}} {{session_id}} deleted {{deletion_date}} in {{days_left}}d, today {{today}}\n' > "$ROOT/prompt.md"
result="$(desk_step_retention "1630" "$step_json" '{}' "$repo" "2027-01-15" '{"act": 3}' "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
assert_eq "three calls under an act cap of 3, soonest first" "77777777-0009 0000aaaa-0008 aaaaaaaa-0001" "$(tr '\n' ' ' < "$CALLS" | sed 's/ $//')"
assert_eq "the overflow is counted for status" '{"act":1,"worth_knowing":0,"wildcard":0}' "$(cat "$PASS_SCRATCH/1630-retention-overflow.json")"
assert_true "the overflow is in the dated brief" \
	"$(grep -q 'edge-work: transcript deleted' "$DESK_BRIEF_DIR"/*.md 2> /dev/null && echo true || echo false)"
assert_true "the prompt got every placeholder" \
	"$(grep -qx "session alpha-work aaaaaaaa-0001 deleted $alpha_date in 10d, today $(date +%F)" "$ROOT/prompt-aaaaaaaa-0001.txt" && echo true || echo false)"

proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json 2> /dev/null)"
alpha="$(jq -c '.items[] | select(.session_id == "aaaaaaaa-0001")' <<< "$proposal")"
assert_eq "the move keeps its kind and anchors on its own first line" 'move [{"at":"- alpha-work: the thing"},"top"]' \
	"$(jq -c -r '"\(.kind) \(.target | tojson)"' <<< "$alpha")"
assert_eq "tier, kind of capture, headline" "act retention:$alpha_date alpha-work: transcript deleted $alpha_date" \
	"$(jq -r '"\(.tier) \(.capture_kind) \(.headline)"' <<< "$alpha")"
assert_true "the deletion date is in the text, the turn mark is not" \
	"$(jq -r .after <<< "$alpha" | grep -qF "$alpha_date" && ! jq -r .after <<< "$alpha" | grep -q '\[turn' && echo true || echo false)"
unnamed="$(jq -c '.items[] | select(.session_id == "0000aaaa-0008")' <<< "$proposal")"
assert_eq "a move that rewrites the user's line lands as new on top" "new \"top\" " \
	"$(jq -r '"\(.kind) \(.target | tojson) \(.before)"' <<< "$unnamed")"
assert_eq "...keeping its first line and added bullets, with the date appended" \
	"- unnamed: rewritten (transcript deleted $(date_of $((NOW + 9 * day))) unless resumed)|  - where it stood" \
	"$(jq -r '.after | split("\n") | join("|")' <<< "$unnamed")"
past="$(jq -c '.items[] | select(.session_id == "77777777-0009")' <<< "$proposal")"
assert_eq "an item without the date gets it on its first line" "past-work (transcript deleted $(date_of "$NOW") unless resumed)" \
	"$(jq -r '.after | split("\n")[0]' <<< "$past")"
applied="$(git -C "$repo" show refs/desk/proposal:notes.md)"
assert_eq "applied, the alpha entry sits on top once" "1" "$(grep -c 'alpha-work: the thing' <<< "$applied")"
assert_true "...and is gone from where it was" "$(sed -n '/^Inbox/,$p' <<< "$applied" | grep -q 'alpha-work' && echo false || echo true)"

echo
echo "=== a repeat pass, and a decline, bring nothing back ==="
cat > "$ROOT/decline.lua" << LUA
package.path = "$REPO_ROOT/nvim/lua/?.lua;" .. package.path
local ledger = require("desk.ledger")
local items = vim.json.decode(io.open("$ROOT/decline.json"):read("a"))
assert(ledger.record_declines("$repo", items))
LUA
jq -c '[.items[] | select(.session_id == "aaaaaaaa-0001")]' <<< "$proposal" > "$ROOT/decline.json"
nvim --headless -u NONE -l "$ROOT/decline.lua" > /dev/null 2>&1
: > "$CALLS"
result="$(desk_step_retention "1630" "$step_json" '{}' "$repo" "2027-01-16" '{"act": 3}' "${files[@]}")"
assert_eq "the repeat step reports ok" "ok" "$result"
assert_eq "only the overflowed session is called now" "eeeeeeee-0003" "$(tr '\n' ' ' < "$CALLS" | sed 's/ $//')"
assert_eq "the declined session's warning is not proposed again" "0" \
	"$(git -C "$repo" show refs/desk/proposal:proposal.json | jq '[.items[] | select(.session_id == "aaaaaaaa-0001")] | length')"

echo
echo "=== nothing wrote to a transcript ==="
assert_eq "every transcript's mtime and content are unchanged" "$before_hash" "$(hash_transcripts)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
