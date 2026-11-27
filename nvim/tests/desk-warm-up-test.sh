#!/usr/bin/env bash
# claude/desk-lib/warm-up.sh: with a pass's `warm_up.config_dirs` set, one
# tool-less request per dir under that dir's CLAUDE_CONFIG_DIR, one log line
# each; nothing when unset; a failing request never fails the pass.
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
mkdir -p "$ROOT/fakebin" "$ROOT/seat1" "$ROOT/seat2" "$ROOT/scratch"
cat > "$ROOT/fakebin/claude" << FAKE
#!/usr/bin/env bash
printf '%s|%s\n' "\$CLAUDE_CONFIG_DIR" "\$*" >> "$ROOT/calls.log"
[ "\${FAKE_FAIL:-}" = "\${CLAUDE_CONFIG_DIR##*/}" ] && exit 1
echo '{"type":"result"}'
FAKE
chmod +x "$ROOT/fakebin/claude"
export PATH="$ROOT/fakebin:$PATH" DESK_CLAUDE_BIN=claude
export DESK_STATE_DIR="$ROOT/state" CLAUDE_CONFIG_DIR="$ROOT/none" DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"
# shellcheck source=../../claude/desk-lib/warm-up.sh
source "$LIB/warm-up.sh"

logged=""
desk_log() { logged+="$*"$'\n'; }

desk_warm_up morning '{"steps":[]}' "$ROOT/scratch"
assert_eq "unset: no request" "" "$(cat "$ROOT/calls.log" 2> /dev/null)"

cfg="{\"warm_up\":{\"config_dirs\":[\"$ROOT/seat2\"]}}"
desk_warm_up morning "$cfg" "$ROOT/scratch"
assert_eq "one dir: one request under its config dir" "$ROOT/seat2" "$(cut -d'|' -f1 "$ROOT/calls.log")"
case "$(cat "$ROOT/calls.log")" in
	*"-p ok --model haiku"*"--tools "*"--strict-mcp-config"*) ok "...minimal, tool-less, haiku" ;;
	*) bad "flags: $(cat "$ROOT/calls.log")" ;;
esac
assert_eq "one log line" "morning warm-up: seat2 window started (haiku)" "$(printf '%s' "$logged" | tail -n1 | sed 's/^- //')"

: > "$ROOT/calls.log"
logged=""
cfg="{\"warm_up\":{\"config_dirs\":[\"$ROOT/seat1\",\"$ROOT/seat2\",\"$ROOT/missing\"],\"model\":\"sonnet\"}}"
FAKE_FAIL=seat1 desk_warm_up morning "$cfg" "$ROOT/scratch"
rc=$?
assert_eq "a failure does not stop the function (returns 0)" 0 "$rc"
assert_eq "both existing dirs were tried, in order" "seat1 seat2" "$(cut -d'|' -f1 "$ROOT/calls.log" | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//')"
case "$logged" in *"seat1 failed"*"seat2 window started (sonnet)"*"missing is not a directory"*) ok "one line each, the failure and the missing dir named" ;; *) bad "log: $logged" ;; esac

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
