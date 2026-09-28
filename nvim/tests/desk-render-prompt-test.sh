#!/usr/bin/env bash
# D8 fix test (review item #5): claude/desk-lib/steps.sh's desk_render_prompt
# treats a placeholder's value literally. Two ways bash's own
# `${text//pat/repl}` (this function's previous implementation) breaks
# that: bash 5.2+'s own `patsub_replacement` (on by default) treats an
# unescaped `&` in the replacement as "the matched text" — same as sed —
# so a value containing a literal `&` would splice the `{{key}}` token
# back in instead; and substituting key by key, each pass rescanning the
# *whole* text, means a value that happens to contain another key's own
# `{{other}}` marker gets that marker substituted too, on a later
# iteration, even though it was never part of the template.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export DESK_STATE_DIR="$ROOT/state"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

template="$ROOT/template.txt"
cat > "$template" <<'EOF'
amp={{amp}}
container={{container}}
zzreferenced={{zzreferenced}}
unknown={{unknown}}
EOF

# "container" (alphabetically, and so substituted) before "zzreferenced":
# a key-by-key loop that rescans the whole (already partly substituted)
# text on every iteration would still catch "zzreferenced"'s own {{...}}
# marker *after* it was inserted by "container"'s own value, on this
# later iteration — a single-pass substitution never gives it the chance.
placeholders='{
	"amp": "a & b, c & d",
	"container": "quotes his own {{zzreferenced}} literally",
	"zzreferenced": "REAL"
}'
out="$(desk_render_prompt "$template" "$placeholders")"

assert_eq "a literal & in a value survives untouched (not the matched token)" \
	"amp=a & b, c & d" "$(grep '^amp=' <<< "$out")"
assert_eq "a {{...}}-shaped substring inside a value is never itself substituted" \
	"container=quotes his own {{zzreferenced}} literally" "$(grep '^container=' <<< "$out")"
assert_eq "the template's own placeholder for that same key still renders normally" \
	"zzreferenced=REAL" "$(grep '^zzreferenced=' <<< "$out")"
assert_eq "a {{name}} with no matching key is left exactly as written" \
	"unknown={{unknown}}" "$(grep '^unknown=' <<< "$out")"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
