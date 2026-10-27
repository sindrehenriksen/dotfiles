#!/usr/bin/env bash
# Matching a quoted notes line ignores trailing whitespace and the agent
# mark with the whitespace before it, wherever the runner compares one:
# desk_item_at_problem (whether `at` is `before`'s first line) and
# desk_write_marked_head_copy (which lines a seeded copy marks as taken). A taken line that ends in a space loses it when the mark is
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

for f in common lock status model-call tool-results validate steps; do
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

echo "=== desk_item_at_problem ==="
at_check() { desk_item_at_problem "$(jq -cn --arg at "$1" --arg b "$2" '{target: {at: $at}, before: $b}')"; }
assert_eq "an at and a before marked with different whitespace agree" "" \
	"$(at_check '- a1  <<agent-suggested>>' $'- a1   <<agent-suggested>>\n  - under it')"
assert_eq "an at with a trailing space matches a before without it" "" "$(at_check '- a1 ' '- a1')"
assert_eq "a mark mid-line is part of the line, as placement reads it" "" "$(at_check '- a1   <<agent-suggested>> more' '- a1   <<agent-suggested>> more ')"
assert_eq "another line is still refused" 'its at line "- b1" is not the first line of before ("- a1")' "$(at_check '- b1' '- a1')"

echo "=== the runner's line rule is placement's (snippet.line_key) ==="
cases="$ROOT/line-cases.txt"
printf '%s\n' '- plain' '- trailing  ' $'- tab\t' '- marked  <<agent-suggested>>' '- spaced end   <<agent-suggested>>  ' \
	'- mid <<agent-suggested>> line' '<<agent-suggested>>' '  indented line ' > "$cases"
lua_keys="$(nvim -l /dev/stdin "$HERE/../lua" "$cases" <<'LUA'
package.path = arg[1] .. "/?.lua;" .. package.path
local snippet = require("desk.snippet")
for l in io.lines(arg[2]) do io.write(snippet.line_key(l), "\n") end
LUA
)"
assert_eq "desk_line_key gives every case the key snippet.line_key gives it" "$lua_keys" "$(desk_line_key < "$cases")"
jq_keys="$(while IFS= read -r l; do
	desk_item_at_problem "$(jq -cn --arg at "$l" --arg b "$(printf '%s' "$lua_keys" | sed -n "$(grep -nxF -- "$l" "$cases" | head -n1 | cut -d: -f1)p")" '{target: {at: $at}, before: $b}')"
done < "$cases")"
assert_eq "and the at check counts each case equal to its key" "" "$(grep -v 'shorter than three' <<< "$jq_keys" | sed '/^$/d')"

echo "=== desk_write_marked_head_copy ==="
desk_nvim_cli() { [ "$1" = taken-lines ] && jq -cn '{lines: ["  - a taken line ending in a space"]}'; }
desk_write_marked_head_copy "$repo" notes.md "$ROOT/copy.md"
assert_eq "a taken line whose trailing space changed is marked" \
	"  - a taken line ending in a space   <<agent-suggested>>" "$(sed -n 2p "$ROOT/copy.md")"
assert_eq "the other lines are copied as they stand" "Section A|  - see [the post](https://example.com/p)  " "$(sed -n '1p;3p' "$ROOT/copy.md" | paste -sd'|' -)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
