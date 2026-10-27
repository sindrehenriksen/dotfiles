#!/usr/bin/env bash
# claude/desk-lib/steps.sh's desk_step_model_call puts one spend ceiling on
# every call, a failsafe: the config's default_max_budget_usd, else
# common.sh's DESK_DEFAULT_MAX_BUDGET_USD. A step's own value is ignored.
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
ARGV_LOG="$ROOT/argv.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGV_LOG"
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

export DESK_STATE_DIR="$ROOT/state"
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
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

extract_budget() {
	grep -A1 -- '^--max-budget-usd$' "$ARGV_LOG" | tail -n1
}

echo "=== every call gets the failsafe ceiling ==="
PASS_SCRATCH="$(desk_scratch_dir test-pass)"
step_default='{"id":"F","kind":"fetch","tools":["Read"],"connector":false,"timeout":30}'
desk_step_model_call testpass "$step_default" > /dev/null
assert_eq "the generic default, 25" "25" "$(extract_budget)"
step_custom='{"id":"F2","kind":"fetch","tools":["Read"],"connector":false,"timeout":30,"max_budget_usd":5}'
desk_step_model_call testpass "$step_custom" > /dev/null
assert_eq "a step's own value is ignored" "25" "$(extract_budget)"
rm -rf "$PASS_SCRATCH"

echo
echo "=== the config's default_max_budget_usd is the one ceiling when set ==="
PASS_SCRATCH="$(desk_scratch_dir test-pass)"
echo '{"default_max_budget_usd": 40}' > "$DESK_CONFIG"
desk_step_model_call testpass "$step_custom" > /dev/null
assert_eq "the config's value" "40" "$(extract_budget)"
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
