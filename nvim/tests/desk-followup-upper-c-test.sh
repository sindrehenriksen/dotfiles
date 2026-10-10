#!/usr/bin/env bash
# Every pass's follow-up tab goes through hammerspoon/desk-open-tab.sh ->
# DeskOpenTab (which places only in the ultrawide's upper_C slot), opens
# only once the pass has finished (status already final, no later model
# call), and is a plain resumed session with the user's own default permissions.
# Nothing else under claude/ opens a terminal tab. The Hammerspoon `hs`
# binary is stubbed; desk-open-tab.sh itself is the real script.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"
OPEN_TAB_SH="$HERE/../../hammerspoon/desk-open-tab.sh"
INIT_LUA="$HERE/../../hammerspoon/init.lua"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
assert_true() {
	if [ "$2" = "true" ]; then ok "$1"; else bad "$1 (got [$2])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
ORDER_LOG="$ROOT/order.log"
SESSIONS_FIXTURE="$ROOT/sessions.jsonl"
HS_EXPR_LOG="$ROOT/hs-expr.log"
HS_STATUS_LOG="$ROOT/hs-status.log"
: > "$ORDER_LOG"
: > "$SESSIONS_FIXTURE"

cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
echo "claude" >> "$ORDER_LOG"
sid="" name="" prev=""
for a in "\$@"; do
	[ "\$prev" = "--session-id" ] && sid="\$a"
	[ "\$prev" = "-n" ] && name="\$a"
	prev="\$a"
done
if [ -n "\$name" ] && [ -n "\$sid" ]; then
	printf '{"name":"%s","id":"%s","cwd":"%s","last_activity":%d,"live":false}\n' "\$name" "\$sid" "\$PWD" "\$(date +%s)" >> "$SESSIONS_FIXTURE"
fi
echo '{"type":"result","subtype":"success"}'
FAKE
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = "resolve" ]; then
	match="\$(grep -F "\"id\":\"\${2:-}\"" "$SESSIONS_FIXTURE" | tail -n1)"
	[ -n "\$match" ] || exit 1
	printf '%s\n' "\$match"
	exit 0
fi
cat "$SESSIONS_FIXTURE"
FAKE
cat > "$FAKEBIN/hs" <<FAKE
#!/usr/bin/env bash
echo "hs" >> "$ORDER_LOG"
prev=""
for a in "\$@"; do
	[ "\$prev" = "-c" ] && printf '%s\n' "\$a" >> "$HS_EXPR_LOG"
	prev="\$a"
done
cat "$ROOT/state/status.json" > "$HS_STATUS_LOG" 2> /dev/null
echo true
exit 0
FAKE
chmod +x "$FAKEBIN"/*

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export CLAUDE_SESSION_STORE="$ROOT/session-events"
export CLAUDE_SESSION_RECORDER_LOG="$ROOT/recorder.log"
export DESK_CLAUDE_BIN=claude
unset DESK_OPEN_TAB_BIN DESK_FOCUS_TAB_BIN
# The real desk-open-tab.sh, found by name on PATH exactly as in production.
mkdir -p "$ROOT/realbin"
ln -s "$OPEN_TAB_SH" "$ROOT/realbin/desk-open-tab.sh"
export PATH="$FAKEBIN:$ROOT/realbin:$PATH"

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial

cfg="$ROOT/config.json"
jq -n --arg repo "$repo" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "mcp__example-tickets__search",
	mail_search_tool: "mcp__claude_ai_Gmail__search_threads",
	ticket_status_step_id: "T",
	mail_fetch_step_id: "F-private",
	files: ["notes.md", "reading.md"],
	passes: { testpass: { follow_up_step: "F", steps: [
		{ id: "F", kind: "fetch", tools: ["Read"], timeout: 30, visible: true },
		{ id: "H", kind: "fetch", tools: ["Read"], timeout: 30 }
	] } }
}' > "$cfg"

DESK_CONFIG="$cfg" "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
assert_eq "the run succeeds" "0" "$?"

echo "=== through desk-open-tab.sh to DeskOpenTab ==="
assert_eq "hs was called exactly once" "1" "$(grep -c '^hs$' "$ORDER_LOG")"
expr="$(cat "$HS_EXPR_LOG")"
sid="$(jq -r '.id' "$SESSIONS_FIXTURE" | head -1)"
assert_true "the expression is a DeskOpenTab call resuming F's session id" \
	"$(case "$expr" in "DeskOpenTab(\"CLAUDE_CONFIG_DIR="*" claude --resume '$sid'\", \"$sid\", \""*) echo true ;; *) echo false ;; esac)"
assert_true "it asks for a background open, never taking focus" \
	"$(case "$expr" in *", { background = true })") echo true ;; *) echo false ;; esac)"
assert_true "it is a plain resume: the user's default permissions, no restricted envelope" \
	"$(case "$expr" in *--restricted* | *--permission-mode* | *--tools* | *--strict-mcp-config*) echo false ;; *) echo true ;; esac)"

echo
echo "=== only after the pass has finished ==="
assert_eq "the tab opener ran after every model call" "hs" "$(tail -n1 "$ORDER_LOG")"
assert_eq "the pass's status was already final when it ran" "ok" "$(jq -r '.passes.testpass.result' "$HS_STATUS_LOG")"

echo
echo "=== the opener only ever targets upper_C, or lower_C as its fallback, and sets no existing window's frame ==="
body="$(awk '/^function DeskOpenTab\(/{f=1} f{print} f && /^end$/{exit}' "$INIT_LUA")"
assert_true "found DeskOpenTab's body" "$([ -n "$body" ] && echo true || echo false)"
slot_body="$(awk '/^function DeskTab.slot_windows\(/{f=1} f{print} f && /^end$/{exit}' "$INIT_LUA")"
slots="$(printf '%s\n' "$slot_body" | rg -o '"(upper|lower|full|mid)[A-Za-z_]*"' | sort -u | tr -d '"' | tr '\n' ' ')"
assert_eq "the slots it names are upper_C and lower_C" "lower_C upper_C " "$slots"
assert_eq "DeskOpenTab names no slot of its own" "" \
	"$(printf '%s\n' "$body" | rg -o '"(upper|lower|full|mid)[A-Za-z_]*"' | sort -u | tr '\n' ' ')"
desk_section="$(awk '/^DeskTab = \{\}/{f=1} f{print} /^-- Dual-function Caps Lock/{exit}' "$INIT_LUA")"
assert_true "found the desk section" "$([ -n "$desk_section" ] && echo true || echo false)"
assert_eq "the desk section sets one frame, and nothing else moves or resizes a window" "1" \
	"$(printf '%s\n' "$desk_section" | grep -cE 'setFrame|setTopLeft|setSize|move[A-Z]|centerOnScreen')"
place_fn="$(awk '/^local function place_new_window\(/{f=1} f{print} f && /^end$/{exit}' "$INIT_LUA")"
assert_eq "that one is in place_new_window" "1" "$(printf '%s\n' "$place_fn" | grep -c 'setFrame')"
assert_true "which sets it only on the window DeskTab.created_window names, and only while it has focus" \
	"$(printf '%s\n' "$place_fn" | grep -q 'DeskTab.created_window' \
		&& printf '%s\n' "$place_fn" | grep -q 'id ~= now.window_id then return false' && echo true || echo false)"

echo
echo "=== nothing else under claude/ opens a terminal tab ==="
others="$(rg -l 'osascript|hs -c|open -a|tell application|new tab' "$HERE/../../claude" --glob '!tests' --glob '!*.md' 2> /dev/null | tr '\n' ' ')"
assert_eq "no other opener" "" "$others"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
