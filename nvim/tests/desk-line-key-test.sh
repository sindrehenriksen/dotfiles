#!/usr/bin/env bash
# Matching a quoted notes line ignores trailing whitespace and the agent
# mark with the whitespace before it, wherever the runner compares one:
# desk_before_is_committed (which URLs an edit's `before` lends its
# `after`), desk_item_at_problem (whether `at` is `before`'s first line)
# and desk_write_marked_head_copy (which lines a judge's copy marks as
# taken). A taken line that ends in a space loses it when the mark is
# stripped from a quote, and must still match. No model call.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"
export DESK_STATE_DIR="$ROOT/state"

for f in common lock status model-call git-ops tool-results validate steps; do
	# shellcheck disable=SC1090
	source "$LIB/$f.sh"
done

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n  - a taken line ending in a space \n  - see [the post](https://example.com/p)  \n' > "$repo/notes.md"
git -C "$repo" add notes.md
git -C "$repo" commit -q -m initial

echo "=== desk_before_is_committed ==="
item='{"kind":"edit","file":"notes.md"}'
yes_no() { if desk_before_is_committed "$item" "$1" "$repo"; then echo yes; else echo no; fi; }
assert_eq "a quote without the line's trailing space matches" yes "$(yes_no '  - see [the post](https://example.com/p)')"
assert_eq "so does one carrying the mark, the space before it dropped" yes "$(yes_no '  - a taken line ending in a space  <<agent-suggested>>')"
assert_eq "a different line still does not" no "$(yes_no '  - see the post')"

kept="$(desk_sanitize_item_text '{"kind":"edit","file":"notes.md","before":"  - see [the post](https://example.com/p)","after":"  - read [the post](https://example.com/p)","headline":"h"}' "" "$repo" | jq -r .after)"
assert_eq "so an edit keeps the URL its before carries, quoted without the trailing spaces" "  - read [the post](https://example.com/p)" "$kept"

echo "=== desk_item_at_problem ==="
at_check() { desk_item_at_problem "$(jq -cn --arg at "$1" --arg b "$2" '{target: {at: $at}, before: $b}')"; }
assert_eq "an at and a before marked with different whitespace agree" "" \
	"$(at_check '- a1  <<agent-suggested>>' $'- a1   <<agent-suggested>>\n  - under it')"
assert_eq "an at with a trailing space matches a before without it" "" "$(at_check '- a1 ' '- a1')"
assert_eq "a mark mid-line goes with the whitespace before it, as desk_line_key drops it" "" "$(at_check '- a1   <<agent-suggested>> more' '- a1 more')"
assert_eq "another line is still refused" 'its at line "- b1" is not the first line of before ("- a1")' "$(at_check '- b1' '- a1')"

echo "=== desk_write_marked_head_copy ==="
desk_nvim_cli() { [ "$1" = taken-lines ] && jq -cn '{lines: ["  - a taken line ending in a space"]}'; }
desk_write_marked_head_copy "$repo" notes.md "$ROOT/copy.md"
assert_eq "a taken line whose trailing space changed is marked" \
	"  - a taken line ending in a space   <<agent-suggested>>" "$(sed -n 2p "$ROOT/copy.md")"
assert_eq "the other lines are copied as they stand" "Section A|  - see [the post](https://example.com/p)  " "$(sed -n '1p;3p' "$ROOT/copy.md" | paste -sd'|' -)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
