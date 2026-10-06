#!/usr/bin/env bash
# claude/desk-lib/model-call.sh's
# desk_call_model exports DESK_HEADLESS=1 for EVERY non-restricted
# (connector) call, not only a named/"visible" one. Before this fix an
# EPHEMERAL connector call (F-private, W — no --name,
# --no-session-persistence) still loaded his real settings and hooks
# exactly like a visible one does, but never got DESK_HEADLESS set, so its
# own genuine SessionStart/SessionEnd would land source "startup", reason
# "other" — indistinguishable from a session he actually opened, and
# exactly the 16:30 capture's own "dropped" criteria. No live model call:
# a fake `claude` on PATH records its own env.
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

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
ENV_LOG="$ROOT/env.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
printf 'DESK_HEADLESS=%s\n' "\${DESK_HEADLESS:-}" > "$ENV_LOG"
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/validate.sh
source "$LIB/validate.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

echo "=== an EPHEMERAL (no --name) connector call still gets DESK_HEADLESS=1 ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ENV_LOG"
step_json='{"id":"F-private","kind":"fetch","tools":["Read"],"connector":true,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "fetch" '{}' "")"
assert_eq "the call reports ok" "ok" "$result"
assert_eq "DESK_HEADLESS=1 was set in the call's own env" "DESK_HEADLESS=1" "$(cat "$ENV_LOG")"
rm -rf "$PASS_SCRATCH"

echo
echo "=== a restricted (non-connector) call never sets DESK_HEADLESS ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ENV_LOG"
step_json='{"id":"F-web","kind":"fetch","tools":["Read"],"connector":false,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "fetch" '{}' "")"
assert_eq "the call reports ok" "ok" "$result"
assert_eq "DESK_HEADLESS was never set" "DESK_HEADLESS=" "$(cat "$ENV_LOG")"
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
