#!/usr/bin/env bash
# claude/desk-lib/timeout.sh's
# run_with_timeout keeps a command's stderr out of its own stdout outfile.
# Before this fix both streams were merged (2>&1) into the same file —
# fine for a human reading a log, but that file is also stream-json a
# downstream extraction slurps with `jq -cs` (desk_extract_final_text):
# one stray non-JSON stderr line anywhere in it fails that whole parse,
# not just the one line.
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
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
export DESK_STATE_DIR="$ROOT/state"
export DESK_KILL_GRACE_SECS=2

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"

noisy() {
	echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}'
	echo 'a deprecation warning on stderr, not JSON at all' >&2
	echo '{"type":"result","subtype":"success"}'
}

out="$ROOT/out.jsonl"
run_with_timeout 5 "$out" bash -c "$(declare -f noisy); noisy"
rc=$?
assert_eq "the command's own exit code is preserved" "0" "$rc"

echo "=== the outfile holds only stdout: every line parses as JSON ==="
bad_lines="$(while IFS= read -r line; do jq -e . > /dev/null 2>&1 <<< "$line" || echo "$line"; done < "$out")"
assert_true "no non-JSON line in the stream file" "$([ -z "$bad_lines" ] && echo true || echo false)"
assert_true "stderr's own text never reached the stream file" \
	"$(grep -q 'deprecation warning' "$out" && echo false || echo true)"

echo
echo "=== stderr is still captured, just separately ==="
assert_true "\$out.stderr holds the warning" \
	"$(grep -q 'deprecation warning' "$out.stderr" 2> /dev/null && echo true || echo false)"

echo
echo "=== a slurp-mode extraction (jq -cs, as desk_extract_final_text uses) survives ==="
final="$(jq -cs '[.[] | select(.type == "assistant")] | last | .message.content[0].text' "$out" 2> /dev/null)"
assert_eq "the assistant's own text is still extracted" '"hi"' "$final"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
