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
	'["weekly-2026-10-07-2-ticket","weekly-2026-10-07-3-answer2"]' "$(proposal_items | jq -c 'map(.id) | sort')"

echo "=== same-day session stagings keep each other's items and number on ==="
repo4="$ROOT/notes4"
desk_test_assert_repo_under_root "$repo4" "$ROOT"
mkdir -p "$repo4"
git -C "$repo4" init -q -b main
git -C "$repo4" config user.email test@example.invalid
git -C "$repo4" config user.name "Desk Test"
printf 'Weekly\n  - posts drafted\nOther\n  - other thing\n' > "$repo4/notes.md"
: > "$repo4/reading.md"
: > "$repo4/.desk-notes"
git -C "$repo4" add -A
git -C "$repo4" commit -q -m initial
jq -n --arg r "$repo4" '{notes_repo: $r, files: ["notes.md", "reading.md"]}' > "$ROOT/config4.json"
jq -n '[{id: "a", file: "notes.md", kind: "add", target: {under: "Weekly"}, before: "", after: "  - one", headline: "One", source: "session:s1"},
	{id: "b", file: "notes.md", kind: "edit", target: {at: "  - other thing"}, before: "  - other thing", after: "  - other thing, done", headline: "Two", source: "session:s1"},
	{id: "c", file: "notes.md", kind: "new", target: "top", before: "", after: "- three", headline: "Three", source: "session:s1"}]' > "$ROOT/s1.json"
DESK_CONFIG="$ROOT/config4.json" "$PROPOSE" --date 2026-10-21 "$ROOT/s1.json" > /dev/null
jq -n '[{id: "d", file: "notes.md", kind: "add", target: {under: "Other"}, before: "", after: "  - four", headline: "Four", source: "session:s2"}]' > "$ROOT/s2.json"
out="$(DESK_CONFIG="$ROOT/config4.json" "$PROPOSE" --date 2026-10-21 "$ROOT/s2.json")"
case "$out" in *"3 still waiting from before"*) ok "a second plain call carries the first's three" ;; *) bad "a second plain call carries the first's three (got [$out])" ;; esac
case "$out" in *"  staged session-2026-10-21-4-d: Four"*) ok "...and numbers its item past them" ;; *) bad "...and numbers its item past them (got [$out])" ;; esac
jq -n '[{id: "e", file: "notes.md", kind: "new", target: "top", before: "", after: "- three, corrected", headline: "Three again", source: "session:s3",
	supersedes: "session-2026-10-21-3-c"}]' > "$ROOT/s3.json"
out="$(DESK_CONFIG="$ROOT/config4.json" "$PROPOSE" --date 2026-10-21 "$ROOT/s3.json")"
case "$out" in "staged: 1 new, 1 replacing open ones, "*"3 still waiting from before"*) ok "a supersedes replaces only the item it names" ;;
	*) bad "a supersedes replaces only the item it names (got [$out])" ;; esac
assert_eq "...leaving every other session's item waiting" \
	"session-2026-10-21-1-a session-2026-10-21-2-b session-2026-10-21-4-d session-2026-10-21-5-e" \
	"$(DESK_CONFIG="$ROOT/config4.json" "$PROPOSE" --list | cut -f1 | sort | paste -sd' ' -)"
jq -n '[{id: "f", file: "notes.md", kind: "new", target: "top", before: "", after: "- x", headline: "X", source: "session:s3",
	supersedes: ["session-2026-10-21-1-a"]}]' > "$ROOT/s4.json"
err="$(DESK_CONFIG="$ROOT/config4.json" "$PROPOSE" --date 2026-10-21 "$ROOT/s4.json" 2>&1 > /dev/null)"
case "$err" in *"supersedes must be an id string"*) ok "a list in supersedes is refused" ;; *) bad "a list in supersedes is refused (got [$err])" ;; esac

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
jq -n '[{id: "short", file: "notes.md", kind: "edit", target: {at: "ok"}, before: "ok\n  - detail", after: "x", headline: "h", source: "notes"},
	{id: "off", file: "notes.md", kind: "move", target: [{at: "Weekly"}, "top"], before: "Other\n  - other thing", after: "x", headline: "h", source: "notes"},
	{id: "fine", file: "notes.md", kind: "remove", target: {at: "Weekly"}, before: "Weekly", after: "", headline: "h", source: "notes"}]' > "$ROOT/bad3.json"
err="$("$PROPOSE" "$ROOT/bad3.json" 2>&1 > /dev/null)"
assert_eq "an at too short to quote, or not before's first line, is refused" "1" "$?"
for want in "item 1 (short): its at line \"ok\" is shorter than three characters" \
	"item 2 (off): its at line \"Weekly\" is not the first line of before (\"Other\")"; do
	case "$err" in *"$want"*) ok "...naming: $want" ;; *) bad "...naming: $want (got [$err])" ;; esac
done
case "$err" in *"(fine)"*) bad "...an at that is before's first line passes (got [$err])" ;; *) ok "...an at that is before's first line passes" ;; esac

echo "=== --allowed-urls: a judged item keeps only links the fetches returned ==="
printf 'https://news.example.com/a\nhttps://news.example.com/b\n' > "$ROOT/allowed.txt"
jq -n '[{id: "news", file: "notes.md", kind: "new", target: "top", before: "",
	after: "- WK: a launch [the post](https://news.example.com/a), also https://evil.example.com/x", headline: "A launch", tier: "worth_knowing",
	source: "https://news.example.com/a", also_sources: ["https://news.example.com/b", "https://evil.example.com/y"]}]' > "$ROOT/judged.json"
out="$("$PROPOSE" --dry-run --allowed-urls "$ROOT/allowed.txt" "$ROOT/judged.json")"
assert_eq "an allowed source passes" "0" "$?"
assert_eq "...a link no fetch returned is removed from its text" \
	"- WK: a launch [the post](https://news.example.com/a), also [url removed]" "$(jq -r '.items[0].after' <<< "$out")"
assert_eq "...and from also_sources" '["https://news.example.com/b"]' "$(jq -c '.items[0].also_sources' <<< "$out")"
jq '.[0].source = "https://evil.example.com/x"' "$ROOT/judged.json" > "$ROOT/judged-bad.json"
before_sha="$(git -C "$repo" rev-parse refs/desk/proposal)"
err="$("$PROPOSE" --allowed-urls "$ROOT/allowed.txt" "$ROOT/judged-bad.json" 2>&1 > /dev/null)"
assert_eq "a source no fetch returned fails the call" "1" "$?"
case "$err" in *"item 1 (news): its source https://evil.example.com/x is not in $ROOT/allowed.txt"*) ok "...naming it" ;; *) bad "...naming it (got [$err])" ;; esac
assert_eq "...and stages nothing" "$before_sha" "$(git -C "$repo" rev-parse refs/desk/proposal)"
jq -n '[{id: "tick", file: "notes.md", kind: "new", target: "top", before: "", after: "- ACT: answer it (ABC-1)", headline: "A ticket", tier: "act", source: "ticket:ABC-1"}]' > "$ROOT/judged-ticket.json"
"$PROPOSE" --dry-run --allowed-urls "$ROOT/allowed.txt" "$ROOT/judged-ticket.json" > /dev/null
assert_eq "a non-URL source is not checked against the file" "0" "$?"

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

echo "=== an item anchored on an uncommitted line waits for the commit ==="
repo3="$ROOT/notes3"
desk_test_assert_repo_under_root "$repo3" "$ROOT"
mkdir -p "$repo3"
git -C "$repo3" init -q -b main
git -C "$repo3" config user.email test@example.invalid
git -C "$repo3" config user.name "Desk Test"
printf 'Weekly\n  - posts drafted\n' > "$repo3/notes.md"
: > "$repo3/reading.md"
: > "$repo3/.desk-notes"
git -C "$repo3" add -A
git -C "$repo3" commit -q -m initial
printf 'Weekly\n  - posts drafted\nMonday\n  - call planned\n' > "$repo3/notes.md"
jq -n --arg r "$repo3" '{notes_repo: $r, files: ["notes.md", "reading.md"]}' > "$ROOT/config3.json"
jq -n '[{id: "plan", file: "notes.md", kind: "add", target: {under: "Monday"}, before: "",
	after: "  - agenda sent", headline: "Agenda sent", source: "notes"},
	{id: "lost", file: "notes.md", kind: "add", target: {under: "Tuesday"}, before: "",
	after: "  - nothing yet", headline: "Nothing yet", source: "notes"}]' > "$ROOT/wait.json"
out="$(DESK_CONFIG="$ROOT/config3.json" "$PROPOSE" --date 2026-10-07 "$ROOT/wait.json")"
assert_eq "it stages" "0" "$?"
case "$out" in *"0 deferred (anchor not found), 1 waiting for you to commit a line;"*) ok "...the summary counts it apart from anchor not found" ;;
	*) bad "...the summary counts it apart from anchor not found (got [$out])" ;; esac
case "$out" in *'waits for you to commit "Monday" in notes.md: Agenda sent (session-2026-10-07-1-plan)'*) ok "...and names the line it waits on" ;;
	*) bad "...and names the line it waits on (got [$out])" ;; esac
assert_eq "...which is not landed on top, unlike an anchor found nowhere" "  - nothing yet|Weekly|  - posts drafted" \
	"$(git -C "$repo3" show refs/desk/proposal:notes.md 2> /dev/null | paste -sd'|' -)"
assert_eq "--list shows the waiting one, marked deferred" \
	"session-2026-10-07-1-plan	notes.md	Agenda sent (deferred: waits for you to commit a line)" \
	"$(DESK_CONFIG="$ROOT/config3.json" "$PROPOSE" --list | grep -F 'session-2026-10-07-1-plan')"

echo "=== --withdraw takes a staged suggestion back ==="
jq -n '[{id: "wd", file: "notes.md", kind: "new", target: "top", before: "", after: "- a suggestion the user says is done", headline: "Done already", source: "notes"}]' > "$ROOT/wd.json"
"$PROPOSE" --pass morning --date 2026-10-13 "$ROOT/wd.json" > /dev/null
wid="$(proposal_items | jq -r '.[] | select(.id | endswith("-wd")) | .id')"
before_sha="$(git -C "$repo" rev-parse refs/desk/proposal)"
err="$("$PROPOSE" --withdraw "$wid" no-such-id 2>&1 > /dev/null)"
assert_eq "an id the proposal does not hold fails the call" "1" "$?"
case "$err" in *"no suggestion no-such-id"*) ok "...naming it" ;; *) bad "...naming it (got [$err])" ;; esac
assert_eq "...and withdraws nothing" "$before_sha" "$(git -C "$repo" rev-parse refs/desk/proposal)"
out="$("$PROPOSE" --withdraw "$wid")"
assert_eq "withdrawing succeeds" "0" "$?"
case "$out" in "withdrew 1: "*) ok "...and says so" ;; *) bad "...and says so (got [$out])" ;; esac
assert_eq "the suggestion is gone from the open proposal" "" "$(nvim -l "$CLI" proposal-open "$repo" | jq -r --arg id "$wid" '.items[] | select(.id == $id) | .id')"
assert_eq "it is recorded as declined" "$wid" "$(nvim -l "$CLI" declined-recent "$repo" | jq -r --arg id "$wid" '.items[] | select(.id == $id) | .id')"
assert_eq "the other suggestions still wait" "true" "$(nvim -l "$CLI" proposal-open "$repo" | jq '[.items[].id] | any(endswith("-ticket"))')"
"$PROPOSE" --pass morning --date 2026-10-14 "$ROOT/wd.json" > /dev/null
assert_eq "staging the same text again does not bring it back" "" \
	"$(nvim -l "$CLI" proposal-open "$repo" | jq -r '.items[] | select(.headline == "Done already") | .id')"

echo "=== staging names the ids it staged; --list shows what waits ==="
jq -n '[{id: "listme", file: "notes.md", kind: "new", target: "top", before: "", after: "- one to list", headline: "One to list", source: "notes"}]' > "$ROOT/list.json"
out="$("$PROPOSE" --pass morning --date 2026-10-15 "$ROOT/list.json")"
lid="$(proposal_items | jq -r '.[] | select(.id | endswith("-listme")) | .id')"
case "$out" in *"  staged $lid: One to list"*) ok "staging prints the id it gave the item" ;; *) bad "staging prints the id it gave the item (got [$out])" ;; esac
case "$out" in *"staged "*"-ticket"*) bad "...and only this call's (got [$out])" ;; *) ok "...and only this call's" ;; esac
jq -n '[{id: "listtoo", file: "notes.md", kind: "new", target: "top", before: "", after: "- a second one to list", headline: "Second to list", source: "notes"}]' > "$ROOT/list2.json"
out2="$("$PROPOSE" --pass morning --date 2026-10-15 "$ROOT/list2.json")"
lid2="$(proposal_items | jq -r '.[] | select(.id | endswith("-listtoo")) | .id')"
case "$out2" in *"  staged $lid2: Second to list"*) ok "a second staging the same day prints its own id" ;; *) bad "a second staging the same day prints its own id (got [$out2])" ;; esac
case "$out2" in *"$lid:"*) bad "...and not the first one's, staged under the same pass and date (got [$out2])" ;; *) ok "...and not the first one's, staged under the same pass and date" ;; esac
listing="$("$PROPOSE" --list)"
assert_eq "--list shows it, with its file and headline" "$lid	notes.md	One to list" "$(grep -F "$lid" <<< "$listing")"
assert_eq "...once, though it is also in the proposal's full list" "1" "$(grep -cF "$lid" <<< "$listing")"
before_sha="$(git -C "$repo" rev-parse refs/desk/proposal)"
out="$("$PROPOSE" --withdraw --dry-run "$lid")"
assert_eq "--withdraw --dry-run says what it would withdraw" "would withdraw $lid: One to list" "$out"
assert_eq "...and changes nothing" "$before_sha" "$(git -C "$repo" rev-parse refs/desk/proposal)"
assert_eq "...not even the ledger" "" "$(nvim -l "$CLI" declined-recent "$repo" | jq -r --arg id "$lid" '.items[] | select(.id == $id) | .id')"

echo "=== a retention warning keeps the fields its dedup reads ==="
jq -n '[{id: "ret", file: "notes.md", kind: "new", target: "top", before: "", after: "old-spike (transcript deleted 2026-10-20 unless resumed)", headline: "old-spike: transcript deleted 2026-10-20", source: "session:abcd", session_id: "abcd", capture_kind: "retention:2026-10-20"}]' > "$ROOT/ret.json"
"$PROPOSE" --pass morning --date 2026-10-16 "$ROOT/ret.json" > /dev/null
assert_eq "session_id and capture_kind reach the proposal" "abcd retention:2026-10-20" \
	"$(proposal_items | jq -r '.[] | select(.id | endswith("-ret")) | "\(.session_id) \(.capture_kind)"')"
assert_eq "...where the ledger state reads them" "abcd" \
	"$(nvim -l "$CLI" ledger-state "$repo" | jq -r '.items[] | select(.capture_kind == "retention:2026-10-20") | .session_id')"

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
printf '%s' "$help" | grep -q 'one id string' && ok "--help says supersedes takes one id string" || bad "--help does not say supersedes takes one id string"
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
