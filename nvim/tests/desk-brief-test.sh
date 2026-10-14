#!/usr/bin/env bash
# The central brief (claude/desk-lib/brief.sh), end to end through desk-run:
# what the run directory holds, the message the central session gets, and
# its delivery through the follow pass's pinned send. One fake `claude`
# plays the fetch and the send, running the send's deny hook on what it
# sends; the reader is a fake whose sessions each case writes. Covers: a
# brief waits while the central session is not running and a later run the
# same day sends it; a delivered brief is not sent again; a new day's run
# sends every pending run in one message, oldest first; a failed send keeps
# it pending, and an unconfirmed one is tried once more, then counted as
# sent; idle sessions reach the message through the close step's list; a
# pending run outlives the seven-day sweep; a shared name or none holds a
# brief; a failed pass still briefs; a weekend slot of a weekdays-only pass
# makes none of its own; another pass's pending brief goes with this pass's
# delivery as its own message. A step with `weekdays` runs only on those
# days. No live model call.
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
assert_contains() {
	local desc=$1 needle=$2 hay=$3
	if [[ "$hay" == *"$needle"* ]]; then ok "$desc"; else bad "$desc (no [$needle] in [$hay])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKEBIN="$ROOT/fakebin"
FIX="$ROOT/fix"
mkdir -p "$FAKEBIN" "$FIX"
CENTRAL="cccccccc-0000-4000-8000-000000000001"
IDLE="dddddddd-0000-4000-8000-000000000002"

# The reader: every session, or `resolve <token>` by id or unique name.
cat > "$FAKEBIN/session-status.sh" << FAKE
#!/usr/bin/env bash
f="$FIX/sessions.jsonl"
[ -f "\$f" ] || exit 0
if [ "\${1:-}" = resolve ]; then
	hits="\$(jq -cs --arg t "\$2" '[.[] | select(.id == \$t or .name == \$t)]' "\$f")"
	[ "\$(jq length <<< "\$hits")" = 1 ] || exit 1
	jq -c '.[0]' <<< "\$hits"
	exit 0
fi
cat "\$f"
FAKE
chmod +x "$FAKEBIN/session-status.sh"
export DESK_READER="$FAKEBIN/session-status.sh"
sessions() { # lines of: id name live
	: > "$FIX/sessions.jsonl"
	while read -r id name live; do
		[ -n "$id" ] || continue
		jq -cn --arg id "$id" --arg n "$name" --argjson l "$live" \
			'{id:$id, name:$n, live:$l, has_start_event:true, last_activity:0, duplicate_pids:false}' >> "$FIX/sessions.jsonl"
	done
}

cat > "$FAKEBIN/claude" << 'FAKE'
#!/usr/bin/env bash
settings="" tools=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
	case "${args[$i]}" in
		--settings) settings="${args[$((i + 1))]}" ;;
		--tools) tools="${args[$((i + 1))]}" ;;
	esac
done
emit_use() { jq -cn --arg id "$1" --arg name "$2" --argjson input "$3" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:$name,input:$input}]}}'; }
emit_text_result() { jq -cn --arg id "$1" --arg t "$2" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:$t}]}]}}'; }
if [ "$tools" = "SendMessage" ]; then
	input="$(jq -c '.[0]' pinned-args.json)"
	input="$(jq -c '. + {summary: "brief", recipient: .to, recipient_kind: "name", type: "message"}' <<< "$input")"
	printf '%s\n' "$input" >> "$BRIEF_TEST_SENT"
	cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")"
	emit_use t1 SendMessage "$input"
	if jq -cn --argjson i "$input" '{tool_name:"SendMessage", tool_input:$i}' | bash -c "$cmd" > /dev/null 2>&1; then
		if [ -n "${FAKE_SEND_RESULT:-}" ]; then
			emit_text_result t1 "$FAKE_SEND_RESULT"
		else
			emit_text_result t1 "$(jq -cn --arg to "$(jq -r .to <<< "$input")" --arg first "$(jq -r '.message | split("\n")[0]' <<< "$input")" \
				'{success:true, message:("“" + $first + "” → " + $to + " (another Claude session on this machine)"), msg_id:"m1"}')"
		fi
	else
		jq -cn '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t1",content:"PreToolUse hook denied this call",is_error:true}]}}'
	fi
	echo '{"type":"result","subtype":"success","total_cost_usd":0.02}'
	exit 0
fi
case "$(pwd -P)" in
	*-F-web-*)
		emit_use u1 WebSearch '{"query":"news"}'
		emit_text_result u1 'A post: https://example.com/a and more'
		jq -cn '{type:"assistant",message:{content:[{type:"text",text:({candidates:[{url:"https://example.com/a",summary:"a post"}]} | tojson)}]}}'
		;;
esac
echo '{"type":"result","subtype":"success","total_cost_usd":0.01}'
FAKE
chmod +x "$FAKEBIN/claude"
export BRIEF_TEST_SENT="$ROOT/sent.jsonl"
: > "$BRIEF_TEST_SENT"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_RUNS_ROOT="$STATE/runs"
export DESK_LOG_DIR="$STATE/logs"
export DESK_TICKET_CACHE="$STATE/ticket-status.json"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export CLAUDE_SESSION_READER_CACHE="$ROOT/reader-cache"
export DESK_LOCK_MAX_WAIT_SECS=2
export DESK_LOCK_POLL_SECS=1

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n  detail\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main

echo 'fetch the news' > "$ROOT/web.md"
printf 'Judge the run in {{run_dir}} from {{inputs}}, caps {{caps}}, for {{pass}} of {{scheduled_date}}.\n' > "$ROOT/brief.md"
printf 'Offer the sessions in {{run_dir}}/close.\n' > "$ROOT/close.md"
printf 'Send to {{to}}:\n-----BEGIN MESSAGE-----\n{{message}}\n-----END MESSAGE-----\n' > "$ROOT/send.md"

cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg central "$CENTRAL" '{
	notes_repo: $repo, timezone: "UTC",
	ticket_search_tool: "mcp__t__search", mail_search_tool: "mcp__m__search",
	ticket_status_step_id: "T-none", mail_fetch_step_id: "F-none",
	files: ["notes.md", "reading.md"],
	caps: {daily: {act: 3, worth_knowing: 3, wildcard: 1}},
	central_session: $central,
	close_after_working_days: 0,
	passes: {
		testpass: {
			steps: [
				{id: "commit-push", kind: "commit_push"},
				{id: "F-web", kind: "fetch", prompt: "web.md", tools: ["WebSearch"], connector: false, timeout: 30},
				{id: "F-mon", kind: "fetch", prompt: "web.md", tools: [], connector: false, timeout: 30, weekdays: [1]},
				{id: "close", kind: "close"}
			],
			brief: {
				input_files: ["notes.md", "f-web.json", "open-items.json"],
				instructions: ["brief.md", "close.md"],
				send: {prompt: "send.md"}
			}
		}
	}
}' > "$cfg"
export DESK_CONFIG="$cfg"

day() { # YYYY-MM-DD -> an epoch at noon UTC that day
	if [ "$(uname)" = Linux ]; then date -u -d "$1 12:00" +%s; else date -u -j -f '%Y-%m-%d %H:%M' "$1 12:00" +%s; fi
}
run() { # date, then the run's output goes to $ROOT/run.out
	DESK_NOW="$(day "$1")" TZ=UTC "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
}
sent_n() { wc -l < "$BRIEF_TEST_SENT" | tr -d ' '; }

echo "=== the central session not running: the run directory is written and the brief waits ==="
sessions <<< "$CENTRAL central-x false"
run 2026-10-05
assert_eq "the pass exits ok" "0" "$?"
R1="$DESK_RUNS_ROOT/testpass-2026-10-05"
assert_true "the inputs are seeded: the committed notes and the fetch's reply" \
	"$([ -f "$R1/inputs/notes.md" ] && jq -e '.candidates[0].url == "https://example.com/a"' "$R1/inputs/f-web.json" > /dev/null 2>&1 && echo true || echo false)"
assert_eq "the instruction files are rendered with the run's own paths and caps" \
	"Judge the run in $R1 from $R1/inputs, caps ACT ≤3, worth knowing ≤3, wildcard ≤1, for testpass of 2026-10-05." \
	"$(cat "$R1/instructions/brief.md" 2> /dev/null)"
assert_eq "the links a suggestion may cite are the fetch's" "https://example.com/a" "$(cat "$R1/allowed-urls.txt" 2> /dev/null)"
assert_eq "run.json has the result and the instruction files, in the config's order" \
	"[\"ok\",[\"$R1/instructions/brief.md\",\"$R1/instructions/close.md\"]]" "$(jq -c '[.result, .instructions]' "$R1/run.json" 2> /dev/null)"
assert_true "run-status.txt says how the run went" "$(grep -q 'It finished ok' "$R1/run-status.txt" 2> /dev/null && echo true || echo false)"
assert_true "it is pending" "$([ -f "$R1/brief.pending" ] && echo true || echo false)"
assert_eq "nothing was sent" "0" "$(sent_n)"
assert_true "the log says it waits" "$(grep -q 'brief: the central session is not running — testpass-2026-10-05 waits' "$ROOT/run.out" && echo true || echo false)"
msg="$(cat "$R1/brief-message.txt" 2> /dev/null)"
assert_eq "the message it waits with starts with the marker" \
	"[desk-brief] The testpass pass of 2026-10-05 is ready for you to judge. Not from the user." "$(head -n1 <<< "$msg")"
assert_contains "it names the run directory" "Run directory: $R1" "$msg"
assert_contains "and the instruction files to judge by, in order" "- Judge it by: $R1/instructions/brief.md, then $R1/instructions/close.md" "$msg"
assert_contains "and the inputs" "- inputs/: f-web.json, notes.md, open-items.json" "$msg"
assert_contains "and how it went" "- How it went: finished ok." "$msg"
also="- Also there: notes-changes.txt (the notes' own commits since the last judged brief), allowed-urls.txt"
assert_contains "an empty staged.json goes unmentioned" "$also." "$msg"
assert_eq "the first brief has no judged one to compare the notes against" "No earlier judged brief recorded a notes commit to compare against." "$(cat "$R1/notes-changes.txt")"
jq -n '{staged: [{headline: "a capture"}], held_back: []}' > "$ROOT/staged-probe.json"
mkdir -p "$ROOT/probe-run" && cp -R "$R1/." "$ROOT/probe-run/" && cp "$ROOT/staged-probe.json" "$ROOT/probe-run/staged.json"
assert_contains "one holding something is named" "$also, staged.json." \
	"$(bash -c 'source "$1/common.sh"; source "$1/brief.sh"; desk_brief_message testpass "$2"' _ "$LIB" "$ROOT/probe-run")"

assert_true "a Monday-only step runs on a Monday" "$(grep -q 'model call: F-mon' "$ROOT/run.out" && echo true || echo false)"

echo
echo "=== a later run the same day, the central session live: it is sent ==="
sessions <<< "$CENTRAL central-x true"
run 2026-10-05
assert_true "the pass itself does not run again" "$(grep -q 'already ran today' "$ROOT/run.out" && echo true || echo false)"
assert_eq "one send" "1" "$(sent_n)"
assert_eq "to the central session's current name" "central-x" "$(jq -r '.to' "$BRIEF_TEST_SENT" | tail -n1)"
assert_eq "with exactly the message" "$msg" "$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"
assert_eq "it is marked sent, confirmed" "true" "$(jq -r '.confirmed' "$R1/brief.sent" 2> /dev/null)"
assert_true "and no longer pending" "$([ ! -e "$R1/brief.pending" ] && echo true || echo false)"
run 2026-10-05
assert_eq "another run that day sends nothing more" "1" "$(sent_n)"

echo
echo "=== the notes' own commits since the last judged brief ==="
echo '{"items": []}' > "$R1/judgement.json"
printf 'Section A\n  detail\n  a line the user added\n' > "$repo/notes.md"
git -C "$repo" commit -q -am "Add a line"
echo
echo "=== a renamed central session is still found by its id ==="
sessions <<< "$CENTRAL central-renamed true"
run 2026-10-06
assert_eq "sent to its new name" "central-renamed" "$(jq -rs '.[-1].to' "$BRIEF_TEST_SENT")"
assert_true "the next run lists the notes' own commit since the judged brief, with its diff" \
	"$(grep -q '^    Add a line$' "$DESK_RUNS_ROOT/testpass-2026-10-06/notes-changes.txt" && grep -q '^+  a line the user added$' "$DESK_RUNS_ROOT/testpass-2026-10-06/notes-changes.txt" && echo true || echo false)"
assert_true "a Monday-only step is skipped on a Tuesday" \
	"$(grep -q 'step F-mon (fetch): skipped (it runs on weekdays 1 only)' "$ROOT/run.out" && ! grep -q 'model call: F-mon' "$ROOT/run.out" && echo true || echo false)"
assert_eq "and the pass is not partial for it" "ok" "$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"

echo
echo "=== a run of a new day sends every pending run in one message, oldest first ==="
sessions <<< "$CENTRAL central-x false"
run 2026-10-07
sessions <<< "$CENTRAL central-x true"
before="$(sent_n)"
run 2026-10-08
assert_eq "one send for both" "$((before + 1))" "$(sent_n)"
m="$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"
assert_eq "its first line names both" \
	"[desk-brief] 2 testpass passes are ready for you to judge, oldest first: 2026-10-07, 2026-10-08. The earlier ones could not be delivered when they ran. Not from the user." \
	"$(head -n1 <<< "$m")"
assert_true "and each run directory, oldest first" \
	"$(grep -n 'Run directory:' <<< "$m" | grep -q "testpass-2026-10-07" && [ "$(grep 'Run directory:' <<< "$m" | tail -n1)" = "Run directory: $DESK_RUNS_ROOT/testpass-2026-10-08" ] && echo true || echo false)"
assert_true "both are marked sent" \
	"$([ -f "$DESK_RUNS_ROOT/testpass-2026-10-07/brief.sent" ] && [ -f "$DESK_RUNS_ROOT/testpass-2026-10-08/brief.sent" ] && echo true || echo false)"

echo
echo "=== a failed send waits; an unconfirmed one is tried once more, then counted as sent ==="
FAKE_SEND_RESULT='{"success":false,"message":"No agent named central-x is reachable."}' run 2026-10-09
R4="$DESK_RUNS_ROOT/testpass-2026-10-09"
assert_true "a failed send leaves it pending" "$([ -f "$R4/brief.pending" ] && echo true || echo false)"
held='{"success":true,"message":"“x” → central-x (another Claude session on this machine; the message was held for that session'"'"'s approval)","msg_id":"m2"}'
FAKE_SEND_RESULT="$held" run 2026-10-09
assert_eq "an unconfirmed send keeps it pending, counted" "1" "$(jq -r '.unconfirmed_sends' "$R4/brief.pending" 2> /dev/null)"
FAKE_SEND_RESULT="$held" run 2026-10-09
assert_eq "the second unconfirmed send counts it as sent, unconfirmed" "false" "$(jq -r '.confirmed' "$R4/brief.sent" 2> /dev/null)"

echo
echo "=== idle sessions reach the message through the close step's list ==="
sessions << EOF
$CENTRAL central-x true
$IDLE idle-one true
EOF
run 2026-10-12
R5="$DESK_RUNS_ROOT/testpass-2026-10-12"
m="$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"
assert_contains "the message lists the idle session, never the central one" \
	"- close/: 1 idle session to offer for closing, each in close/<session id>/ with session.json and transcript.txt: idle-one (" "$m"
assert_true "its directory is there" "$([ -f "$R5/close/$IDLE/session.json" ] && [ -f "$R5/close/$IDLE/transcript.txt" ] && echo true || echo false)"
mkdir -p "$R5/retention"
jq -cn '[{session_id: "x", name: "old-spike", deletion_date: "2026-10-20", days_left: 8, dir: "d"}]' > "$R5/retention/candidates.json"
assert_contains "the retention step's list reaches the message" \
	"- retention/: 1 session the notes name whose transcripts Claude Code deletes soon, each in retention/<session id>/ with session.json and transcript.txt: old-spike (deleted 2026-10-20)." \
	"$(bash -c 'source "$1/common.sh"; source "$1/brief.sh"; desk_brief_message testpass "$2"' _ "$LIB" "$R5")"

echo
echo "=== a name that does not address the central session alone, or none, holds the brief ==="
sessions << EOF
$CENTRAL central-x true
eeeeeeee-0000-4000-8000-000000000003 central-x true
EOF
run 2026-10-13
assert_true "a shared name holds it, saying why" \
	"$(grep -q "brief: the name 'central-x' does not address the central session alone" "$ROOT/run.out" && [ -f "$DESK_RUNS_ROOT/testpass-2026-10-13/brief.pending" ] && echo true || echo false)"
jq -cn --arg id "$CENTRAL" '{id:$id, name:"", live:true, has_start_event:true, last_activity:0, duplicate_pids:false}' > "$FIX/sessions.jsonl"
run 2026-10-14
assert_true "a live session with no name is logged as that, not as not running" \
	"$(grep -q 'brief: the central session is running but has no name to send to' "$ROOT/run.out" && echo true || echo false)"

echo
echo "=== a failed pass still briefs, saying where it stopped ==="
sessions <<< "$CENTRAL central-x true"
jq '.passes.testpass.steps += [{id: "X", kind: "no-such-kind"}, {id: "F-after", kind: "fetch", prompt: "web.md", tools: [], connector: false, timeout: 30}]' "$cfg" > "$ROOT/cfg-fail.json"
DESK_CONFIG="$ROOT/cfg-fail.json" DESK_NOW="$(day 2026-10-15)" TZ=UTC "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
assert_eq "the pass reads failed" "failed" "$(jq -r '.result' "$DESK_RUNS_ROOT/testpass-2026-10-15/run.json" 2> /dev/null)"
m="$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"
assert_contains "and its brief says where it stopped" "- How it went: failed at step X, so the steps after it did not run." "$m"
assert_contains "the held ones go with it, oldest first" "oldest first: 2026-10-13, 2026-10-14, 2026-10-15" "$m"

echo
echo "=== a rerun clears the run's old judgement, so it is judged again ==="
echo '{"items": []}' > "$DESK_RUNS_ROOT/testpass-2026-10-15/judgement.json"
DESK_CONFIG="$ROOT/cfg-fail.json" DESK_NOW="$(day 2026-10-15)" TZ=UTC "$DESK_RUN" testpass --rerun > "$ROOT/run.out" 2>&1
assert_true "the old judgement.json is gone" "$([ ! -e "$DESK_RUNS_ROOT/testpass-2026-10-15/judgement.json" ] && echo true || echo false)"

echo
echo "=== a weekend slot of a weekdays-only pass makes no brief of its own, but sends one waiting ==="
sessions <<< "$CENTRAL central-x false"
run 2026-10-16
sessions <<< "$CENTRAL central-x true"
before="$(sent_n)"
jq '.passes.testpass.weekdays_only = true' "$cfg" > "$ROOT/cfg-wk.json"
DESK_CONFIG="$ROOT/cfg-wk.json" DESK_NOW="$(day 2026-10-17)" TZ=UTC "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
assert_eq "the Saturday run sends the Friday brief that waited" "$((before + 1))" "$(sent_n)"
assert_contains "naming that run" "Run directory: $DESK_RUNS_ROOT/testpass-2026-10-16" "$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"
assert_true "no run directory brief for the Saturday" "$([ ! -e "$DESK_RUNS_ROOT/testpass-2026-10-17/brief.pending" ] && [ ! -e "$DESK_RUNS_ROOT/testpass-2026-10-17/brief.sent" ] && echo true || echo false)"
assert_true "and the log says why" "$(grep -q 'brief: weekend slot' "$ROOT/run.out" && echo true || echo false)"

echo
echo "=== a brief with notes_diff_since carries the user's notes diff ==="
sessions <<< "$CENTRAL central-x true"
jq '.passes.testpass.brief.notes_diff_since = "last_wednesday"' "$cfg" > "$ROOT/cfg-nd.json"
DESK_CONFIG="$ROOT/cfg-nd.json" DESK_NOW="$(day 2026-10-21)" TZ=UTC "$DESK_RUN" testpass > "$ROOT/run.out" 2>&1
assert_true "notes-diff.md is written, the notes diff a tab would get" \
	"$(grep -q '^# Notes diff' "$DESK_RUNS_ROOT/testpass-2026-10-21/notes-diff.md" 2> /dev/null && echo true || echo false)"
assert_contains "and the message names it" ", notes-diff.md." "$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"

echo
echo "=== a brief another pass left pending goes with this pass's delivery, as its own message ==="
jq '.passes.otherpass = {steps: [{id: "F-web", kind: "fetch", prompt: "web.md", tools: ["WebSearch"], connector: false, timeout: 30}],
	brief: {input_files: ["notes.md", "f-web.json"], instructions: ["brief.md"], send: {prompt: "send.md"}}}' "$cfg" > "$ROOT/cfg-two.json"
run_as() { # pass date
	DESK_CONFIG="$ROOT/cfg-two.json" DESK_NOW="$(day "$2")" TZ=UTC "$DESK_RUN" "$1" > "$ROOT/run.out" 2>&1
}
sessions <<< "$CENTRAL central-x false"
run_as otherpass 2026-10-22
sessions <<< "$CENTRAL central-x true"
before="$(sent_n)"
run_as testpass 2026-10-22
assert_eq "this pass's brief and the other's, two sends" "$((before + 2))" "$(sent_n)"
assert_eq "each its own message" "The otherpass pass of 2026-10-22|The testpass pass of 2026-10-22" \
	"$(jq -rs '.[-2:] | map(.message | split("\n")[0] | sub("^\\[desk-brief\\] "; "") | sub(" is ready.*"; "")) | sort | join("|")' "$BRIEF_TEST_SENT")"
assert_true "the other pass's run is marked sent" "$([ -f "$DESK_RUNS_ROOT/otherpass-2026-10-22/brief.sent" ] && echo true || echo false)"
sessions <<< "$CENTRAL central-x false"
run_as otherpass 2026-10-23
sessions <<< "$CENTRAL central-x true"
before="$(sent_n)"
run_as testpass 2026-10-22
assert_eq "a later slot of a date already run sends the other pass's, with none of its own waiting" "$((before + 1))" "$(sent_n)"
assert_contains "naming that run" "Run directory: $DESK_RUNS_ROOT/otherpass-2026-10-23" "$(jq -rs '.[-1].message' "$BRIEF_TEST_SENT")"

echo
echo "=== a pending run outlives the seven-day sweep; a delivered one does not ==="
# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/lock.sh
source "$LIB/lock.sh"
# shellcheck source=../../claude/desk-lib/model-call.sh
source "$LIB/model-call.sh"
mkdir -p "$DESK_RUNS_ROOT/testpass-2026-09-01/inputs" "$DESK_RUNS_ROOT/testpass-2026-09-02/inputs"
echo '{"unconfirmed_sends": 0}' > "$DESK_RUNS_ROOT/testpass-2026-09-01/brief.pending"
echo '{}' > "$DESK_RUNS_ROOT/testpass-2026-09-02/brief.sent"
desk_prune_old_runs "$(day 2026-10-12)"
assert_true "the pending one stays" "$([ -d "$DESK_RUNS_ROOT/testpass-2026-09-01/inputs" ] && echo true || echo false)"
assert_true "the delivered one goes" "$([ ! -e "$DESK_RUNS_ROOT/testpass-2026-09-02" ] && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
