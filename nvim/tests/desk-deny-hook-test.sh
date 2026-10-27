#!/usr/bin/env bash
# The deny hook (claude/desk-lib/deny-unlisted-tool.sh) and the settings that
# wire it in: every way out of the hook but the one allow is a deny, a
# missing pinned file denies, a Bash pattern admits only commands that fit
# it, and a call whose hook cannot be wired never runs.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"
HOOK="$LIB/deny-unlisted-tool.sh"

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

echo "=== a pinned call is held to its pinned arguments ==="
send='{"tool_name":"SendMessage","tool_input":{"to":"central","message":"hi"}}'
jq -n '[{to: "central", message: "hi"}]' > "$ROOT/pinned.json"
rc=0
echo "$send" | "$HOOK" --pinned "$ROOT/pinned.json" -- SendMessage > /dev/null 2>&1 || rc=$?
assert_eq "the pinned call is allowed" "0" "$rc"
rc=0
jq -c '.tool_input.to = "someone-else"' <<< "$send" | "$HOOK" --pinned "$ROOT/pinned.json" -- SendMessage > /dev/null 2>&1 || rc=$?
assert_eq "any other arguments are denied" "2" "$rc"
rc=0
echo "$send" | "$HOOK" --pinned "$ROOT/does-not-exist.json" -- SendMessage > /dev/null 2>&1 || rc=$?
assert_eq "a missing pinned file denies, rather than skipping the check" "2" "$rc"

echo
echo "=== any other way out of the hook is a deny, never a non-blocking error ==="
rc=0
echo '{"tool_name":"Read","tool_input":{}}' | "$HOOK" --pinned > /dev/null 2>&1 || rc=$?
assert_eq "an option missing its argument (before the allowlist) denies" "2" "$rc"

NOJQ="$ROOT/nojq-bin"
mkdir -p "$NOJQ"
for t in cat bash env dirname; do ln -sf "$(command -v "$t")" "$NOJQ/$t"; done
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' | PATH="$NOJQ" "$HOOK" Read > /dev/null 2>&1 || rc=$?
assert_eq "no jq on PATH denies an otherwise allowed tool" "2" "$rc"
rc=0
echo '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' | "$HOOK" Read > /dev/null 2>&1 || rc=$?
assert_eq "control: the same Read is allowed when everything is present" "0" "$rc"

echo
echo "=== the runner refuses to start without the tools it needs ==="
RUNBIN="$ROOT/runner-bin"
mkdir -p "$RUNBIN"
for t in bash env dirname readlink mkdir jq nvim git date cat uname sed tr rm mv head tail grep sort uuidgen find; do
	if p="$(command -v "$t")"; then ln -sf "$p" "$RUNBIN/$t"; fi
done
run_out="$(PATH="$RUNBIN" DESK_CONFIG="$ROOT/none.json" DESK_STATE_DIR="$ROOT/runner-state" /bin/bash "$HERE/../../claude/desk-run" morning 2>&1)" && run_rc=0 || run_rc=$?
assert_eq "no realpath: exits 2" "2" "$run_rc"
assert_true "and says which tool is missing" "$(grep -q 'required tool not found on PATH: realpath' <<< "$run_out" && echo true || echo false)"

echo
echo "=== a Bash pattern admits only the commands that fit it ==="
bash_call() { # <command> <allowed tool>...: the hook's exit code
	local rc=0
	jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$HOOK" "${@:2}" > /dev/null 2>&1 || rc=$?
	echo "$rc"
}
assert_eq "the prefix itself" "0" "$(bash_call 'gh run list' 'Bash(gh run list:*)')"
assert_eq "the prefix with arguments" "0" "$(bash_call 'gh run list --limit 5 --json name' 'Bash(gh run list:*)')"
assert_eq "a trailing ' *' reads as ':*'" "0" "$(bash_call 'gh pr list -s open' 'Bash(gh pr list *)')"
assert_eq "any of several patterns" "0" "$(bash_call 'gh pr list' 'Bash(gh run list:*)' 'Bash(gh pr list:*)')"
assert_eq "an exact spec, matched exactly" "0" "$(bash_call 'gh auth status' 'Bash(gh auth status)')"
assert_eq "an exact spec refuses extra arguments" "2" "$(bash_call 'gh auth status -t' 'Bash(gh auth status)')"
assert_eq "another command" "2" "$(bash_call 'gh run rerun 1' 'Bash(gh run list:*)')"
assert_eq "the prefix running on into a longer word" "2" "$(bash_call 'gh run listx' 'Bash(gh run list:*)')"
assert_eq "a second command after ;" "2" "$(bash_call 'gh run list; rm -rf ~' 'Bash(gh run list:*)')"
assert_eq "a second command after &&" "2" "$(bash_call 'gh run list && curl x' 'Bash(gh run list:*)')"
assert_eq "a pipe, even quoted" "2" "$(bash_call "gh run list --jq '.[] | .name'" 'Bash(gh run list:*)')"
assert_eq "a command substitution" "2" "$(bash_call 'gh run list -b $(id)' 'Bash(gh run list:*)')"
assert_eq "a backtick" "2" "$(bash_call 'gh run list -b `id`' 'Bash(gh run list:*)')"
assert_eq "a redirect" "2" "$(bash_call 'gh run list > ~/.bashrc' 'Bash(gh run list:*)')"
assert_eq "a second line" "2" "$(bash_call $'gh run list\nrm -rf ~' 'Bash(gh run list:*)')"
assert_eq "a wildcard mid-spec admits nothing" "2" "$(bash_call 'gh x list' 'Bash(gh * list)')"
rc=0
echo '{"tool_name":"Bash","tool_input":{}}' | "$HOOK" 'Bash(gh run list:*)' > /dev/null 2>&1 || rc=$?
assert_eq "a Bash call with no command" "2" "$rc"
assert_eq "a pattern for another tool admits no Bash" "2" "$(bash_call 'gh run list' 'WebFetch(gh run list:*)')"
rc=0
jq -cn '{tool_name:"WebFetch",tool_input:{url:"https://example.com"}}' \
	| "$HOOK" 'WebFetch(domain:example.com)' > /dev/null 2>&1 || rc=$?
assert_eq "a pattern the hook cannot check refuses its tool" "2" "$rc"
assert_eq "control: bare Bash still admits any command" "0" "$(bash_call 'anything; at all' Bash)"

echo
echo "=== the settings run the hook from a path with a space in it ==="
export DESK_STATE_DIR="$ROOT/state"
# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"
spacey_dir="$ROOT/a scratch dir"
mkdir -p "$spacey_dir"
cp "$HOOK" "$spacey_dir/deny hook.sh"
export DESK_DENY_HOOK_SCRIPT="$spacey_dir/deny hook.sh"
hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$(desk_write_deny_hook_settings "$spacey_dir" 'Bash(gh pr list:*)')")"
rc=0
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr list"}}' | bash -c "$hook_cmd" > /dev/null 2>&1 || rc=$?
assert_eq "a listed call is allowed" "0" "$rc"
rc=0
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf x"}}' | bash -c "$hook_cmd" > /dev/null 2>&1 || rc=$?
assert_eq "an unlisted one is denied" "2" "$rc"

echo
echo "=== a call whose hook cannot be wired never runs ==="
# shellcheck source=../../claude/desk-lib/status.sh
source "$LIB/status.sh"
# shellcheck source=../../claude/desk-lib/timeout.sh
source "$LIB/timeout.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"
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
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_CONFIG="$ROOT/config.json"
echo '{}' > "$DESK_CONFIG"
PASS_SCRATCH="$(desk_scratch_dir "test-pass")"
step_json='{"id":"F-x","kind":"fetch","tools":["mcp__example__search","Bash(gh pr list:*)","Bash(gh pr view:*)"],"timeout":30}'
desk_step_model_call "testpass" "$step_json" > /dev/null
assert_eq "control: with the hook, --tools names the pattern's tool once, and no MCP tool" "Bash" \
	"$(grep -A1 -x -- '--tools' "$ARGV_LOG" | tail -1)"
rm -f "$ARGV_LOG"
export DESK_DENY_HOOK_SCRIPT="$ROOT/does-not-exist-hook.sh"
missing_out="$(desk_write_deny_hook_settings "$ROOT" Read 2> /dev/null)" && missing_rc=0 || missing_rc=$?
assert_true "writing the settings fails, printing no path" "$([ "$missing_rc" -ne 0 ] && [ -z "$missing_out" ] && echo true || echo false)"
assert_eq "the step reports failed" "failed" "$(desk_step_model_call "testpass" "$step_json")"
assert_true "and the model was never invoked" "$([ ! -f "$ARGV_LOG" ] && echo true || echo false)"
unset DESK_DENY_HOOK_SCRIPT

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
