#!/usr/bin/env bash
# D8b test: the weekly tab's notes-diff (weekly/README.md's "holding the
# runner's fenced notes-diff.md") — nvim/lua/desk/cli.lua's own `notes-diff`
# verb (the diffing + ledger-based exclusion, reusing desk.ledger/desk.snippet
# rather than a second normalization here) and claude/desk-lib/steps.sh's
# desk_write_notes_diff/desk_last_weekday_epoch (the since-commit resolution
# and rendering around it). Three from-scratch-repo scenarios drive the verb
# directly: his own edit is kept, an accepted agent line is excluded even
# after it was moved elsewhere in the file, and an accepted agent removal is
# excluded — the two exclusion mechanisms this feature relies on (an after-
# snippet match via desk.ledger.derive_all's own accepted/pending states, and
# a before-content match via the ledger's own accept key records, position-
# independent on purpose — see cli.lua's own comment on why removals can't
# use derive_all's state the way additions do). No live model call, nothing
# pushed anywhere.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"
CLI="$HERE/../lua/desk/cli.lua"

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

# ---------------------------------------------------------------------------
# The from-scratch repo + ledger: an agent-suggested line accepted, then
# moved by a later accepted `move`; an agent-suggested removal accepted; and
# a line only he ever touched.
# ---------------------------------------------------------------------------
repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"

printf 'Alpha: existing block\nGamma: agent-suggested content\nBeta: existing block\nEpsilon: to be removed by agent\n' \
	> "$repo/notes.md"
git -C "$repo" add notes.md
# Backdated well before any real "last Wednesday" cutoff (desk_write_notes_diff's
# own "last_wednesday" test below runs against the real wall clock, unlike the
# fixed-input desk_last_weekday_epoch check above it) — so that check always
# resolves "since" back to exactly this commit, never an ambiguous one.
GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
	git -C "$repo" commit -q -m initial
since_sha="$(git -C "$repo" rev-parse HEAD)"

printf 'Alpha: existing block\nBeta: existing block\nGamma: agent-suggested content\nHis own new line\n' \
	> "$repo/notes.md"
git -C "$repo" add notes.md
git -C "$repo" commit -q -m "his edit plus the accepted move/removal"

recs="$ROOT/ledger-recs.ndjson"
cat > "$recs" <<'EOF'
{"type":"item","id":"move1","kind":"move","file":"notes.md","anchor":[{"at":"Gamma: agent-suggested content"},{"under":"Beta: existing block"}],"before":"Gamma: agent-suggested content","after":"Gamma: agent-suggested content","source":"test","headline":"moved"}
{"type":"item","id":"remove1","kind":"remove","file":"notes.md","anchor":{"at":"Epsilon: to be removed by agent"},"before":"Epsilon: to be removed by agent","after":"","source":"test","headline":"removed"}
{"type":"laid_in","at":1,"proposal":"p1","items":["move1","remove1"]}
{"type":"key","id":"move1","at":2,"action":"accept"}
{"type":"key","id":"remove1","at":2,"action":"accept"}
EOF
nvim -l "$CLI" ledger-append-batch "$repo" "$recs" > /dev/null

echo "=== cli.lua notes-diff: the three scenarios ==="
out="$(nvim -l "$CLI" notes-diff "$repo" notes.md "$since_sha")"
assert_true "valid JSON" "$(jq -e . > /dev/null 2>&1 <<< "$out" && echo true || echo false)"

additions="$(jq -c '.additions' <<< "$out")"
removals="$(jq -c '.removals' <<< "$out")"

assert_true "his own new line is kept as an addition" \
	"$(jq -e '. == ["His own new line"]' > /dev/null 2>&1 <<< "$additions" && echo true || echo false)"
assert_true "the accepted, later-moved agent line never shows up as an addition" \
	"$(jq -e 'index("Gamma: agent-suggested content") == null' > /dev/null 2>&1 <<< "$additions" && echo true || echo false)"
assert_true "the accepted, later-moved agent line never shows up as a removal either" \
	"$(jq -e 'index("Gamma: agent-suggested content") == null' > /dev/null 2>&1 <<< "$removals" && echo true || echo false)"
assert_true "the accepted agent removal never shows up as a removal" \
	"$(jq -e 'index("Epsilon: to be removed by agent") == null' > /dev/null 2>&1 <<< "$removals" && echo true || echo false)"
assert_true "no removal is left unaccounted for (only the excluded one dropped)" \
	"$(jq -e '. == []' > /dev/null 2>&1 <<< "$removals" && echo true || echo false)"

echo
echo "=== cli.lua notes-diff: an unresolvable since fails loudly, not silently ==="
bad_out="$(nvim -l "$CLI" notes-diff "$repo" notes.md "not-a-real-ref" 2> /dev/null)"
assert_true "an error key is present" "$(jq -e '.error' > /dev/null 2>&1 <<< "$bad_out" && echo true || echo false)"

echo
echo "=== cli.lua notes-diff: a file untouched by the ledger reports cleanly ==="
: > "$repo/reading.md"
git -C "$repo" add reading.md
git -C "$repo" commit -q -m "add reading.md"
reading_out="$(nvim -l "$CLI" notes-diff "$repo" reading.md "$since_sha")"
assert_true "additions/removals both empty, no error" \
	"$(jq -e '.additions == [] and .removals == [] and (.error | not)' > /dev/null 2>&1 <<< "$reading_out" && echo true || echo false)"

# ---------------------------------------------------------------------------
# steps.sh's own bash-level wiring: desk_last_weekday_epoch (a pure function
# of "now", checked against fixed inputs) and desk_write_notes_diff (the
# since-commit resolution + fenced rendering around the verb above).
# ---------------------------------------------------------------------------
# Without this, common.sh's own `mkdir -p "$DESK_STATE_DIR" ...` (sourced
# next) falls through to its real $HOME-based default and creates empty
# dirs under the real ~/.local/state/desk/ the moment it's sourced.
export DESK_STATE_DIR="$ROOT/state"
# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

echo
echo "=== desk_last_weekday_epoch: never today's own occurrence ==="
# 2026-09-30 is a Wednesday; "now" is that same Wednesday morning, so the
# most recent Wednesday strictly before it is a full week earlier.
now_wed="$(date -j -f "%Y-%m-%d %H:%M:%S" "2026-09-30 07:00:00" +%s 2> /dev/null \
	|| date -d "2026-09-30 07:00:00" +%s)"
epoch="$(desk_last_weekday_epoch "$now_wed" 3 8 0)"
got="$(date -j -r "$epoch" '+%Y-%m-%d %H:%M %u' 2> /dev/null || date -d "@$epoch" '+%Y-%m-%d %H:%M %u')"
assert_eq "last Wednesday 08:00, not this morning's" "2026-09-23 08:00 3" "$got"

echo
echo "=== desk_write_notes_diff: renders a fenced file across both configured files ==="
out_file="$ROOT/notes-diff.md"
desk_write_notes_diff "$repo" "$out_file" "last_wednesday" notes.md reading.md
content="$(cat "$out_file")"
assert_true "opens with the fenced header" "$(head -1 "$out_file" | grep -q '^# Notes diff' && echo true || echo false)"
assert_true "notes.md section present" "$(grep -q '^== notes.md ==' "$out_file" && echo true || echo false)"
assert_true "reading.md section present" "$(grep -q '^== reading.md ==' "$out_file" && echo true || echo false)"
assert_true "his own new line rendered as an addition" "$(grep -qF '+ His own new line' "$out_file" && echo true || echo false)"
assert_true "the moved agent line is nowhere in the file" \
	"$([ ! "$(grep -F 'Gamma: agent-suggested content' "$out_file")" ] && echo true || echo false)"
assert_true "the removed agent line is nowhere in the file" \
	"$([ ! "$(grep -F 'Epsilon: to be removed by agent' "$out_file")" ] && echo true || echo false)"
assert_true "reading.md (untouched, no changes) says so" "$(grep -q '(no changes)' "$out_file" && echo true || echo false)"
assert_true "the whole diff body is fenced" "$(grep -c '^```$' "$out_file" | grep -qx 2 && echo true || echo false)"

echo
echo "=== desk_write_notes_diff: an unknown notes_diff_since falls back to the empty tree, never fails ==="
out_file2="$ROOT/notes-diff-bogus.md"
desk_write_notes_diff "$repo" "$out_file2" "bogus_kind" notes.md 2> /dev/null
assert_true "a file is still written" "$([ -s "$out_file2" ] && echo true || echo false)"
assert_true "the whole (since-the-beginning) notes.md content shows as additions" \
	"$(grep -qF '+ Alpha: existing block' "$out_file2" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
