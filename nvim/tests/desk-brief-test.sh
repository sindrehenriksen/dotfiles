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
# delivery as its own message; notes-changes.txt goes back to the last
# judged run of any pass, says when no kept run was judged or the history
# was rewritten (with the whole diff) or the commit is gone. A step with
# `weekdays` runs only on those days. No live model call.
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
		[ -z "${BRIEF_TEST_WEB_PROMPT:-}" ] || cp prompt.txt "$BRIEF_TEST_WEB_PROMPT"
		emit_use u1 WebSearch '{"query":"news"}'
		emit_text_result u1 'A post: https://example.com/a and more'
		if [ -n "${FAKE_WEB_REPLY:-}" ]; then
			jq -cn --arg t "$FAKE_WEB_REPLY" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
		else
			jq -cn '{type:"assistant",message:{content:[{type:"text",text:({candidates:[{url:"https://example.com/a",summary:"a post"}]} | tojson)}]}}'
		fi
		[ -z "${FAKE_WEB_TRAILER+x}" ] || jq -cn --arg t "$FAKE_WEB_TRAILER" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
		;;
esac
if [ -n "${FAKE_RESULT_TEXT:-}" ]; then
	jq -cn --arg t "$FAKE_RESULT_TEXT" '{type:"result",subtype:"success",total_cost_usd:0.01,result:$t}'
	exit 0
fi
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

echo 'fetch the news {{window_start}} {{window_end}} {{mode}} {{today}}' > "$ROOT/web.md"
export BRIEF_TEST_WEB_PROMPT="$ROOT/web-prompt.txt"
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
assert_eq "the first brief has no run to compare the notes against" "No earlier brief run is kept, so there is nothing to compare the notes against." "$(cat "$R1/notes-changes.txt")"
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
echo "=== notes-changes compares against the last judged run of any pass ==="
printf 'Section A\n  detail\n  a line the user added\n  before the judged run\n' > "$repo/notes.md"
git -C "$repo" commit -q -am "Before the judged run"
jq --arg h "$(git -C "$repo" rev-parse HEAD)" '.notes_head = $h' "$DESK_RUNS_ROOT/otherpass-2026-10-22/run.json" > "$ROOT/rj.json" \
	&& mv -f "$ROOT/rj.json" "$DESK_RUNS_ROOT/otherpass-2026-10-22/run.json"
echo '{"items": []}' > "$DESK_RUNS_ROOT/otherpass-2026-10-22/judgement.json"
printf 'Section A\n  detail\n  a line the user added\n  before the judged run\n  since the judged run\n' > "$repo/notes.md"
git -C "$repo" commit -q -am "Since the judged run"
run_as testpass 2026-10-24
nc="$(cat "$DESK_RUNS_ROOT/testpass-2026-10-24/notes-changes.txt" 2> /dev/null)"
assert_contains "the newest run being unjudged, it goes back to another pass's judged one" "    Since the judged run" "$nc"
assert_true "and no further" "$(! grep -q 'Before the judged run' <<< "$nc" && echo true || echo false)"
echo '{"items": []}' > "$DESK_RUNS_ROOT/testpass-2026-10-24/judgement.json"
git -C "$repo" reset -q --hard HEAD~1
printf 'Section A\n  detail\n  a line the user added\n  before the judged run\n  a different line\n' > "$repo/notes.md"
git -C "$repo" commit -q -am "A rewritten history"
run_as testpass 2026-10-25
nc="$(cat "$DESK_RUNS_ROOT/testpass-2026-10-25/notes-changes.txt" 2> /dev/null)"
assert_contains "a rewritten history is said plainly" "The notes history was rewritten since testpass-2026-10-24" "$nc"
assert_true "with the whole diff, so the lost line shows" \
	"$(grep -q '^-  since the judged run$' <<< "$nc" && grep -q '^+  a different line$' <<< "$nc" && echo true || echo false)"
notes_changes() { # runs root, run name
	bash -c 'source "$1/common.sh"; source "$1/brief.sh"; DESK_RUNS_ROOT="$2"; mkdir -p "$2/$3"
		desk_brief_notes_changes x "$2/$3" "$4" "$(git -C "$4" rev-parse HEAD)" notes.md; cat "$2/$3/notes-changes.txt"' _ "$LIB" "$1" "$2" "$repo"
}
G="$ROOT/runs-gap"
mkdir -p "$G/testpass-2026-11-01" "$G/testpass-2026-11-02"
jq -n --arg h "$(git -C "$repo" rev-parse HEAD~1)" '{notes_head: $h}' > "$G/testpass-2026-11-01/run.json"
jq -n --arg h "$(git -C "$repo" rev-parse HEAD)" '{notes_head: $h}' > "$G/testpass-2026-11-02/run.json"
nc="$(notes_changes "$G" testpass-2026-11-03)"
assert_contains "no kept run judged: the oldest kept stands in, and the file says what that misses" \
	"No kept brief run was judged, so this goes back only to the oldest kept, testpass-2026-11-01" "$nc"
assert_contains "...with the commits since it" "    A rewritten history" "$nc"
echo '{"items": []}' > "$G/testpass-2026-11-02/judgement.json"
jq -n '{notes_head: "0123456789abcdef0123456789abcdef01234567"}' > "$G/testpass-2026-11-02/run.json"
jq -n '{}' > "$G/testpass-2026-11-02/run.json"
assert_eq "a judged run that recorded no commit is said as that" \
	"The last judged brief, testpass-2026-11-02, recorded no notes commit, so there is nothing to compare against." \
	"$(notes_changes "$G" testpass-2026-11-03)"
jq -n '{notes_head: "0123456789abcdef0123456789abcdef01234567"}' > "$G/testpass-2026-11-02/run.json"
assert_eq "a recorded commit now gone is said as that" \
	"The notes commit testpass-2026-11-02 recorded, 0123456789ab, is no longer in the repo, so there is nothing to compare against." \
	"$(notes_changes "$G" testpass-2026-11-03)"

echo
echo "=== edits the review settled because their lines were gone reach the brief ==="
GE="$ROOT/runs-gone"
mkdir -p "$GE/testpass-2026-11-01" "$GE/testpass-2026-11-02"
echo '{}' > "$GE/testpass-2026-11-01/run.json"
echo '{"items": []}' > "$GE/testpass-2026-11-01/judgement.json"
judged_at="$(_now=$(date +%s); echo $((_now - 3600)))"
touch -t "$(date -r "$judged_at" +%Y%m%d%H%M.%S 2> /dev/null || date -d "@$judged_at" +%Y%m%d%H%M.%S)" "$GE/testpass-2026-11-01/judgement.json"
gone="the lines it changes are no longer in your notes"
ge_item() { jq -cn --arg id "$1" --arg f "${2:-notes.md}" '{id: $id, file: $f, kind: "edit", headline: ("h " + $id), source: "https://example.com/a", before: "  old", after: ("  new " + $id)}'; }
{
	jq -cn --arg r "$gone" --argjson i "$(ge_item before)" --argjson at "$((judged_at - 60))" '{type: "decline", id: "before", at: $at, reason: $r, settled: true, item: $i}'
	jq -cn --arg r "$gone" --argjson i "$(ge_item g1)" --argjson at "$((judged_at + 60))" '{type: "decline", id: "g1", at: $at, reason: $r, settled: true, item: $i}'
	jq -cn --arg r "$gone" --argjson i "$(ge_item g2)" --argjson at "$((judged_at + 60))" '{type: "decline", id: "g2", at: $at, reason: $r, settled: true, item: $i}'
	jq -cn --argjson at "$((judged_at + 120))" '{type: "restore", id: "g2", at: $at}'
	jq -cn --argjson i "$(ge_item mine)" --argjson at "$((judged_at + 60))" '{type: "decline", id: "mine", at: $at, item: $i}'
	jq -cn --arg r "$gone" --argjson i "$(ge_item other other.md)" --argjson at "$((judged_at + 60))" '{type: "decline", id: "other", at: $at, reason: $r, settled: true, item: $i}'
} > "$ROOT/ledger.jsonl"
git -C "$repo" update-ref refs/desk/ledger "$(git -C "$repo" hash-object -w "$ROOT/ledger.jsonl")"
bash -c 'source "$1/common.sh"; source "$1/brief.sh"; DESK_RUNS_ROOT="$2"; desk_brief_gone_edits "$2/testpass-2026-11-02" "$3" notes.md reading.md' _ "$LIB" "$GE" "$repo"
assert_eq "only the edits settled as gone since the judged brief, still declined, in the notes' files, with their text" \
	'[{"id":"g1","after":"  new g1"}]' "$(jq -c '[.[] | {id, after}]' "$GE/testpass-2026-11-02/gone-edits.json" 2> /dev/null)"
assert_contains "and the message names the file" ", gone-edits.json." \
	"$(bash -c 'source "$1/common.sh"; source "$1/brief.sh"; echo "{\"scheduled_date\":\"2026-11-02\"}" > "$2/run.json"; echo "{}" > "$2/staged.json"; desk_brief_message testpass "$2"' _ "$LIB" "$GE/testpass-2026-11-02")"
git -C "$repo" update-ref -d refs/desk/ledger

echo
echo "=== a fetch reply is read as JSON however it is wrapped, and one with none fails the source ==="
sessions <<< "$CENTRAL central-x true"
FAKE_WEB_REPLY=$'Here it is:\n```json\n{"candidates": [{"url": "https://example.com/a", "summary": "fenced"}]}\n```' run 2026-10-26
assert_eq "a reply in a code fence is still the step's file" "fenced" \
	"$(jq -r '.candidates[0].summary' "$DESK_RUNS_ROOT/testpass-2026-10-26/inputs/f-web.json" 2> /dev/null)"
FAKE_WEB_TRAILER="" FAKE_RESULT_TEXT='{"candidates": [{"url": "https://example.com/a", "summary": "from the result line"}]}' run 2026-10-28
assert_eq "a final text held by the result line, the last message empty, is still read" "from the result line" \
	"$(jq -r '.candidates[0].summary' "$DESK_RUNS_ROOT/testpass-2026-10-28/inputs/f-web.json" 2> /dev/null)"
FAKE_WEB_REPLY="I read the channels but ran out of room before the JSON." run 2026-10-27
R7="$DESK_RUNS_ROOT/testpass-2026-10-27"
cp "$BRIEF_TEST_WEB_PROMPT" "$ROOT/web-prompt-1027.txt"
assert_eq "a reply holding no JSON fails the source, so the pass reads partial" "partial F-web" \
	"$(jq -r '"\(.passes.testpass.result) \(.passes.testpass.failed_sources | join(","))"' "$DESK_STATUS_FILE" 2> /dev/null)"
assert_true "the run status says so, never ok" "$(grep -q 'its reply was not the JSON the step asks for' "$R7/run-status.txt" && echo true || echo false)"
assert_eq "and the reply is kept in the run directory" "I read the channels but ran out of room before the JSON." "$(cat "$R7/F-web-reply.txt" 2> /dev/null)"
assert_true "run.json records the window the run fetched, for a step rerun" \
	"$(jq -e '.fetch.window_start != null and .fetch.window_end != null and .fetch.mode != null and .fetch.today != null' "$R7/run.json" > /dev/null 2>&1 && echo true || echo false)"

echo
echo "=== a failed fetch is rerun by hand into its run's directory, and only that step runs ==="
rerun_step() { # args after the pass; output to $ROOT/rerun.out
	DESK_NOW="$(day 2026-10-29)" TZ=UTC "$DESK_RUN" testpass "$@" > "$ROOT/rerun.out" 2>&1
}
status_before="$(jq -c '.passes.testpass' "$DESK_STATUS_FILE")"
sent_before="$(sent_n)"
window_before="$(jq -c '.fetch | {window_start, window_end}' "$R7/run.json")"
jq '.failed += ["close"]' "$R7/run.json" > "$ROOT/rj.json" && mv -f "$ROOT/rj.json" "$R7/run.json"
rerun_step --rerun-step close --date 2026-10-27
assert_eq "a step that is not a fetch is refused, even one that failed" "2" "$?"
assert_true "for not being a fetch" "$(grep -q 'this pass has no fetch step close; only a fetch step is rerun' "$ROOT/rerun.out" && echo true || echo false)"
jq '.failed -= ["close"]' "$R7/run.json" > "$ROOT/rj.json" && mv -f "$ROOT/rj.json" "$R7/run.json"
rerun_step --rerun-step F-mon --date 2026-10-27
assert_eq "a fetch that did not fail in that run is refused" "2" "$?"
assert_true "saying why" "$(grep -q 'F-mon did not fail in that run (failed: F-web); only a failed step is rerun' "$ROOT/rerun.out" && echo true || echo false)"
rerun_step --rerun-step F-web --date 2026-10-02
assert_eq "a date with no run directory is refused" "2" "$?"
rerun_step --rerun-step F-web --date yesterday
assert_eq "a date not written YYYY-MM-DD is a usage error" "2" "$?"
FAKE_WEB_REPLY="Still no JSON." rerun_step --rerun-step F-web --date 2026-10-27
assert_eq "a rerun that fails again exits 1" "1" "$?"
assert_true "run-status.txt says it failed again, and why" \
	"$(grep -q '^F-web was rerun by hand at .* and failed again: its call ran, but its reply was not the JSON' "$R7/run-status.txt" && echo true || echo false)"
assert_eq "it is still failed in run.json" '["F-web"]' "$(jq -c '.failed' "$R7/run.json")"
# A mode and date other than the ones a run on the rerun's own day would
# get, so the prompt shows whether the recorded ones were used.
jq '.fetch.mode = "RECORDED-MODE" | .fetch.today = "2026-10-27"' "$R7/run.json" > "$ROOT/rj.json" && mv -f "$ROOT/rj.json" "$R7/run.json"
rerun_step --rerun-step F-web --date 2026-10-27
assert_eq "a rerun that succeeds exits 0" "0" "$?"
assert_eq "it fetched the run's own window, not one ending at the rerun" \
	"$(awk 'NR == 1 {print $4, $5}' "$ROOT/web-prompt-1027.txt")" "$(awk 'NR == 1 {print $4, $5}' "$BRIEF_TEST_WEB_PROMPT")"
assert_eq "with the mode and date the run recorded" "RECORDED-MODE 2026-10-27" "$(awk 'NR == 1 {print $6, $7}' "$BRIEF_TEST_WEB_PROMPT")"
assert_eq "only that step ran: one model call, F-web's" "F-web" "$(sed -n 's/.*model call: \([^ ]*\)$/\1/p' "$ROOT/rerun.out" | paste -sd, -)"
assert_eq "its reply is the run's input now" "https://example.com/a" "$(jq -r '.candidates[0].url' "$R7/inputs/f-web.json" 2> /dev/null)"
assert_true "its links are allowed" "$(grep -qxF 'https://example.com/a' "$R7/allowed-urls.txt" && echo true || echo false)"
assert_true "the failed reply kept from before is gone" "$([ ! -e "$R7/F-web-reply.txt" ] && echo true || echo false)"
assert_eq "run.json: nothing failed any more, so the partial run reads ok, and the tries are recorded" 'ok [] ["failed","ok"]' \
	"$(jq -r '"\(.result) \(.failed | tojson) \([.reruns[].result] | tojson)"' "$R7/run.json")"
assert_eq "the window recorded is the one it fetched, unchanged" "$window_before" "$(jq -c '.fetch | {window_start, window_end}' "$R7/run.json")"
assert_true "run-status.txt says it succeeded and what it brought" \
	"$(grep -q '^F-web was rerun by hand at .* and succeeded: what it fetched is now in inputs/ (f-web.json).$' "$R7/run-status.txt" && echo true || echo false)"
assert_eq "nothing was sent" "$sent_before" "$(sent_n)"
assert_eq "and the status file keeps the run's own record: no run of the pass, no window moved" "$status_before" "$(jq -c '.passes.testpass' "$DESK_STATUS_FILE")"
rerun_step --rerun-step F-web --date 2026-10-27
assert_eq "once it succeeded, it is not rerun again" "2" "$?"

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
