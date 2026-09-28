#!/usr/bin/env bash
# "Visible run sessions" (design.md's later "Runs he can open and
# continue"): a step whose own config sets "visible": true gets a named,
# persisted call — --session-id/-n, no --no-session-persistence — instead
# of the ordinary ephemeral one; its cwd survives under
# $DESK_RUNS_ROOT/<pass>-<date>/<step> rather than being cleaned up; a
# --restricted call (no hooks) is recorded by the runner itself
# (session-recorder.sh start/end, source desk-run); a non-restricted
# (connector) call instead gets DESK_HEADLESS=1, trusting its own real
# hooks to record themselves; once the pass finishes, the pass's own
# `follow_up_step` is resolved back to a session and a tab opened
# (`claude --resume <id>`) in that call's own cwd; and a run more than 7
# days old (its own directory, and its config-dir project folder) is
# pruned. No live model call (claude, session-status.sh's resolve mode,
# and the Hammerspoon tab opener are all faked); session-recorder.sh is
# the real script, pointed at a throwaway store under a temp dir.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"
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

# Safety: this test drives real git commits (a throwaway notes repo). Refuse
# to run anywhere but under a throwaway temp dir, and never let the real
# dotfiles hookspath (set globally on this machine) or an inherited
# GIT_DIR/GIT_WORK_TREE point a git command at a real repo.
case "$(cd "$ROOT" && pwd -P)" in
	"${TMPDIR:-/nonexistent}"* | /tmp/* | /private/tmp/* | /private/var/folders/* | /var/folders/*) : ;;
	*)
		printf 'refusing to run: ROOT is not under a temp dir: %s\n' "$ROOT" >&2
		exit 1
		;;
esac
unset GIT_DIR GIT_WORK_TREE

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"

# --- fake claude: logs its own cwd/argv/env, writes a fixture line any
# --session-id/-n it was given so the fake session-status.sh below can
# resolve that name back to (id, cwd), same as a real Claude Code session
# would be resolvable by name. --------------------------------------------
CALL_LOG="$ROOT/calls.log"
: > "$CALL_LOG"
SESSIONS_FIXTURE="$ROOT/sessions-by-name.jsonl"
: > "$SESSIONS_FIXTURE"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
{
	printf 'CWD=%s\n' "\$PWD"
	printf 'ARGV=%s\n' "\$*"
	printf 'DESK_HEADLESS=%s\n' "\${DESK_HEADLESS:-}"
	printf '===\n'
} >> "$CALL_LOG"
sid="" name=""
prev=""
for a in "\$@"; do
	[ "\$prev" = "--session-id" ] && sid="\$a"
	[ "\$prev" = "-n" ] && name="\$a"
	prev="\$a"
done
if [ -n "\$name" ] && [ -n "\$sid" ]; then
	printf '{"name":"%s","id":"%s","cwd":"%s","last_activity":%d}\n' "\$name" "\$sid" "\$PWD" "\$(date +%s)" >> "$SESSIONS_FIXTURE"
fi
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

# --- fake session-status.sh: only its `resolve <name>` mode is exercised
# here (desk_open_follow_up_tab's own lookup) — exact match against the
# fixture the fake claude above just wrote. --------------------------------
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = "resolve" ]; then
	match="\$(grep -F "\"name\":\"\${2:-}\"" "$SESSIONS_FIXTURE" 2> /dev/null | tail -n1)"
	[ -n "\$match" ] || exit 1
	printf '%s\n' "\$match"
	exit 0
fi
cat "$SESSIONS_FIXTURE" 2> /dev/null
FAKE
chmod +x "$FAKEBIN/session-status.sh"

# --- fake the Hammerspoon tab opener: logs its own argv. -------------------
OPEN_TAB_LOG="$ROOT/open-tab-calls.log"
: > "$OPEN_TAB_LOG"
cat > "$FAKEBIN/desk-open-tab-fake.sh" <<FAKE
#!/usr/bin/env bash
printf 'CMD=%s\nSID=%s\nCWD=%s\n===\n' "\$1" "\${2:-}" "\${3:-}" >> "$OPEN_TAB_LOG"
exit 0
FAKE
chmod +x "$FAKEBIN/desk-open-tab-fake.sh"
export DESK_OPEN_TAB_BIN="$FAKEBIN/desk-open-tab-fake.sh"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
# The real recorder script, against a throwaway store — never the real
# ~/.local/state/claude/session-events.
export CLAUDE_SESSION_STORE="$ROOT/session-events"
export CLAUDE_SESSION_RECORDER_LOG="$ROOT/recorder.log"

repo="$ROOT/notes"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config core.hookspath "$ROOT/no-hooks"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial

today="$(date +%F)"

# Pre-seed a run directory more than 7 days old, with its own (fake)
# config-dir project folder, so this same run also exercises pruning.
old_date="$(date -v-10d +%F 2> /dev/null || date -d '10 days ago' +%F)"
old_step_dir="$DESK_RUNS_ROOT/testpass-$old_date/old-step"
mkdir -p "$old_step_dir"
old_step_real="$(cd "$old_step_dir" && pwd -P)" # a command substitution strips the trailing newline `pwd` itself prints; a raw pipe wouldn't, and `tr` would then turn that into a stray trailing '-' — see desk_project_folder_name's own printf '%s' for the same reason.
old_project_name="$(printf '%s' "$old_step_real" | tr -c 'A-Za-z0-9' '-')"
old_project_dir="$CLAUDE_CONFIG_DIR/projects/$old_project_name"
mkdir -p "$old_project_dir"
: > "$old_project_dir/leftover-transcript.jsonl"

cfg="$ROOT/config.json"
jq -n --arg repo "$repo" '{
	notes_repo: $repo,
	files: ["notes.md", "reading.md"],
	passes: { testpass: { follow_up_step: "F", steps: [
		{ id: "F", kind: "fetch", tools: ["Read"], timeout: 30, visible: true },
		{ id: "G", kind: "fetch", connector: true, tools: ["Read"], timeout: 30, visible: true },
		{ id: "H", kind: "fetch", tools: ["Read"], timeout: 30 }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
rc=$?
assert_eq "the run succeeds" "0" "$rc"

# --- pruning: the old run and its project folder are both gone -----------
assert_true "the old run directory (>7 days) was pruned" \
	"$([ ! -d "$DESK_RUNS_ROOT/testpass-$old_date" ] && echo true || echo false)"
assert_true "its config-dir project folder was pruned with it" \
	"$([ ! -d "$old_project_dir" ] && echo true || echo false)"

# --- per-call log sections, split on cwd (each call's own scratch dir) ---
section_for() { # matches a CWD=...<suffix> line
	awk -v suf="$1" '
		/^CWD=/ { cwd=$0; buf=$0 ORS; next }
		/^===$/ { if (cwd ~ suf) print buf; buf=""; cwd=""; next }
		{ buf = buf $0 ORS }
	' "$CALL_LOG"
}

f_section="$(section_for "/F$")"
g_section="$(section_for "/G$")"
h_section="$(section_for "-H-")"

echo "=== F: a restricted visible call ==="
assert_true "F's argv carries --session-id" "$(echo "$f_section" | grep -q -- '--session-id' && echo true || echo false)"
assert_true "F's argv is named desk-testpass-<date>-F" \
	"$(echo "$f_section" | grep -q -- "-n desk-testpass-$today-F" && echo true || echo false)"
assert_true "F's argv never sets --no-session-persistence" \
	"$(echo "$f_section" | grep -q -- '--no-session-persistence' && echo false || echo true)"
assert_true "F's call never set DESK_HEADLESS (restricted, manually recorded instead)" \
	"$(echo "$f_section" | grep -q '^DESK_HEADLESS=1$' && echo false || echo true)"

f_sid="$(echo "$f_section" | grep -oE -- '--session-id [^ ]+' | awk '{print $2}')"
f_scratch="$DESK_RUNS_ROOT/testpass-$today/F"
assert_true "F's own scratch dir still exists (never cleaned up)" \
	"$([ -d "$f_scratch" ] && echo true || echo false)"

f_store="$CLAUDE_SESSION_STORE/$f_sid.jsonl"
assert_true "F got a real start event, source desk-run" \
	"$([ -f "$f_store" ] && jq -rs 'map(select(.event=="start")) | last | .source' "$f_store" 2> /dev/null | grep -qx desk-run && echo true || echo false)"
assert_true "F's start event's own cwd is its scratch dir" \
	"$([ -f "$f_store" ] && jq -rs 'map(select(.event=="start")) | last | .cwd' "$f_store" 2> /dev/null | grep -qxF "$f_scratch" && echo true || echo false)"
assert_true "F also got a real end event" \
	"$([ -f "$f_store" ] && [ "$(jq -rs 'map(select(.event=="end")) | length' "$f_store" 2> /dev/null)" = "1" ] && echo true || echo false)"

echo
echo "=== G: a non-restricted (connector) visible call ==="
assert_true "G's argv carries --session-id" "$(echo "$g_section" | grep -q -- '--session-id' && echo true || echo false)"
assert_true "G's argv is named desk-testpass-<date>-G" \
	"$(echo "$g_section" | grep -q -- "-n desk-testpass-$today-G" && echo true || echo false)"
assert_true "G's call sets DESK_HEADLESS=1 (its own real hooks record it)" \
	"$(echo "$g_section" | grep -q '^DESK_HEADLESS=1$' && echo true || echo false)"

g_sid="$(echo "$g_section" | grep -oE -- '--session-id [^ ]+' | awk '{print $2}')"
assert_true "the runner never wrote a recorder event for G itself (no double-record)" \
	"$([ ! -f "$CLAUDE_SESSION_STORE/$g_sid.jsonl" ] && echo true || echo false)"
assert_true "G's own scratch dir still exists too" \
	"$([ -d "$DESK_RUNS_ROOT/testpass-$today/G" ] && echo true || echo false)"

echo
echo "=== H: an ordinary (non-visible) call keeps the old ephemeral behavior ==="
assert_true "H's argv still sets --no-session-persistence" \
	"$(echo "$h_section" | grep -q -- '--no-session-persistence' && echo true || echo false)"
assert_true "H's argv never names a session" \
	"$(echo "$h_section" | grep -q -- ' -n ' && echo false || echo true)"
h_cwd="$(echo "$h_section" | grep '^CWD=' | head -n1 | cut -d= -f2-)"
assert_true "H's own scratch dir was cleaned up as before" \
	"$([ -n "$h_cwd" ] && [ ! -d "$h_cwd" ] && echo true || echo false)"

echo
echo "=== the follow-up tab: opened once, for F (the pass's own follow_up_step) ==="
assert_eq "desk-open-tab was called exactly once" "1" "$(grep -c '^CMD=' "$OPEN_TAB_LOG")"
assert_true "it resumes F's own session id" \
	"$(grep -q "CMD=claude --resume '$f_sid'" "$OPEN_TAB_LOG" && echo true || echo false)"
assert_true "it passes F's own session id as the session-id arg too" \
	"$(grep -q "^SID=$f_sid\$" "$OPEN_TAB_LOG" && echo true || echo false)"
assert_true "it opens in F's own cwd" \
	"$(grep -qF "CWD=$f_scratch" "$OPEN_TAB_LOG" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
