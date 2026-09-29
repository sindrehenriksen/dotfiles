#!/usr/bin/env bash
# A judge/close call's own Read is scoped to that call's own scratch dir —
# desk_step_allowed_tools (claude/desk-lib/steps.sh) turns a bare "Read" in
# a judge/close step's `tools` into `Read(<scratch>/**)`, an absolute glob,
# instead of an unscoped "Read" — those two kinds only ever legitimately
# read their own seeded scratch files, never anywhere else. Any other kind
# (fetch here) keeps the old unscoped behavior. "<scratch>" is always
# call_scratch, this call's own REAL cwd (never merely a directory its
# prompt or --allowedTools *name*): a live 16:30 close call once got every
# Read refused because `--restricted` confines file tools to the actual
# cwd, and its own cwd (a properly-named, freshly created scratch dir)
# differed from the seed dir its Read rule and prompt instead pointed at.
# A caller's own seed dir (desk_step_judge/desk_step_close, seeding this
# call's input files ahead of time) is always copied INTO call_scratch,
# never adopted as the cwd directly — call_scratch keeps its own
# "$pass-$id"/kept-runs naming either way (relied on elsewhere: log lines,
# a fake-claude test harness routing by cwd basename) — so cwd and the
# scoped-Read directory always come out identical. Exercises
# desk_step_model_call directly (no live model call: a fake `claude` on
# PATH records its own argv and cwd).
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
# An ephemeral call's own cwd is rm -rf'd by desk_step_model_call itself
# right after this fake claude returns (same reason SETTINGS_CONTENT_LOG
# above exists), so whether a seeded file actually landed in cwd has to be
# captured here too, while cwd still exists, rather than read back after.
NOTES_CONTENT_LOG="$ROOT/notes-content.log"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
pwd > "$CWD_LOG"
printf '%s\n' "\$@" > "$ARGV_LOG"
: > "$SETTINGS_CONTENT_LOG"
: > "$NOTES_CONTENT_LOG"
[ -f notes.md ] && cat notes.md > "$NOTES_CONTENT_LOG"
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
echo "=== a judge call given a seed dir (its own caller's seeded inputs) copies it INTO its own cwd ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ARGV_LOG"
: > "$CWD_LOG"
seed_dir="$ROOT/judge-seed-fixture"
mkdir -p "$seed_dir"
printf 'a seeded file\n' > "$seed_dir/notes.md"
step_json='{"id":"B2","kind":"judge","tools":["Read"],"connector":false,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "judge" '{}' "$seed_dir")"
assert_eq "the call reports ok" "ok" "$result"
call_cwd="$(cat "$CWD_LOG")"
assert_true "cwd is its OWN dir, never the seed dir itself (naming elsewhere depends on that)" \
	"$([ "$call_cwd" != "$seed_dir" ] && echo true || echo false)"
assert_eq "the seed dir's own content was copied into cwd" "a seeded file" "$(cat "$NOTES_CONTENT_LOG")"
assert_eq "--allowedTools scopes Read to cwd, matching where the content actually landed" \
	"Read($call_cwd/**)" "$(allowed_tools_of "$ARGV_LOG")"
rm -rf "$PASS_SCRATCH" "$call_cwd"

echo
echo "=== a non-visible close call copies its own seed dir INTO its own cwd (cwd == scoped Read, not the seed dir) ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ARGV_LOG"
: > "$CWD_LOG"
seed_dir="$ROOT/close-seed-fixture"
mkdir -p "$seed_dir"
printf 'a seeded file\n' > "$seed_dir/notes.md"
step_json='{"id":"C","kind":"close","tools":["Read"],"connector":false,"timeout":30}'
result="$(desk_step_model_call "testpass" "$step_json" "close" '{}' "$seed_dir")"
assert_eq "the call reports ok" "ok" "$result"
call_cwd="$(cat "$CWD_LOG")"
assert_true "cwd is its OWN dir, never the seed dir itself" \
	"$([ "$call_cwd" != "$seed_dir" ] && echo true || echo false)"
assert_eq "the seed dir's own content was copied into cwd" "a seeded file" "$(cat "$NOTES_CONTENT_LOG")"
assert_eq "--allowedTools scopes Read to cwd — a --restricted call's Read only ever reaches its real cwd" \
	"Read($call_cwd/**)" "$(allowed_tools_of "$ARGV_LOG")"
close_settings="$(settings_of "$ARGV_LOG")"
assert_eq "a --settings file was also passed (the deny hook's own backstop)" \
	"true" "$([ -n "$close_settings" ] && echo true || echo false)"
assert_eq "that settings file's own hook is scoped to the same cwd" \
	"$call_cwd" "$(deny_hook_scratch_of "$SETTINGS_CONTENT_LOG")"
rm -rf "$PASS_SCRATCH" "$call_cwd"

echo
echo "=== a VISIBLE close call keeps its kept-runs cwd; the seed dir is copied INTO it, same as non-visible ==="
PASS_SCRATCH="$(mktemp -d)"
: > "$ARGV_LOG"
: > "$CWD_LOG"
seed_dir="$ROOT/close-seed-visible-fixture"
mkdir -p "$seed_dir"
printf 'a seeded file\n' > "$seed_dir/notes.md"
step_json='{"id":"C2","kind":"close","tools":["Read"],"connector":false,"timeout":30,"visible":true}'
result="$(desk_step_model_call "visiblepass" "$step_json" "close" '{}' "$seed_dir" "" "2026-09-28")"
assert_eq "the call reports ok" "ok" "$result"
call_cwd="$(cat "$CWD_LOG")"
kept_dir="$(desk_pass_scratch_dir "visiblepass" "2026-09-28" "C2")"
assert_eq "cwd is the kept-runs dir (naming/resume/16:30-capture all key off it), not the seed dir itself" \
	"$kept_dir" "$call_cwd"
assert_eq "the seed dir's own content was copied into it" \
	"a seeded file" "$(cat "$kept_dir/notes.md" 2> /dev/null)"
assert_eq "--allowedTools scopes Read to the kept-runs dir, matching cwd" \
	"Read($kept_dir/**)" "$(allowed_tools_of "$ARGV_LOG")"
# A visible call's own cwd is left standing for a later `claude --resume` —
# not removed the way an ephemeral one is above — so clean it up here.
rm -rf "$kept_dir"
rm -rf "$PASS_SCRATCH"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
