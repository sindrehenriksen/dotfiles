#!/usr/bin/env bash
# D8b test (the runner's own gap #1: "render the {{name}} scalars and
# scratch-dir input files each prompt expects"): claude/desk-lib/steps.sh's
# desk_step_judge, exercised directly (not through desk-run) so the
# placeholders_json/pass_ctx_json it's handed are fully under this test's
# control. Verifies, against a real repo/ledger and a fake `claude` that
# copies out whatever its own cwd (the call's scratch dir) actually holds:
# the {{mode}}/{{today}}/{{caps}}/{{scratch}} placeholders render; notes.md
# is seeded from HEAD with an accepted ledger item's own line marked;
# sources.json, f-private.json, f-web.json, tickets.json, sessions.json and
# open-items.json are all produced from their own real sources (the ledger,
# a fetch step's own raw stream, the ticket-cache diff, session-status.sh).
# No live model call, session-status.sh faked, nothing pushed anywhere.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"
CLI="$HERE/../lua/desk/cli.lua"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
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
CAPTURE="$ROOT/capture"
mkdir -p "$CAPTURE"
cat > "$FAKEBIN/claude" <<FAKE
#!/usr/bin/env bash
# cwd is the call's own scratch dir (a copy of the seed desk_step_judge
# built) — capture every file J's own prompt says it can expect there,
# for this test's own inspection, since that scratch dir is gone (rm -rf'd)
# by the time desk_step_judge itself returns.
for f in prompt.txt notes.md sources.json f-private.json f-web.json tickets.json sessions.json open-items.json; do
	cp -f "\$f" "$CAPTURE/\$f" 2>/dev/null
done
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"items\":[]}"}]}}'
echo '{"type":"result","subtype":"success"}'
exit 0
FAKE
chmod +x "$FAKEBIN/claude"

SESSION_STATUS_FIXTURE="$ROOT/sessions.jsonl"
cat > "$FAKEBIN/session-status.sh" <<FAKE
#!/usr/bin/env bash
cat "$SESSION_STATUS_FIXTURE"
FAKE
chmod +x "$FAKEBIN/session-status.sh"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_TICKET_CACHE="$STATE/ticket-status.json"
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
# shellcheck source=../../claude/desk-lib/git-ops.sh
source "$LIB/git-ops.sh"
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/validate.sh
source "$LIB/validate.sh"
# shellcheck source=../../claude/desk-lib/ticket-cache.sh
source "$LIB/ticket-cache.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"
# shellcheck source=../../claude/desk-lib/steps.sh
source "$LIB/steps.sh"

PASS_SCRATCH="$ROOT/pass-scratch"
mkdir -p "$PASS_SCRATCH"

# --- the repo: an already-accepted line, a queued suggestion in the ledger ---
repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'accepted line\nSection A\n  detail\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial

recs="$ROOT/ledger-recs.ndjson"
cat > "$recs" <<EOF
{"type":"item","id":"acc1","file":"notes.md","kind":"new","anchor":"top","before":"","after":"accepted line","source":"test","headline":"already accepted"}
{"type":"laid_in","at":1,"proposal":"p1","items":["acc1"]}
{"type":"item","id":"q1","file":"notes.md","kind":"add","anchor":{"under":"Section A"},"before":"","after":"  a queued suggestion","source":"notes","headline":"still open"}
EOF
nvim -l "$CLI" ledger-append-batch "$repo" "$recs" > /dev/null

# --- sources.json's own source file ---
sources_path="$ROOT/sources.json"
echo '{"marker": "MARKER_SOURCES_CONTENT"}' > "$sources_path"

# --- F-private / F-web's own raw stream, as if those steps already ran ---
cat > "$PASS_SCRATCH/F-private-stream.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"{\"candidates\":[{\"source\":\"slack\",\"url\":\"https://example.invalid/p1\"}]}"}]}}
EOF
cat > "$PASS_SCRATCH/F-web-stream.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"{\"candidates\":[{\"source\":\"web\",\"url\":\"https://example.invalid/w1\"}]}"}]}}
EOF

# --- ticket cache: a status change (TICKET-1) and an unchanged/new one (TICKET-2) ---
old_ticket_cache='{"tickets":{"TICKET-1":{"status":"Open","summary":"s1"}}}'
jq -n '{checked_at: 999, tickets: {"TICKET-1": {status: "Done", summary: "s1"}, "TICKET-2": {status: "Open", summary: "s2"}}}' \
	> "$DESK_TICKET_CACHE"

# --- sessions.json's own reader fixture ---
jq -nc '{id: "s1", name: "Alpha", status: "busy", live: true}' > "$SESSION_STATUS_FIXTURE"

# --- J's own prompt: references every scalar placeholder this test checks ---
prompt_file="$ROOT/j-prompt.md"
cat > "$prompt_file" <<'EOF'
mode={{mode}}
today={{today}}
caps={{caps}}
scratch={{scratch}}
EOF

pass_ctx="$(jq -n --arg repo "$repo" --arg sources_path "$sources_path" --arg pass_scratch "$PASS_SCRATCH" \
	--argjson old_ticket_cache "$old_ticket_cache" '{
		repo: $repo, sources_path: $sources_path, pass_scratch: $pass_scratch,
		old_ticket_cache: $old_ticket_cache
	}')"
placeholders="$(jq -n --arg caps "ACT ≤3, worth knowing ≤3, wildcard ≤1" \
	'{mode: "WEEKLY", today: "2026-09-27", caps: $caps}')"
step_json="$(jq -n --arg prompt "$prompt_file" \
	'{id: "J", kind: "judge", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30}')"

result="$(desk_step_judge "testpass" "$step_json" "$repo" "$placeholders" "$pass_ctx" notes.md reading.md)"
assert_true "the call reports ok" "$([ "$result" = "ok" ] && echo true || echo false)"

echo
echo "=== scalar placeholders rendered into the prompt ==="
prompt_out="$(cat "$CAPTURE/prompt.txt" 2> /dev/null)"
assert_true "mode" "$(grep -qx 'mode=WEEKLY' <<< "$prompt_out" && echo true || echo false)"
assert_true "today" "$(grep -qx 'today=2026-09-27' <<< "$prompt_out" && echo true || echo false)"
assert_true "caps" "$(grep -qx 'caps=ACT ≤3, worth knowing ≤3, wildcard ≤1' <<< "$prompt_out" && echo true || echo false)"
assert_true "scratch (auto-injected, a real absolute path)" \
	"$(grep -qE '^scratch=/' <<< "$prompt_out" && echo true || echo false)"

echo
echo "=== notes.md: HEAD content, the accepted line marked, the rest untouched ==="
notes_out="$(cat "$CAPTURE/notes.md" 2> /dev/null)"
assert_true "the accepted line is marked" \
	"$(grep -qF "accepted line${DESK_AGENT_MARK}" <<< "$notes_out" && echo true || echo false)"
assert_true "an ordinary line is not marked" \
	"$(grep -qx '  detail' <<< "$notes_out" && echo true || echo false)"

echo
echo "=== sources.json: the configured source file, copied verbatim ==="
assert_true "sources.json holds the marker" \
	"$(grep -q MARKER_SOURCES_CONTENT "$CAPTURE/sources.json" 2> /dev/null && echo true || echo false)"

echo
echo "=== f-private.json / f-web.json: each fetch step's own final text ==="
assert_true "f-private.json holds F-private's own candidate" \
	"$(jq -e '.candidates[0].source == "slack"' > /dev/null 2>&1 "$CAPTURE/f-private.json" && echo true || echo false)"
assert_true "f-web.json holds F-web's own candidate" \
	"$(jq -e '.candidates[0].source == "web"' > /dev/null 2>&1 "$CAPTURE/f-web.json" && echo true || echo false)"

echo
echo "=== tickets.json: only the ticket whose status actually changed ==="
assert_true "exactly one changed ticket" "$(jq 'length == 1' "$CAPTURE/tickets.json" 2> /dev/null)"
assert_true "TICKET-1, Open -> Done" \
	"$(jq -e '.[0].key == "TICKET-1" and .[0].previous_status == "Open" and .[0].status == "Done"' \
		> /dev/null 2>&1 "$CAPTURE/tickets.json" && echo true || echo false)"

echo
echo "=== sessions.json: names and status only ==="
assert_true "Alpha, busy" \
	"$(jq -e '. == [{"name":"Alpha","status":"busy"}]' > /dev/null 2>&1 "$CAPTURE/sessions.json" && echo true || echo false)"

echo
echo "=== open-items.json: the still-queued suggestion, never the accepted one ==="
assert_true "q1 is present" \
	"$(jq -e '[.[] | select(.id == "q1")] | length == 1' > /dev/null 2>&1 "$CAPTURE/open-items.json" && echo true || echo false)"
assert_true "acc1 (already accepted) is absent" \
	"$(jq -e '[.[] | select(.id == "acc1")] | length == 0' > /dev/null 2>&1 "$CAPTURE/open-items.json" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
