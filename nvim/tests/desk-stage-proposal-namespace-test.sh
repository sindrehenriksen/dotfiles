#!/usr/bin/env bash
# D8 fix test (review item #10): claude/desk-lib/git-ops.sh's
# desk_stage_and_write_proposal namespaces every new item's own (model-
# assigned) id inside the proposal builder (desk.ledger.namespace_ids)
# before anything is written into the proposal — a model's own promise of id uniqueness only ever holds within
# its own single reply, so two different calls this same scheduled date
# reusing the same literal id (a real, likely scenario: a judge call and a
# close capture both handing back "id": "c1") must never collide in the
# proposal.
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

export DESK_STATE_DIR="$ROOT/state"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/git-ops.sh
source "$LIB/git-ops.sh"

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial

echo "=== a new item's id is namespaced, never the model's own literal id ==="
items1="$ROOT/items1.json"
jq -n '{items: [{id:"c1", file:"notes.md", kind:"new", target:"top", before:"", after:"first", source:"test-one", headline:"h1"}]}' > "$items1"
sha1="$(desk_stage_and_write_proposal "$repo" "morning" "2026-09-28" "$items1" notes.md reading.md)"
assert_true "staging succeeds" "$([ -n "$sha1" ] && echo true || echo false)"
proposal1="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "the literal model id 'c1' never appears bare" \
	"$(jq -e '.items[] | select(.id == "c1")' > /dev/null 2>&1 <<< "$proposal1" && echo false || echo true)"
assert_true "the namespaced id carries the pass/date and the model's own id" \
	"$(jq -e '.items[] | select(.id == "morning-2026-09-28-1-c1")' > /dev/null 2>&1 <<< "$proposal1" && echo true || echo false)"

echo
echo "=== a second call the same scheduled date, reusing the model's own id 'c1', never collides ==="
items2="$ROOT/items2.json"
jq -n '{items: [{id:"c1", file:"notes.md", kind:"new", target:"top", before:"", after:"second", source:"test-two", headline:"h2"}]}' > "$items2"
sha2="$(desk_stage_and_write_proposal "$repo" "morning" "2026-09-28" "$items2" notes.md reading.md)"
assert_true "the second staging also succeeds" "$([ -n "$sha2" ] && echo true || echo false)"
proposal2="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "both namespaced items are present, distinctly" \
	"$(jq -e '[.items[] | select(.id == "morning-2026-09-28-1-c1" or .id == "morning-2026-09-28-2-c1")] | length == 2' \
		> /dev/null 2>&1 <<< "$proposal2" && echo true || echo false)"
first_after="$(jq -r '.items[] | select(.id == "morning-2026-09-28-1-c1") | .after' <<< "$proposal2")"
assert_eq "the first item's own content is untouched by the second call" "first" "$first_after"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
