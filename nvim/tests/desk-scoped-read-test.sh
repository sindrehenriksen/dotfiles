#!/usr/bin/env bash
# A judge/close call's own Read is scoped to that call's own scratch dir —
# desk_step_allowed_tools (claude/desk-lib/steps.sh) turns a bare "Read" in
# a judge/close step's `tools` into `Read(<scratch>/**)`, an absolute glob,
# instead of an unscoped "Read" — those two kinds only ever legitimately
# read their own seeded scratch files, never anywhere else. Any other kind
# (fetch here) keeps the old unscoped behavior. "<scratch>" is whatever the
# call's own {{scratch}} placeholder resolves to: the call's actual cwd for
# an ordinary call, but desk_step_close's own longer-lived seed dir for a
# close call (its prompt is pointed at that, not its ephemeral cwd) — a
# scoped Read that didn't follow the same rule couldn't read what the
# prompt just told the model to read. Exercises desk_step_model_call
# directly (no live model call: a fake `claude` on PATH records its own
# argv and cwd).
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
CWD_LOG="$ROOT/cwd.log"
# An ephemeral (non-visible) call's own scratch dir — where
# desk_write_deny_hook_settings wrote its settings file — is rm -rf'd by
# desk_step_model_call itself right after this fake claude returns, so
# the settings file's own content has to be captured here, while it still
# exists, rather than read back afterward.
SETTINGS_CONTENT_LOG="$ROOT/settings-content.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
pwd > "$CWD_LOG"
printf '%s\n' "\$@" > "$ARGV_LOG"
: > "$SETTINGS_CONTENT_LOG"
prev=""
for a in "\$@"; do
	[ "\$prev" = "--settings" ] && [ -f "\$a" ] && cat "\$a" > "$SETTINGS_CONTENT_LOG"
	prev="\$a"
done
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

allowed_tools_of() { # <argv-log-file>: the value right after --allowedTools
	grep -A1 -- '^--allowedTools$' "$1" | tail -1
}
settings_of() { # <argv-log-file>: the value right after --settings, or ""
	grep -A1 -- '^--settings$' "$1" | tail -1
}
deny_hook_scratch_of() { # <settings-content-log>: its --scratch arg, or ""
	jq -r '.hooks.PreToolUse[0].hooks[0].command' "$1" 2> /dev/null \
		| grep -oE -- '--scratch [^ ]+' | awk '{print $2}' | sed "s/^'//; s/'\$//"
}

echo "=== a fetch call keeps a bare, unscoped Read ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ARGV_LOG"
: > "$CWD_LOG"
step_json='{"id":"A","kind":"fetch","tools":["Read"],"connector":false,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "fetch" '{}' "")"
assert_eq "the call reports ok" "ok" "$result"
assert_eq "--allowedTools stays the plain \"Read\"" "Read" "$(allowed_tools_of "$ARGV_LOG")"
assert_eq "no --settings at all (a restricted, non-judge/close call needs no deny hook)" \
	"" "$(settings_of "$ARGV_LOG")"
rm -rf "$PASS_SCRATCH"

echo
echo "=== a judge call scopes Read to its own cwd, leaving other tools alone ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ARGV_LOG"
: > "$CWD_LOG"
step_json='{"id":"B","kind":"judge","tools":["Read","Bash"],"connector":false,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "judge" '{}' "")"
assert_eq "the call reports ok" "ok" "$result"
call_cwd="$(cat "$CWD_LOG")"
assert_eq "--allowedTools scopes Read to Read(<cwd>/**), Bash untouched" \
	"Read($call_cwd/**),Bash" "$(allowed_tools_of "$ARGV_LOG")"
judge_settings="$(settings_of "$ARGV_LOG")"
assert_eq "a --settings file was also passed (the deny hook's own backstop)" \
	"true" "$([ -n "$judge_settings" ] && echo true || echo false)"
assert_eq "that settings file's own hook is scoped to the same cwd" \
	"$call_cwd" "$(deny_hook_scratch_of "$SETTINGS_CONTENT_LOG")"
rm -rf "$PASS_SCRATCH"

echo
echo "=== a close call scopes Read to its own (longer-lived) seed dir, not its ephemeral cwd ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ARGV_LOG"
: > "$CWD_LOG"
seed_dir="$ROOT/close-seed-fixture"
mkdir -p "$seed_dir"
printf 'a seeded file\n' > "$seed_dir/notes.md"
placeholders="$(jq -n --arg scratch "$seed_dir" '{scratch: $scratch}')"
step_json='{"id":"C","kind":"close","tools":["Read"],"connector":false,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "close" "$placeholders" "$seed_dir")"
assert_eq "the call reports ok" "ok" "$result"
call_cwd="$(cat "$CWD_LOG")"
assert_eq "--allowedTools scopes Read to the seed dir" "Read($seed_dir/**)" "$(allowed_tools_of "$ARGV_LOG")"
close_settings="$(settings_of "$ARGV_LOG")"
assert_eq "a --settings file was also passed (the deny hook's own backstop)" \
	"true" "$([ -n "$close_settings" ] && echo true || echo false)"
assert_eq "that settings file's own hook is scoped to the seed dir, not the cwd" \
	"$seed_dir" "$(deny_hook_scratch_of "$SETTINGS_CONTENT_LOG")"
assert_true_seed_ne_cwd() {
	[ "$seed_dir" != "$call_cwd" ] && ok "the seed dir really is a different directory from the call's own cwd" \
		|| bad "test fixture bug: seed dir and cwd came out the same, so this doesn't prove anything"
}
assert_true_seed_ne_cwd
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
