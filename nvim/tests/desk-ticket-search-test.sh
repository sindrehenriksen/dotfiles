#!/usr/bin/env bash
# The ticket search (claude/desk-lib/ticket-search.sh), through desk-run: a
# fetch step with `ticket_search` gets the runner's query, the runner reads
# the raw result itself, a result saved to a file because it was too large
# for the call included, and the judge gets the runner's
# {window, tickets, coverage} in place of the step's reply, cut to the
# tickets created in the window. A result that cannot be read fails the
# step, so the pass reads partial and the judge is told the check failed.
# Offline: `claude` is a fake.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"

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

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export DESK_FETCH_CACHE_ROOT="$STATE/fetch-cache"
export DESK_TICKET_CACHE="$STATE/ticket-status.json"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
mkdir -p "$STATE" "$CLAUDE_CONFIG_DIR"

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
git -C "$repo" add notes.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main

INST="$ROOT/instance"
mkdir -p "$INST"
printf 'Search with jql={{ticket_search_jql}}\nfields={{ticket_search_fields}}\n' > "$INST/f-new.md"
echo "judge" > "$INST/j.md"
jq -n --arg repo "$repo" '
def steps: [
	{id: "F-new", kind: "fetch", prompt: "f-new.md", tools: ["mcp__tickets__search"], connector: false, timeout: 30,
	 ticket_search: {jql: "project = ABC AND creator != currentUser()", self: ["Test User"]}},
	{id: "J", kind: "judge", prompt: "j.md", tools: ["Read"], input_files: ["notes.md", "f-new.json"], timeout: 30}];
{
	notes_repo: $repo, timezone: "UTC", files: ["notes.md"],
	ticket_search_tool: "mcp__tickets__search", mail_search_tool: "none", ticket_status_step_id: "none", mail_fetch_step_id: "none",
	passes: {spilled: {steps: steps}, lost: {steps: steps}}
}' > "$INST/config.json"

NOW="$(date +%s)"
iso() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%S.000+0000")'; }
issue() { # key created assignee description
	jq -cn --arg k "$1" --arg c "$2" --arg a "$3" --arg d "$4" '
		{key: $k, fields: {summary: ("Summary of " + $k), status: {name: "To Do"}, issuetype: {name: "Task"},
		  creator: {displayName: "Ada Other"}, assignee: (if $a == "" then null else {displayName: $a} end),
		  created: $c, parent: null, labels: [], priority: {name: "Medium"}, description: $d}}'
}
{
	issue ABC-1 "$(iso $((NOW - 3600)))" "Test User" "Set up the thing."
	issue ABC-2 "$(iso $((NOW - 1800)))" "" "Ask Test User about the plan."
	issue ABC-3 "$(iso $((NOW - 3 * 86400)))" "" "Older than the window."
} | jq -cs '{issues: ., isLast: true}' > "$ROOT/issues.json"

J_SEEN="$ROOT/j-saw.json"
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" << FAKE
#!/usr/bin/env bash
J_SEEN="$J_SEEN"
ISSUES="$ROOT/issues.json"
FAKE
cat >> "$FAKEBIN/claude" << 'FAKE'
cwd="$(pwd -P)"
case "$cwd" in
	*-F-new-*)
		q="$(sed -n 's/^Search with jql=//p' prompt.txt)"
		printf '%s\n' "$q" > "$J_SEEN.query"
		jq -nc --arg q "$q" '{type:"assistant",message:{content:[{type:"tool_use",id:"u1",name:"mcp__tickets__search",input:{jql:$q}}]}}'
		# Too large for the call: Claude Code saves it under the project
		# folder and the call sees only where. The lost pass's file is gone.
		saved="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')/sess/tool-results/saved-1.txt"
		case "$cwd" in
			*/lost-*) ;;
			*) mkdir -p "$(dirname "$saved")"; jq -c '[{type: "text", text: tojson}]' "$ISSUES" > "$saved" ;;
		esac
		jq -nc --arg p "$saved" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"u1",
			content:("Output too large. Output has been saved to " + $p + ".")}]}}'
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"candidates\":[{\"key\":\"MADE-UP-1\"}]}"}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-J-*)
		cp f-new.json "$J_SEEN" 2> /dev/null
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"items\":[]}"}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*) echo '{"type":"result","subtype":"success"}' ;;
esac
FAKE
chmod +x "$FAKEBIN/claude"
export DESK_CLAUDE_BIN="$FAKEBIN/claude"

echo "=== a result saved to a file is read by the runner, cut to the window ==="
DESK_CONFIG="$INST/config.json" "$DESK_RUN" spilled > "$ROOT/spilled.out" 2>&1
rc=$?
assert_eq "the pass is ok" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    /' "$ROOT/spilled.out"
assert_eq "the judge gets the tickets created in the window, not the reply's" '["ABC-1","ABC-2"]' \
	"$(jq -c '[.tickets[].key]' "$J_SEEN" 2> /dev/null)"
assert_eq "each with its creator" '["Ada Other","Ada Other"]' "$(jq -c '[.tickets[].creator]' "$J_SEEN" 2> /dev/null)"
assert_eq "the user's part is marked" '["assigned","mentioned"]' "$(jq -c '[.tickets[].user_part]' "$J_SEEN" 2> /dev/null)"
assert_eq "coverage counts what came back and what was kept" "3 returned, 2 created in the window" \
	"$(jq -r '.coverage' "$J_SEEN" 2> /dev/null)"
assert_eq "the query the call ran was the runner's, in relative minutes" "true" \
	"$(grep -qx '(project = ABC AND creator != currentUser()) AND created >= -[0-9]*m' "$J_SEEN.query" && echo true || echo false)"

echo
echo "=== a saved result that cannot be read fails the step, and the judge is told ==="
rm -f "$J_SEEN"
DESK_CONFIG="$INST/config.json" "$DESK_RUN" lost > "$ROOT/lost.out" 2>&1
assert_eq "the pass reads partial" "partial" "$(jq -r '.passes.lost.result' "$DESK_STATUS_FILE")"
assert_eq "the step is named as the failed source" '["F-new"]' "$(jq -c '.passes.lost.failed_sources' "$DESK_STATUS_FILE")"
assert_eq "the judge still ran, and got no tickets" "[]" "$(jq -c '.tickets' "$J_SEEN" 2> /dev/null)"
assert_eq "with a coverage saying the check failed" "FAILED:" "$(jq -r '.coverage[0:7]' "$J_SEEN" 2> /dev/null)"
assert_eq "and the log says so" "true" "$(grep -q 'ticket search did not come back whole' "$ROOT/lost.out" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
