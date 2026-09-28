#!/usr/bin/env bash
# claude/desk-lib/git-ops.sh's desk_stage_and_write_proposal, against
# design.md's "Review rounds" section: supersede a postponed item only on
# an explicit `supersedes: <id>` or a shared `source`, or on (target, kind)
# when the target isn't "top" (design's own reason: every news item lands
# on "top", so two independent ones sharing kind "new" must never read as
# the same suggestion); a pending item is never re-proposed — it's only
# ever used to dedup a new item that would duplicate it.
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

# --- seed one PENDING item (p1: still sitting, unstaged, in the worktree)
# and one POSTPONED item (q1: laid in, then "not now"'d — content back to
# HEAD in both index and worktree, a not_now key record is what turns its
# content-derived "declined" into "postponed") ------------------------------

ledger_records="$ROOT/seed.ndjson"
now=$(( $(date +%s) - 3600 ))
cat > "$ledger_records" <<EOF
{"type":"item","id":"p1","file":"notes.md","kind":"add","anchor":{"under":"Section A"},"before":"","after":"  pending suggestion","source":"https://example.com/p1","headline":"p1","proposed_at":$now}
{"type":"item","id":"q1","file":"notes.md","kind":"new","anchor":"top","before":"","after":"NEWS Q1","source":"https://example.com/q1","headline":"q1","proposed_at":$now}
{"type":"round","file":"notes.md","at":$now,"text":["Section A","  pending suggestion"],"items":{"p1":{"kind":"add","ranges":[{"line":2,"count":1,"role":"edit"}]},"q1":{"kind":"new","ranges":[{"line":1,"count":1,"role":"edit"}]}}}
{"type":"laid_in","at":$now,"proposal":"seed","items":["p1","q1"]}
{"type":"key","id":"q1","at":$now,"action":"not_now"}
EOF
desk_nvim_cli ledger-append-batch "$repo" "$ledger_records" > /dev/null

# Worktree: p1's suggestion still sitting (pending); q1's reset back to
# HEAD (its not_now key is what makes that content-identical-to-decline
# state read as "postponed" rather than "declined").
printf 'Section A\n  pending suggestion\n' > "$repo/notes.md"

echo "=== a same-source new item supersedes the postponed one, even with a different (target, kind) ==="
items_a="$ROOT/items-a.json"
jq -n '{items: [{id:"a1", file:"notes.md", kind:"add", target:{after:"Section A"}, before:"", after:"  a1", source:"https://example.com/q1", headline:"a1"}]}' > "$items_a"
sha_a="$(desk_stage_and_write_proposal "$repo" "morning" "2026-09-28" "$items_a" notes.md reading.md)"
assert_true "staging succeeds" "$([ -n "$sha_a" ] && echo true || echo false)"
proposal_a="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "q1 (same source) is dropped, superseded" \
	"$(jq -e '.items[] | select(.id == "q1")' > /dev/null 2>&1 <<< "$proposal_a" && echo false || echo true)"
assert_true "the new item a1 is present" \
	"$(jq -e '.items[] | select(.id == "morning-2026-09-28-1-a1")' > /dev/null 2>&1 <<< "$proposal_a" && echo true || echo false)"

echo
echo "=== a same (target, kind) 'top' new item does NOT supersede — two independent news items coexist ==="
items_b="$ROOT/items-b.json"
jq -n '{items: [{id:"b1", file:"notes.md", kind:"new", target:"top", before:"", after:"NEWS B1", source:"https://example.com/unrelated-b", headline:"b1"}]}' > "$items_b"
sha_b="$(desk_stage_and_write_proposal "$repo" "morning" "2026-09-29" "$items_b" notes.md reading.md)"
assert_true "staging succeeds" "$([ -n "$sha_b" ] && echo true || echo false)"
proposal_b="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "q1 survives — 'top' is exempt from (target, kind) supersession" \
	"$(jq -e '.items[] | select(.id == "q1")' > /dev/null 2>&1 <<< "$proposal_b" && echo true || echo false)"
assert_true "the new item b1 is ALSO present — both coexist" \
	"$(jq -e '.items[] | select(.id == "morning-2026-09-29-1-b1")' > /dev/null 2>&1 <<< "$proposal_b" && echo true || echo false)"

echo
echo "=== an explicit 'supersedes: q1' drops it regardless of target/kind/source ==="
items_c="$ROOT/items-c.json"
jq -n '{items: [{id:"c1", file:"notes.md", kind:"add", target:{after:"Section A"}, before:"", after:"  c1", source:"https://example.com/unrelated-c", supersedes:"q1", headline:"c1"}]}' > "$items_c"
sha_c="$(desk_stage_and_write_proposal "$repo" "morning" "2026-09-30" "$items_c" notes.md reading.md)"
assert_true "staging succeeds" "$([ -n "$sha_c" ] && echo true || echo false)"
proposal_c="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "q1 is dropped, explicitly superseded" \
	"$(jq -e '.items[] | select(.id == "q1")' > /dev/null 2>&1 <<< "$proposal_c" && echo false || echo true)"

echo
echo "=== a new item matching the PENDING item p1 (target, kind, non-top) is dropped — never re-proposed ==="
items_d="$ROOT/items-d.json"
jq -n '{items: [{id:"d1", file:"notes.md", kind:"add", target:{under:"Section A"}, before:"", after:"  a duplicate of p1", headline:"d1"}]}' > "$items_d"
sha_d="$(desk_stage_and_write_proposal "$repo" "morning" "2026-10-01" "$items_d" notes.md reading.md)"
assert_true "staging succeeds" "$([ -n "$sha_d" ] && echo true || echo false)"
proposal_d="$(git -C "$repo" show refs/desk/proposal:proposal.json)"
assert_true "d1 never appears — it duplicated a currently-pending item" \
	"$(jq -e '.items[] | select(.headline == "d1")' > /dev/null 2>&1 <<< "$proposal_d" && echo false || echo true)"
assert_true "p1 itself is still never carried forward as a separate proposal entry (it's pending, not queued/postponed)" \
	"$(jq -e '.items[] | select(.id == "p1")' > /dev/null 2>&1 <<< "$proposal_d" && echo false || echo true)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
