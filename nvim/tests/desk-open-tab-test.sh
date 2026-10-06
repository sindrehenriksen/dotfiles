#!/usr/bin/env bash
# D8b test (the runner's own gap #2): claude/desk-lib/steps.sh's
# desk_step_open_tab — assembling the Wednesday tab's launch command from
# its step config (cwd_outside, restricted, permission_mode, tools,
# strict_mcp_config/mcp_config, settings, skill, the fixed prompt_text) and
# handing it to
# hammerspoon/desk-open-tab.sh, and skipping entirely when a session under
# the step's own `session_name` is already live (via the session-status.sh
# reader, faked here). The helper itself is faked throughout — this never
# opens a real Ghostty tab.
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

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
ARGV_LOG="$ROOT/open-tab-argv.log"
cat > "$FAKEBIN/desk-open-tab-fake.sh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$ARGV_LOG.command"
printf '%s\n' "\$2" > "$ARGV_LOG.session"
printf '%s\n' "\$3" > "$ARGV_LOG.cwd"
exit 0
FAKE
chmod +x "$FAKEBIN/desk-open-tab-fake.sh"
export DESK_OPEN_TAB_BIN="$FAKEBIN/desk-open-tab-fake.sh"

SESSION_STATUS_FIXTURE="$ROOT/sessions.jsonl"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
cat "$SESSION_STATUS_FIXTURE" 2> /dev/null
FAKE
chmod +x "$FAKEBIN/session-status.sh"
export PATH="$FAKEBIN:$PATH"

# mcp_config/settings/skill resolve relative to $DESK_CONFIG's own
# directory, like every other config path ($DESK_CONFIG standing in for
# an instance's desk/config.json).
export DESK_CONFIG="$ROOT/workspace/desk/config.json"
mkdir -p "$ROOT/workspace/desk"

# Without this, common.sh's own `mkdir -p "$DESK_STATE_DIR" ...` (sourced
# next) falls through to its real $HOME-based default and creates empty
# dirs under the real ~/.local/state/desk/ the moment it's sourced.
export DESK_STATE_DIR="$ROOT/state"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

step_json='{
	"id": "open-tab", "kind": "open_tab",
	"cwd_outside": "~/dev/example-workspace",
	"permission_mode": "default",
	"tools": ["Read", "Glob", "Grep", "Write", "Bash"],
	"strict_mcp_config": true,
	"mcp_config": "weekly/mcp.json",
	"settings": "weekly/settings.json",
	"skill": "../agents/skills/weekly-update/SKILL.md",
	"prompt_text": "Run the weekly update. The notes diff is ./notes-diff.md.",
	"session_name": "Weekly Update"
}'

echo "=== no live session under that name: the tab is assembled and opened ==="
: > "$SESSION_STATUS_FIXTURE"
rm -f "$ARGV_LOG.command" "$ARGV_LOG.session" "$ARGV_LOG.cwd"
result="$(desk_step_open_tab "$step_json")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "the helper was actually invoked" "$([ -f "$ARGV_LOG.command" ] && echo true || echo false)"

command_line="$(cat "$ARGV_LOG.command" 2> /dev/null)"
cwd_arg="$(cat "$ARGV_LOG.cwd" 2> /dev/null)"
session_arg="$(cat "$ARGV_LOG.session" 2> /dev/null)"
assert_eq "cwd_outside is expanded to \$HOME" "$HOME/dev/example-workspace" "$cwd_arg"
assert_eq "no session id is pinned (a fresh launch, not a resume)" "" "$session_arg"
assert_true "the command starts with the claude binary" "$(grep -qE "^'claude' " <<< "$command_line" && echo true || echo false)"
assert_true "a --restricted tab is never tagged DESK_HEADLESS (its own real hooks never load)" \
	"$([[ "$command_line" != DESK_HEADLESS=1\ * ]] && echo true || echo false)"
assert_true "-n names the session, so a later run's live-check can actually find it" \
	"$(grep -qF "'-n' 'Weekly Update'" <<< "$command_line" && echo true || echo false)"
assert_true "--restricted is present" "$(grep -q -- '--restricted' <<< "$command_line" && echo true || echo false)"
assert_true "--permission-mode default is present" "$(grep -q -- "'--permission-mode' 'default'" <<< "$command_line" && echo true || echo false)"
assert_true "--tools carries the exact CSV" \
	"$(grep -q -- "'--tools' 'Read,Glob,Grep,Write,Bash'" <<< "$command_line" && echo true || echo false)"
assert_true "--strict-mcp-config is present" "$(grep -q -- '--strict-mcp-config' <<< "$command_line" && echo true || echo false)"
assert_true "--mcp-config resolves against \$DESK_CONFIG's own dir" \
	"$(grep -qE -- "--mcp-config' '$ROOT/workspace/desk/weekly/mcp.json'" <<< "$command_line" && echo true || echo false)"
assert_true "--settings resolves the same way" \
	"$(grep -qE -- "--settings' '$ROOT/workspace/desk/weekly/settings.json'" <<< "$command_line" && echo true || echo false)"
assert_true "the skill is passed in explicitly via --append-system-prompt-file" \
	"$(grep -qE -- "--append-system-prompt-file' '$ROOT/workspace/desk/../agents/skills/weekly-update/SKILL.md'" <<< "$command_line" && echo true || echo false)"
assert_true "the prompt follows --, so no variadic flag (--tools, --mcp-config) can swallow it" \
	"$(grep -qF "'--' 'Run the weekly update. The notes diff is ./notes-diff.md.'" <<< "$command_line" && echo true || echo false)"
assert_true "the fixed prompt_text is the final argument, single-quoted" \
	"$(grep -qF "'Run the weekly update. The notes diff is ./notes-diff.md.'" <<< "$command_line" && echo true || echo false)"

echo
echo "=== a live session already under that name: skipped, the helper is never called ==="
jq -nc --arg n "Weekly Update" '{id: "s9", name: $n, status: "busy", live: true}' > "$SESSION_STATUS_FIXTURE"
rm -f "$ARGV_LOG.command"
result="$(desk_step_open_tab "$step_json")"
assert_eq "the step still reports ok (nothing went wrong)" "ok" "$result"
assert_true "the helper was never invoked" "$([ ! -f "$ARGV_LOG.command" ] && echo true || echo false)"

echo
echo "=== a same-named session that's ended (not live): opens anyway ==="
jq -nc --arg n "Weekly Update" '{id: "s9", name: $n, status: "ended", live: false}' > "$SESSION_STATUS_FIXTURE"
rm -f "$ARGV_LOG.command"
result="$(desk_step_open_tab "$step_json")"
assert_eq "the step reports ok" "ok" "$result"
assert_true "the helper was invoked (an ended session doesn't block a new tab)" \
	"$([ -f "$ARGV_LOG.command" ] && echo true || echo false)"

echo
echo "=== scratch_dir + notes-diff fields: the tab opens in a fresh scratch dir seeded with notes-diff.md ==="
notes_repo="$ROOT/notes"
desk_test_assert_repo_under_root "$notes_repo" "$ROOT"
mkdir -p "$notes_repo"
git -C "$notes_repo" init -q
git -C "$notes_repo" config user.email test@example.invalid
git -C "$notes_repo" config user.name "Desk Test"
printf 'Alpha: existing block\n' > "$notes_repo/notes.md"
git -C "$notes_repo" add notes.md
GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" \
	git -C "$notes_repo" commit -q -m initial
printf 'Alpha: existing block\nHis own new line\n' > "$notes_repo/notes.md"
git -C "$notes_repo" add notes.md
git -C "$notes_repo" commit -q -m "his own edit"
: > "$notes_repo/reading.md"
git -C "$notes_repo" add reading.md
git -C "$notes_repo" commit -q -m "add reading.md"

scratch_root="$ROOT/weekly-scratch"
scratch_step_json='{
	"id": "open-tab", "kind": "open_tab",
	"cwd_outside": "~/dev/example-workspace",
	"permission_mode": "default",
	"prompt_text": "Run the weekly update. The notes diff is ./notes-diff.md.",
	"scratch_dir": "'"$scratch_root"'",
	"notes_diff_file": "notes-diff.md",
	"notes_diff_since": "last_wednesday"
}'
: > "$SESSION_STATUS_FIXTURE"
rm -f "$ARGV_LOG.command" "$ARGV_LOG.cwd"
result="$(desk_step_open_tab "$scratch_step_json" "$notes_repo" notes.md reading.md)"
assert_eq "the step reports ok" "ok" "$result"
scratch_cwd_arg="$(cat "$ARGV_LOG.cwd" 2> /dev/null)"
assert_true "the tab's cwd is a fresh dir under scratch_dir, not cwd_outside" \
	"$([[ "$scratch_cwd_arg" == "$scratch_root"/* ]] && echo true || echo false)"
assert_true "the fresh scratch dir actually exists" "$([ -d "$scratch_cwd_arg" ] && echo true || echo false)"
diff_file="$scratch_cwd_arg/notes-diff.md"
assert_true "notes-diff.md was seeded into it" "$([ -s "$diff_file" ] && echo true || echo false)"
assert_true "it carries his own edit" "$(grep -qF '+ His own new line' "$diff_file" 2> /dev/null && echo true || echo false)"
assert_true "the diff body is fenced" "$(grep -q '^```$' "$diff_file" 2> /dev/null && echo true || echo false)"

echo
echo "=== restricted: false — his default permissions, no isolation flags ==="
default_perms_step_json='{
	"id": "open-tab", "kind": "open_tab",
	"cwd_outside": "~/dev/example-workspace",
	"restricted": false,
	"permission_mode": "default",
	"tools": ["Read", "Glob", "Grep", "Write", "Bash"],
	"strict_mcp_config": true,
	"settings": "weekly/settings.json",
	"prompt_text": "Run the weekly update. The notes diff is ./notes-diff.md.",
	"session_name": "Weekly Update"
}'
: > "$SESSION_STATUS_FIXTURE"
rm -f "$ARGV_LOG.command" "$ARGV_LOG.session" "$ARGV_LOG.cwd"
result="$(desk_step_open_tab "$default_perms_step_json")"
assert_eq "the step reports ok" "ok" "$result"
command_line="$(cat "$ARGV_LOG.command" 2> /dev/null)"
assert_true "--restricted is absent" "$(grep -q -- '--restricted' <<< "$command_line" && echo false || echo true)"
assert_true "--permission-mode is absent" "$(grep -q -- '--permission-mode' <<< "$command_line" && echo false || echo true)"
assert_true "--tools is absent" "$(grep -q -- '--tools' <<< "$command_line" && echo false || echo true)"
assert_true "--strict-mcp-config is absent" "$(grep -q -- '--strict-mcp-config' <<< "$command_line" && echo false || echo true)"
assert_true "-n still names the session" \
	"$(grep -qF "'-n' 'Weekly Update'" <<< "$command_line" && echo true || echo false)"
assert_true "--settings still resolves, independent of restricted" \
	"$(grep -qE -- "--settings' '$ROOT/workspace/desk/weekly/settings.json'" <<< "$command_line" && echo true || echo false)"
assert_true "the command is tagged DESK_HEADLESS=1 (review item #1: the Wednesday tab's session is tagged desk-run too)" \
	"$([[ "$command_line" == DESK_HEADLESS=1\ * ]] && echo true || echo false)"

echo
echo "=== missing cwd_outside or prompt_text: fails rather than opening a bare shell ==="
bad_step='{"id": "open-tab", "kind": "open_tab", "prompt_text": "x"}'
result="$(desk_step_open_tab "$bad_step")"
assert_eq "reports failed" "failed" "$result"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
