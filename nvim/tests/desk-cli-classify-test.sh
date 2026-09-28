#!/usr/bin/env bash
# D8 fix test: the his-text-derived status fields (design.md §9(f):
# accepted_by_accident, resolved_without_key, waiting_edits) wired end to
# end — desk.review's commit_his_text and desk.cli's own commit-his-text
# verb both write the pending-set snapshot (desk.ledger.write_pending_
# snapshot) every run, and nvim/lua/desk/cli.lua's `ledger-classify` verb
# reads it back (desk.ledger.classify_transitions) to produce these
# fields. Exercised as the actual subprocess a non-Lua caller (the runner)
# would run, against from-scratch fixture repos.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../lua/desk/cli.lua"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then
		ok "$desc"
	else
		bad "$desc (expected [$expected], got [$actual])"
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$TMP"

# Sandboxed: the pending-set snapshot resolves under $DESK_STATE_DIR (real
# default ~/.local/state/desk, same as every other desk-lib state file) —
# never the real one from a test run.
export DESK_STATE_DIR="$TMP/state"

new_repo() {
	local repo="$1"
	desk_test_assert_repo_under_root "$repo" "$TMP"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name "Desk Test"
	printf 'Alpha\n' > "$repo/notes.md"
	git -C "$repo" add notes.md
	git -C "$repo" commit -q -m initial
}

echo "=== ledger-classify: nothing snapshotted yet -- every list empty, never an error ==="
REPO0="$TMP/repo0"
new_repo "$REPO0"
out0=$(nvim -l "$CLI" ledger-classify "$REPO0" notes.md)
assert_eq "exit code 0" "0" "$?"
assert_eq "accepted_by_accident is empty" "[]" "$(printf '%s' "$out0" | jq -c -S '.accepted_by_accident')"
assert_eq "resolved_without_key is empty" "[]" "$(printf '%s' "$out0" | jq -c -S '.resolved_without_key')"
assert_eq "waiting_edits is empty" "[]" "$(printf '%s' "$out0" | jq -c -S '.waiting_edits')"

echo
echo "=== ledger-classify: accepted_by_accident (a git add -A, no accept key) ==="
REPO1="$TMP/repo1"
new_repo "$REPO1"
records1="$TMP/records1.ndjson"
cat > "$records1" <<'EOF'
{"type":"item","id":"acc1","file":"notes.md","kind":"new","anchor":"top","before":"","after":"accidentally accepted","headline":"acc"}
{"type":"laid_in","at":0,"proposal":"seed","items":["acc1"]}
EOF
nvim -l "$CLI" ledger-append-batch "$REPO1" "$records1" > /dev/null
printf 'accidentally accepted\nAlpha\n' > "$REPO1/notes.md"

# Establishes the pending-set snapshot (acc1 is pending right now).
nvim -l "$CLI" commit-his-text "$REPO1" notes.md > /dev/null

# The accident: stage the whole worktree, never through the review key.
git -C "$REPO1" add notes.md

out1=$(nvim -l "$CLI" ledger-classify "$REPO1" notes.md)
assert_eq "exit code 0" "0" "$?"
assert_eq "acc1 is flagged accepted by accident" '["acc1"]' "$(printf '%s' "$out1" | jq -c -S '.accepted_by_accident')"
assert_eq "resolved_without_key is empty" "[]" "$(printf '%s' "$out1" | jq -c -S '.resolved_without_key')"
assert_eq "waiting_edits is empty" "[]" "$(printf '%s' "$out1" | jq -c -S '.waiting_edits')"

echo
echo "=== ledger-classify: resolved_without_key (content vanished, no decline key) ==="
REPO2="$TMP/repo2"
new_repo "$REPO2"
records2="$TMP/records2.ndjson"
cat > "$records2" <<'EOF'
{"type":"item","id":"dec1","file":"notes.md","kind":"new","anchor":"top","before":"","after":"silently resolved","headline":"dec"}
{"type":"laid_in","at":0,"proposal":"seed","items":["dec1"]}
EOF
nvim -l "$CLI" ledger-append-batch "$REPO2" "$records2" > /dev/null
printf 'silently resolved\nAlpha\n' > "$REPO2/notes.md"

# Establishes the pending-set snapshot (dec1 is pending right now).
nvim -l "$CLI" commit-his-text "$REPO2" notes.md > /dev/null

# Resolved without ever pressing decline: the line is just gone.
printf 'Alpha\n' > "$REPO2/notes.md"

out2=$(nvim -l "$CLI" ledger-classify "$REPO2" notes.md)
assert_eq "exit code 0" "0" "$?"
assert_eq "dec1 is flagged resolved without a key" '["dec1"]' "$(printf '%s' "$out2" | jq -c -S '.resolved_without_key')"
assert_eq "accepted_by_accident is empty" "[]" "$(printf '%s' "$out2" | jq -c -S '.accepted_by_accident')"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
