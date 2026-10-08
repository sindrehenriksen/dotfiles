#!/usr/bin/env bash
# claude/desk-propose: a session staging suggestions into the desk proposal.
# A from-scratch notes repo and config; checks what reaches refs/desk/proposal
# (namespaced, cleaned, carried across calls, superseding), and that an item
# that does not fit the shape stages nothing. No model call, nothing pushed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROPOSE="$HERE/../../claude/desk-propose"
CLI="$HERE/../lua/desk/cli.lua"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"
export DESK_STATE_DIR="$ROOT/state"

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Weekly\n  - posts drafted\n' > "$repo/notes.md"
: > "$repo/reading.md"
: > "$repo/.desk-notes"
git -C "$repo" add -A
git -C "$repo" commit -q -m initial

jq -n --arg r "$repo" '{notes_repo: $r, files: ["notes.md", "reading.md"]}' > "$ROOT/config.json"
export DESK_CONFIG="$ROOT/config.json"

proposal_items() { nvim -l "$CLI" proposal-read "$repo" | jq -c '.items'; }

echo "=== staging a session's items ==="
jq -n '{items: [
	{id: "answer", file: "notes.md", kind: "add", target: {under: "Weekly"},
	 before: "", after: "  - his answer: ship it on Friday\u001b[31m", headline: "His answer on the release", source: "notes"},
	{id: "ticket", file: "notes.md", kind: "add", target: {under: "Weekly"},
	 before: "", after: "  - [Ticket for the follow-up](https://tickets.example.com/browse/ABC-9)", headline: "Ticket created", source: "https://tickets.example.com/browse/ABC-9", tier: "worth_knowing"}
]}' > "$ROOT/items.json"
out="$("$PROPOSE" --pass weekly --date 2026-10-07 "$ROOT/items.json")"
assert_eq "it stages and says so" "0" "$?"
case "$out" in "staged: 2 new, "*) ok "...two new items" ;; *) bad "...two new items (got [$out])" ;; esac
items="$(proposal_items)"
assert_eq "ids are namespaced to the pass and date" '["weekly-2026-10-07-1-answer","weekly-2026-10-07-2-ticket"]' "$(jq -c 'map(.id)' <<< "$items")"
assert_eq "control characters are stripped" "  - his answer: ship it on Friday" "$(jq -r '.[0].after' <<< "$items")"
assert_eq "the session's own URL is kept" "  - [Ticket for the follow-up](https://tickets.example.com/browse/ABC-9)" "$(jq -r '.[1].after' <<< "$items")"
assert_eq "the proposal applies them to the notes" "Weekly|  - posts drafted|  - his answer: ship it on Friday|  - [Ticket for the follow-up](https://tickets.example.com/browse/ABC-9)" \
	"$(git -C "$repo" show refs/desk/proposal:notes.md | paste -sd'|' -)"
assert_eq "the notes file itself is untouched" "Weekly|  - posts drafted" "$(paste -sd'|' - < "$repo/notes.md")"

echo "=== a second call carries the first's items, and can replace one ==="
jq -n '[{id: "answer2", file: "notes.md", kind: "add", target: {under: "Weekly"}, before: "",
	after: "  - his answer: ship it on Monday", headline: "His corrected answer", source: "notes",
	supersedes: "weekly-2026-10-07-1-answer"}]' > "$ROOT/items2.json"
"$PROPOSE" --pass weekly --date 2026-10-07 "$ROOT/items2.json" > /dev/null
assert_eq "the superseded item is gone, the other still waits" \
	'["weekly-2026-10-07-1-answer2","weekly-2026-10-07-2-ticket"]' "$(proposal_items | jq -c 'map(.id) | sort')"

echo "=== an item that does not fit stages nothing ==="
before_sha="$(git -C "$repo" rev-parse refs/desk/proposal)"
jq -n '[{id: "ok", file: "notes.md", kind: "add", target: "top", before: "", after: "x", headline: "h", source: "notes"},
	{id: "bad", file: "elsewhere.md", kind: "rewrite", target: "somewhere", before: "", after: "x", headline: "", source: "notes"}]' > "$ROOT/bad.json"
err="$("$PROPOSE" "$ROOT/bad.json" 2>&1 > /dev/null)"
assert_eq "it fails" "1" "$?"
for want in "item 2 (bad): file must be one of notes.md, reading.md" "item 2 (bad): kind must be" \
	"item 2 (bad): headline must be a non-empty string" "item 2 (bad): target must be"; do
	case "$err" in *"$want"*) ok "...naming: $want" ;; *) bad "...naming: $want (got [$err])" ;; esac
done
assert_eq "...and the proposal did not move" "$before_sha" "$(git -C "$repo" rev-parse refs/desk/proposal)"
jq -n '[{id: "e", file: "notes.md", kind: "edit", target: {at: "Weekly"}, before: "", after: "x", headline: "h", source: "notes"}]' > "$ROOT/bad2.json"
"$PROPOSE" "$ROOT/bad2.json" > /dev/null 2> "$ROOT/err"
assert_eq "an edit without the lines it replaces is refused" "1" "$?"

echo "=== --dry-run checks and prints, staging nothing ==="
out="$("$PROPOSE" --dry-run "$ROOT/items2.json")"
assert_eq "it prints the cleaned items" "answer2" "$(jq -r '.items[0].id' <<< "$out")"
assert_eq "...and the proposal did not move" "$before_sha" "$(git -C "$repo" rev-parse refs/desk/proposal)"

echo "=== a blank line between sections survives the cleaning ==="
repo2="$ROOT/notes2"
desk_test_assert_repo_under_root "$repo2" "$ROOT"
mkdir -p "$repo2"
git -C "$repo2" init -q -b main
git -C "$repo2" config user.email test@example.invalid
git -C "$repo2" config user.name "Desk Test"
printf 'Weekly\n  - posts drafted\nOther\n  - other thing\n' > "$repo2/notes.md"
: > "$repo2/reading.md"
: > "$repo2/.desk-notes"
git -C "$repo2" add -A
git -C "$repo2" commit -q -m initial
jq -n --arg r "$repo2" '{notes_repo: $r, files: ["notes.md", "reading.md"]}' > "$ROOT/config2.json"
jq -n '[{id: "gap", file: "notes.md", kind: "edit", target: {at: "  - posts drafted"}, before: "  - posts drafted",
	after: "  - posts drafted\n\n", headline: "Space the sections", source: "notes"}]' > "$ROOT/gap.json"
out="$(DESK_CONFIG="$ROOT/config2.json" "$PROPOSE" "$ROOT/gap.json")"
case "$out" in "staged: 1 new, "*) ok "an edit that only adds a blank line is staged" ;; *) bad "an edit that only adds a blank line is staged (got [$out])" ;; esac
assert_eq "...and the proposal has the blank line between the sections" "Weekly|  - posts drafted||Other|  - other thing" \
	"$(git -C "$repo2" show refs/desk/proposal:notes.md 2> /dev/null | paste -sd'|' -)"

echo "=== config and usage ==="
DESK_CONFIG="" DESK_CONFIG_DEFAULT="$ROOT/none.json" "$PROPOSE" "$ROOT/items.json" > /dev/null 2>&1
assert_eq "no config is a config error" "2" "$?"
"$PROPOSE" --date 07.10.2026 "$ROOT/items.json" > /dev/null 2>&1
assert_eq "a malformed --date is refused" "2" "$?"
"$PROPOSE" > /dev/null 2>&1
assert_eq "no items file is a usage error" "2" "$?"

echo
help="$(bash "$PROPOSE" --help 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok "--help exits 0" || bad "--help exit $rc"
printf '%s' "$help" | grep -q 'session:<its session id>' && ok "--help states the session item rules" || bad "--help lacks the session item rules"
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
