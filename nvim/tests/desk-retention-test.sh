#!/usr/bin/env bash
# claude/desk-lib/retention.sh: the cutoff read from a temp settings file,
# which sessions are selected (fake transcripts with set mtimes in a temp
# CLAUDE_CONFIG_DIR, against a fixed clock), what the step lists for the
# brief, that it calls no model and stages nothing, dedup on a decline, and
# that no transcript is written. The reader is faked for selection and the
# real one is run once against the same temp config dir.
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

export PATH="$FAKEBIN:$PATH"

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
	entry ffffffff-0006 done-work 110 '{"ended":true,"end_reason":"prompt_input_exit","end_deliberate":true}'
	entry 99999999-0007 unmentioned-work 110
	entry 0000aaaa-0008 "Some auto title" 111 '{"name_source":"ai_or_none"}'
	entry 77777777-0009 past-work 125           # already past due
	jq -cn --arg tp "$outside_tp" '{id:"88888888-0010", name:"elsewhere-work", name_source:"user", live:false, transcript_path:$tp}'
} > "$SESSION_STATUS_FIXTURE"
# Done is the reader's end_deliberate, minus a close by a pass: a resumed-away
# session is done, a pass-closed or shut-down one still gets its warning.
{
	entry 11111111-0011 alpha-work 110 '{"ended":true,"end_reason":"resume","end_deliberate":true}'
	entry 22222222-0012 alpha-work 110 '{"ended":true,"end_reason":"closed-by-pass","end_deliberate":true}'
	entry 33333333-0013 alpha-work 110 '{"ended":true,"end_reason":"other","end_deliberate":false}'
} > "$ROOT/end-reasons.jsonl"
cp "$SESSION_STATUS_FIXTURE" "$ROOT/main-fixture.jsonl"
cp "$ROOT/end-reasons.jsonl" "$SESSION_STATUS_FIXTURE"
ended_ids="$(desk_retention_candidates 120 14 "$repo" "${files[@]}" | jq -r '[.[].id] | sort | join(" ")')"
cp "$ROOT/main-fixture.jsonl" "$SESSION_STATUS_FIXTURE"
assert_eq "a resume is done; a close by a pass and a shutdown are not" "22222222-0012 33333333-0013" "$ended_ids"
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
assert_eq "already past due: its real date, 0 days left" "$(date_of $((NOW - 125 * day + 120 * day))) 0" \
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
# This checkout's reader, not whichever one is installed on PATH.
REALBIN="$ROOT/realbin"
mkdir -p "$REALBIN"
ln -sf "$HERE/../../claude/session-status.sh" "$REALBIN/session-status.sh"
real_sel="$(PATH="$REALBIN:${PATH#"$FAKEBIN:"}" desk_retention_candidates 120 14 "$repo" "${files[@]}")"
assert_true "an unrecorded transcript named in the notes is selected" \
	"$(jq -e 'map(.id) | index("abcdef12-0000-0000-0000-000000000000") != null' > /dev/null <<< "$real_sel" && echo true || echo false)"
rm -f "$real_tp"

echo
echo "=== the step lists the sessions for the brief, and stages nothing ==="
PASS_SCRATCH="$(mktemp -d "$ROOT/pass.XXXX")"
step_json='{"id":"retention","kind":"retention"}'
cfg_brief='{"passes": {"morning": {"brief": {"instructions": ["x.md"]}}}}'
result="$(desk_step_retention "morning" "$step_json" "$cfg_brief" "$repo" "2027-01-15" "${files[@]}")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "nothing staged" "$(git -C "$repo" rev-parse -q --verify refs/desk/proposal > /dev/null && echo false || echo true)"
listed="$DESK_RUNS_ROOT/morning-2027-01-15/retention/candidates.json"
alpha_date="$(date_of $((NOW + 10 * day)))"
assert_eq "every candidate is listed, soonest first, with no cap" \
	"77777777-0009 0000aaaa-0008 aaaaaaaa-0001 eeeeeeee-0003" "$(jq -r '[.[].session_id] | join(" ")' "$listed")"
assert_eq "each with its label, deletion date and days left" "alpha-work $alpha_date 10" \
	"$(jq -r '.[] | select(.session_id == "aaaaaaaa-0001") | "\(.name) \(.deletion_date) \(.days_left)"' "$listed")"
assert_eq "an unnamed one by its auto title and short id" "Some auto title · 0000aaaa" \
	"$(jq -r '.[] | select(.session_id == "0000aaaa-0008") | .name' "$listed")"
adir="$(jq -r '.[] | select(.session_id == "aaaaaaaa-0001") | .dir' "$listed")"
assert_true "its directory holds the reader entry and a readable transcript" \
	"$(jq -e '.label == "alpha-work" and .deletion_date != null' "$adir/session.json" > /dev/null && grep -q 'aaaaaaaa' "$adir/transcript.txt" && echo true || echo false)"
result="$(desk_step_retention "otherpass" "$step_json" "$cfg_brief" "$repo" "2027-01-15" "${files[@]}")"
assert_true "a pass with no brief lists none" "$([ "$result" = ok ] && [ ! -e "$DESK_RUNS_ROOT/otherpass-2027-01-15/retention" ] && echo true || echo false)"

echo
echo "=== a warning the ledger already holds is not listed again ==="
cat > "$ROOT/decline.lua" << LUA
package.path = "$REPO_ROOT/nvim/lua/?.lua;" .. package.path
local ledger = require("desk.ledger")
local items = vim.json.decode(io.open("$ROOT/decline.json"):read("a"))
assert(ledger.record_declines("$repo", items))
LUA
jq -cn --arg d "$alpha_date" '[{id: "morning-2027-01-15-1-r1", file: "notes.md", kind: "new", target: "top", before: "",
	after: "alpha-work (transcript deleted \($d) unless resumed)", source: "session:aaaaaaaa-0001", headline: "alpha-work: transcript deleted \($d)",
	session_id: "aaaaaaaa-0001", capture_kind: ("retention:" + $d)}]' > "$ROOT/decline.json"
nvim --headless -u NONE -l "$ROOT/decline.lua" > /dev/null 2>&1
desk_step_retention "morning" "$step_json" "$cfg_brief" "$repo" "2027-01-16" "${files[@]}" > /dev/null
assert_eq "the declined session is left out" "77777777-0009 0000aaaa-0008 eeeeeeee-0003" \
	"$(jq -r '[.[].session_id] | join(" ")' "$DESK_RUNS_ROOT/morning-2027-01-16/retention/candidates.json")"

echo
echo "=== nothing wrote to a transcript ==="
assert_eq "every transcript's mtime and content are unchanged" "$before_hash" "$(hash_transcripts)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
