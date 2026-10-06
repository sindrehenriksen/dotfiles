#!/usr/bin/env bash
# claude/desk-lib/steps.sh's
# desk_step_model_call passes --max-budget-usd on every call — a step's
# own `max_budget_usd`, falling back to common.sh's own
# DESK_DEFAULT_MAX_BUDGET_USD when a step doesn't name one. Before this
# fix no call ever passed --max-budget-usd at all, despite desk_call_model
# already supporting the flag.
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

echo "=== a step with no max_budget_usd of its own gets the generic default ==="
PASS_SCRATCH="$(desk_scratch_dir test-pass)"
step_default='{"id":"F","kind":"fetch","tools":["Read"],"connector":false,"timeout":30}'
desk_step_fetch testpass "$step_default" "" '{}' > /dev/null
assert_eq "the generic default (common.sh's DESK_DEFAULT_MAX_BUDGET_USD)" "$DESK_DEFAULT_MAX_BUDGET_USD" "$(extract_budget)"
rm -rf "$PASS_SCRATCH"

echo
echo "=== a step's own max_budget_usd overrides the default ==="
PASS_SCRATCH="$(desk_scratch_dir test-pass)"
step_custom='{"id":"F2","kind":"fetch","tools":["Read"],"connector":false,"timeout":30,"max_budget_usd":5}'
desk_step_fetch testpass "$step_custom" "" '{}' > /dev/null
assert_eq "the step's own value" "5" "$(extract_budget)"
rm -rf "$PASS_SCRATCH"

echo
echo "=== the config's default_max_budget_usd sits between the step's and the generic default ==="
PASS_SCRATCH="$(desk_scratch_dir test-pass)"
echo '{"default_max_budget_usd": 7}' > "$DESK_CONFIG"
desk_step_fetch testpass "$step_default" "" '{}' > /dev/null
assert_eq "the config's default" "7" "$(extract_budget)"
desk_step_fetch testpass "$step_custom" "" '{}' > /dev/null
assert_eq "a step's own value still wins" "5" "$(extract_budget)"
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
