#!/usr/bin/env bash
# move-session-seat.sh against fixtures in a temp HOME: copies the transcript
# and its directory, marks the original, refuses a live session and a repeat.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOVE="$HERE/../move-session-seat.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
S1="$HOME/.claude-work"
S2="$HOME/.claude-work-2"
ID=aaaaaaaa-0000-4000-8000-000000000001
mkdir -p "$S1/projects/-p/$ID/subagents" "$S2/projects"
echo '{"cwd":"/tmp/x","type":"user"}' > "$S1/projects/-p/$ID.jsonl"
echo sub > "$S1/projects/-p/$ID/subagents/a.jsonl"

cat > "$TMP/reader" << 'EOS'
#!/usr/bin/env bash
printf '{"id":"%s","live":%s}\n' "$FAKE_ID" "${FAKE_LIVE:-false}"
EOS
chmod +x "$TMP/reader"
export DESK_READER="$TMP/reader" FAKE_ID=$ID

FAKE_LIVE=true "$MOVE" $ID 2 > /dev/null 2>&1; assert_eq "a live session is refused" 1 $?
[ -f "$S1/projects/-p/$ID.jsonl" ] && [ ! -e "$S2/projects/-p" ]; assert_eq "...and nothing was copied" 0 $?
out=$("$MOVE" $ID 2 2>&1); assert_eq "a stopped one moves" 0 $?
[ -f "$S2/projects/-p/$ID.jsonl" ] && [ -f "$S2/projects/-p/$ID/subagents/a.jsonl" ]; assert_eq "transcript and its directory are on seat 2" 0 $?
[ ! -e "$S1/projects/-p/$ID.jsonl" ] && [ -f "$S1/projects/-p/$ID.jsonl.moved-to-2" ]; assert_eq "the original is marked, not listed as a transcript" 0 $?
case "$out" in *"cd /tmp/x && claude-work-2 --resume $ID"*) ok "it prints the resume command" ;; *) bad "resume command: $out" ;; esac
"$MOVE" $ID 2 > /dev/null 2>&1; assert_eq "moving it again is refused" 1 $?
"$MOVE" $ID 3 > /dev/null 2>&1; assert_eq "a seat that does not exist is refused" 1 $?

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
