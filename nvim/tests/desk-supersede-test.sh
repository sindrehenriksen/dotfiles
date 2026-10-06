#!/usr/bin/env bash
# claude/desk-lib/git-ops.sh's desk_stage_and_write_proposal: an untaken
# item from the last proposal is carried into the next (a "not now"), and a
# new item replaces a carried one only when it names it (`supersedes: <id>`),
# shares its `source`, or is an in-place edit/remove/move/merge of the same
# existing line. Insertions (`add`, `new`) never supersede by place: two
# unrelated items under one heading or at "top" are two suggestions.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

export DESK_STATE_DIR="$ROOT/state"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/git-ops.sh
source "$LIB/git-ops.sh"

new_repo() {
	local repo="$1"
	desk_test_assert_repo_under_root "$repo" "$ROOT"
	mkdir -p "$repo"
	git -C "$repo" init -q
	printf 'Section A\n' > "$repo/notes.md"
	: > "$repo/reading.md"
	git -C "$repo" add notes.md reading.md
	git -C "$repo" commit -q -m initial
	local seed="$ROOT/seed.json"
	jq -n '{items: [
		{id:"p1", file:"notes.md", kind:"add", target:{under:"Section A"}, before:"", after:"  carried add", source:"https://example.com/p1", headline:"p1"},
		{id:"q1", file:"notes.md", kind:"new", target:"top", before:"", after:"NEWS Q1", source:"https://example.com/q1", headline:"q1"}
	]}' > "$seed"
	desk_stage_and_write_proposal "$repo" "morning" "2026-09-27" "$seed" notes.md reading.md > /dev/null
}

has_headline() { # proposal-json headline
	jq -e --arg h "$2" '.items[] | select(.headline == $h)' > /dev/null 2>&1 <<< "$1" && echo true || echo false
}

echo "=== untaken items are carried into the next pass (a not-now), with the new ones on top ==="
repo="$ROOT/notes-a"
new_repo "$repo"
items="$ROOT/items-a.json"
jq -n '{items: [{id:"n1", file:"notes.md", kind:"new", target:"top", before:"", after:"NEWS N1", source:"https://example.com/n1", headline:"n1"}]}' > "$items"
desk_stage_and_write_proposal "$repo" "morning" "2026-09-28" "$items" notes.md reading.md > /dev/null
proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "p1 carried" "$(has_headline "$proposal" p1)"
assert_true "q1 carried" "$(has_headline "$proposal" q1)"
assert_true "n1 new" "$(has_headline "$proposal" n1)"
assert_true "the new item is first" "$(jq -e '.items[0].headline == "n1"' > /dev/null 2>&1 <<< "$proposal" && echo true || echo false)"

echo
echo "=== a same-source new item supersedes the carried one, even with a different (target, kind) ==="
repo="$ROOT/notes-b"
new_repo "$repo"
items="$ROOT/items-b.json"
jq -n '{items: [{id:"a1", file:"notes.md", kind:"add", target:{after:"Section A"}, before:"", after:"  a1", source:"https://example.com/q1", headline:"a1"}]}' > "$items"
desk_stage_and_write_proposal "$repo" "morning" "2026-09-28" "$items" notes.md reading.md > /dev/null
proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "q1 (same source) is dropped, superseded" "$([ "$(has_headline "$proposal" q1)" = false ] && echo true || echo false)"
assert_true "the new item a1 is present" "$(has_headline "$proposal" a1)"
assert_true "p1 is still carried" "$(has_headline "$proposal" p1)"

echo
echo "=== a same (target, kind) 'top' new item does NOT supersede: two news items coexist ==="
repo="$ROOT/notes-c"
new_repo "$repo"
items="$ROOT/items-c.json"
jq -n '{items: [{id:"b1", file:"notes.md", kind:"new", target:"top", before:"", after:"NEWS B1", source:"https://example.com/unrelated-b", headline:"b1"}]}' > "$items"
desk_stage_and_write_proposal "$repo" "morning" "2026-09-29" "$items" notes.md reading.md > /dev/null
proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "q1 survives" "$(has_headline "$proposal" q1)"
assert_true "b1 is present too" "$(has_headline "$proposal" b1)"

echo
echo "=== an explicit 'supersedes: <id>' drops it regardless of target/kind/source ==="
repo="$ROOT/notes-d"
new_repo "$repo"
q1_id="$(git -C "$repo" show refs/desk/proposal:proposal.json | jq -r '.items[] | select(.headline == "q1") | .id')"
items="$ROOT/items-d.json"
jq -n --arg id "$q1_id" '{items: [{id:"c1", file:"notes.md", kind:"add", target:{after:"Section A"}, before:"", after:"  c1", source:"https://example.com/unrelated-c", supersedes:$id, headline:"c1"}]}' > "$items"
desk_stage_and_write_proposal "$repo" "morning" "2026-09-30" "$items" notes.md reading.md > /dev/null
proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "q1 is dropped, explicitly superseded" "$([ "$(has_headline "$proposal" q1)" = false ] && echo true || echo false)"

echo
echo "=== two adds under the same heading are two suggestions, not one replacing the other ==="
repo="$ROOT/notes-e"
new_repo "$repo"
items="$ROOT/items-e.json"
jq -n '{items: [{id:"d1", file:"notes.md", kind:"add", target:{under:"Section A"}, before:"", after:"  a newer take", headline:"d1"}]}' > "$items"
desk_stage_and_write_proposal "$repo" "morning" "2026-10-01" "$items" notes.md reading.md > /dev/null
proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "p1 (same heading, same kind) is still carried" "$(has_headline "$proposal" p1)"
assert_true "d1 is present" "$(has_headline "$proposal" d1)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
