#!/usr/bin/env bash
# D8 fix test: the `nvim -l` entry point onto desk.ledger.namespace_ids
# (nvim/lua/desk/cli.lua's `namespace-ids` verb) — exercised as the actual
# subprocess a non-Lua caller (the runner) would run, against a
# from-scratch fixture repo.
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

REPO="$TMP/notes"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "Desk Test"
printf 'Alpha\n' > "$REPO/notes.md"
git -C "$REPO" add notes.md
git -C "$REPO" commit -q -m initial

echo "=== namespace-ids: two same-pass items sharing a model id get distinct ids ==="
items="$TMP/items.json"
cat > "$items" <<'EOF'
{"items": [
  {"id": "c1", "file": "notes.md", "kind": "new", "target": "top", "before": "", "after": "first"},
  {"id": "c1", "file": "notes.md", "kind": "new", "target": "top", "before": "", "after": "second"}
]}
EOF
out=$(nvim -l "$CLI" namespace-ids "$REPO" close 2026-09-29 "$items")
assert_eq "exit code 0" "0" "$?"
assert_eq "first item's namespaced id" "close-2026-09-29-1-c1" "$(printf '%s' "$out" | jq -r '.items[0].id')"
assert_eq "second item's namespaced id" "close-2026-09-29-2-c1" "$(printf '%s' "$out" | jq -r '.items[1].id')"
assert_eq "content besides id is untouched" "first" "$(printf '%s' "$out" | jq -r '.items[0].after')"

echo
echo "=== namespace-ids: colliding with something already in the ledger bumps past it ==="
# Simulate a prior pass having already appended this exact namespaced id.
prior_records="$TMP/prior.ndjson"
printf '%s\n' '{"type":"item","id":"morning-2026-09-30-1-j1","file":"notes.md"}' > "$prior_records"
nvim -l "$CLI" ledger-append-batch "$REPO" "$prior_records" > /dev/null
items2="$TMP/items2.json"
cat > "$items2" <<'EOF'
{"items": [{"id": "j1", "file": "notes.md", "kind": "new", "target": "top", "before": "", "after": "retried"}]}
EOF
out2=$(nvim -l "$CLI" namespace-ids "$REPO" morning 2026-09-30 "$items2")
assert_eq "exit code 0" "0" "$?"
assert_eq "seq is bumped past the existing collision" "morning-2026-09-30-2-j1" \
	"$(printf '%s' "$out2" | jq -r '.items[0].id')"

echo
echo "=== namespace-ids: missing arguments fail loudly ==="
nvim -l "$CLI" namespace-ids "$REPO" morning 2026-09-30 > /dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && ok "a missing items file exits non-zero" || bad "a missing items file exits non-zero (exited 0)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
