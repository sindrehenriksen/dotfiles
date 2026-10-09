#!/usr/bin/env bash
# The follow pass (claude/desk-lib/follow.sh, claude/desk-follow): the follow
# list CLI, the interval floor, a baseline run, a run that forwards changes
# to a live session, a queue held for a session that is not running and
# delivered whole once it is, the send pinned to the resolved name (a send
# to any other name is refused by the deny hook), the dry run, and the
# seam for retiring a follow whose tickets are all closed, and a ticket
# another followed session owns going only to that session, and a line on
# a ticket another followed session also has naming that session.
# Offline: `claude`, `gh` and the reader are fakes; the fake `claude` runs
# the deny hook from the settings file the runner hands it, the way Claude
# Code would. No git repo is touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$REPO_ROOT/claude/desk-lib"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}
assert_contains() {
	local desc=$1 needle=$2 hay=$3
	case "$hay" in *"$needle"*) ok "$desc" ;; *) bad "$desc (no [$needle] in [${hay:0:600}])" ;; esac
}
assert_not_contains() {
	local desc=$1 needle=$2 hay=$3
	case "$hay" in *"$needle"*) bad "$desc (found [$needle])" ;; *) ok "$desc" ;; esac
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

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
export CLAUDE_SESSION_READER_CACHE="$ROOT/reader-cache"
export DESK_FOLLOW_FILE="$STATE/follow.json"
export DESK_FOLLOW_STATE_FILE="$STATE/follow-state.json"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_SESSION_STORE"
unset CLAUDE_CODE_SESSION_ID

FIX="$ROOT/fix"
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FIX" "$FAKEBIN"
CALLS="$ROOT/calls.log"
: > "$CALLS"

SID_A="aaaaaaaa-1111-4111-8111-111111111111"
SID_B="bbbbbbbb-2222-4222-8222-222222222222"
SID_OTHER="cccccccc-3333-4333-8333-333333333333"

# --- fakes --------------------------------------------------------------------

# The reader: every session, or `resolve <token>` by id, unique name or
# 8+ character id prefix, from $FIX/sessions.jsonl.
cat > "$FAKEBIN/session-status.sh" << FAKE
#!/usr/bin/env bash
f="$FIX/sessions.jsonl"
[ -f "\$f" ] || exit 0
if [ "\${1:-}" = resolve ]; then
	hits="\$(jq -cs --arg t "\$2" '[.[] | select(.id == \$t or .name == \$t or ((\$t | length) >= 8 and (.id | startswith(\$t))))]' "\$f")"
	[ "\$(jq length <<< "\$hits")" = 1 ] || { printf '%s\n' "\$hits"; exit 1; }
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
			'{id:$id, name:$n, live:$l, status:(if $l then "idle" else "ended" end), duplicate_pids:false}' >> "$FIX/sessions.jsonl"
	done
}

# claude: the ticket fetch replies with $FIX/scope-result.json and
# $FIX/changes-result.json for the queries its prompt names; the send runs
# the PreToolUse hook from --settings on its tool input and reports a denial
# as an error result. FAKE_SEND_TO sends somewhere other than the pinned name.
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
emit_result() { jq -cn --arg id "$1" --arg t "$2" --argjson e "$3" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:$t,is_error:$e}]}}'; }
# A tool's own result, as Claude Code writes it: one text block.
emit_text_result() { jq -cn --arg id "$1" --arg t "$2" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:$t}]}]}}'; }
# What SendMessage answers for a peer session it delivered to (Claude Code
# 2.1.294, captured live): the message's first line quoted, the recipient,
# then boilerplate naming what may still happen to it.
delivered() {
	jq -cn --arg to "$1" --arg first "$2" '{success:true,
		message:("“" + $first + "” → " + $to + " (another Claude session on this machine; in that session'"'"'s inbox, not yet read by its Claude — that session may hold it (usually a different permission mode) or refuse it, and with no inbox bound here nothing reports back, so never treat silence as agreement)"),
		msg_id:"1d4d98b4-96d5-475f-81ab-1c910d2da2e6"}'
}
if [ "$tools" = "SendMessage" ]; then
	echo "send $(pwd)" >> "$FOLLOW_TEST_CALLS"
	input="$(jq -c '.[0]' pinned-args.json)"
	[ -n "${FAKE_SEND_TO:-}" ] && input="$(jq -c --arg to "$FAKE_SEND_TO" '.to = $to' <<< "$input")"
	# What Claude Code hands a PreToolUse hook for SendMessage: the model's
	# to/message/summary plus fields it fills in itself.
	input="$(jq -c '. + {summary: "follow update", recipient: .to, recipient_kind: "name", type: "message", content: (.message[0:50] + "…")}' <<< "$input")"
	printf '%s\n' "$input" >> "$FOLLOW_TEST_SENT"
	cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")"
	emit_use t1 SendMessage "$input"
	if jq -cn --argjson i "$input" '{tool_name:"SendMessage", tool_input:$i}' | bash -c "$cmd" > /dev/null 2>&1; then
		if [ -n "${FAKE_SEND_RESULT:-}" ]; then
			emit_text_result t1 "$FAKE_SEND_RESULT"
		else
			emit_text_result t1 "$(delivered "$(jq -r .to <<< "$input")" "$(jq -r '.message | split("\n")[0]' <<< "$input")")"
		fi
	else
		emit_result t1 "PreToolUse hook denied this call" true
	fi
	echo '{"type":"result","subtype":"success","total_cost_usd":0.02}'
	exit 0
fi
echo "fetch" >> "$FOLLOW_TEST_CALLS"
cp prompt.txt "$FOLLOW_TEST_LAST_PROMPT"
scope="$(sed -n 's/^SCOPE: //p' prompt.txt)"
changes="$(sed -n 's/^CHANGES: //p' prompt.txt)"
if [ "$scope" != none ]; then
	emit_use s1 mcp__tickets__search "$(jq -cn --arg q "$scope" '{jql:$q}')"
	emit_result s1 "$(cat "$FOLLOW_TEST_FIX/scope-result.json")" false
fi
if [ "$changes" != none ] && [ -z "${FAKE_JIRA_FAIL:-}" ]; then
	emit_use c1 mcp__tickets__search "$(jq -cn --arg q "$changes" '{jql:$q}')"
	emit_result c1 "$(cat "$FOLLOW_TEST_FIX/changes-result.json")" false
fi
echo '{"type":"result","subtype":"success","total_cost_usd":0.01}'
FAKE
chmod +x "$FAKEBIN/claude"
export FOLLOW_TEST_CALLS="$CALLS" FOLLOW_TEST_FIX="$FIX" FOLLOW_TEST_SENT="$ROOT/sent.jsonl" FOLLOW_TEST_LAST_PROMPT="$ROOT/last-prompt.txt"
: > "$FOLLOW_TEST_SENT"
export DESK_CLAUDE_BIN="$FAKEBIN/claude"

# gh: `pr list` replies $FIX/prs.json, `pr view N` replies $FIX/pr-N.json.
cat > "$FAKEBIN/gh" << FAKE
#!/usr/bin/env bash
echo "gh \$*" >> "$CALLS"
case "\$1 \$2" in
	"pr list") cat "$FIX/prs.json" ;;
	"pr view") cat "$FIX/pr-\$3.json" 2> /dev/null || echo '{"comments":[],"reviews":[]}' ;;
	*) exit 9 ;;
esac
FAKE
chmod +x "$FAKEBIN/gh"
export DESK_GH_BIN="$FAKEBIN/gh"

# --- instance -------------------------------------------------------------------

INST="$ROOT/instance"
mkdir -p "$INST/prompts"
printf 'SCOPE: {{scope_jql}}\nCHANGES: {{changes_jql}}\nFIELDS: {{changes_fields}}\n' > "$INST/prompts/follow-fetch.md"
printf 'Send to {{to}}:\n{{message}}\n' > "$INST/prompts/follow-send.md"
printf 'STANDING PREAMBLE: end with [needs-you] only when the bar is met.\n' > "$INST/prompts/follow-preamble.md"
write_config() { # interval
	jq -n --argjson iv "${1:-15}" '{
		timezone: "UTC", ticket_search_tool: "x", mail_search_tool: "x", ticket_status_step_id: "x", mail_fetch_step_id: "x",
		notes_repo: "/nonexistent", files: ["notes.md"],
		passes: {follow: {kind: "follow", interval_minutes: $iv,
			jira: {prompt: "prompts/follow-fetch.md", tool: "mcp__tickets__search"},
			github_repos: ["org/repo"],
			send: {prompt: "prompts/follow-send.md"},
			skip: {bot_authors: ["^github-actions", "^Automation", "\\[bot\\]$"], bot_signatures: ["^🤖 Review Bot"]},
			preamble: "prompts/follow-preamble.md"}}}' > "$INST/config.json"
}
write_config 15
export DESK_CONFIG="$INST/config.json"

# Jira fixtures, in the REST issue shape the search tool returns.
issue() { # key status [parent] [links-json] [comments-json] [updated] [summary]
	jq -cn --arg k "$1" --arg s "$2" --arg p "${3:-}" --argjson l "${4:-[]}" --argjson c "${5:-null}" \
		--arg u "${6:-2026-10-07T09:00:00.000+0300}" --arg sum "${7:-Summary of $1}" '
		{key:$k, fields:({summary:$sum, status:{name:$s, statusCategory:{key:(if $s == "Done" then "done" else "indeterminate" end)}},
		  issuetype:{name:"Task"}, assignee:{displayName:"Dev One"}, labels:[], resolution:null,
		  parent:(if $p == "" then null else {key:$p} end), issuelinks:$l, updated:$u, created:"2026-09-01T10:00:00.000+0300"}
		  + (if $c == null then {} else {comment:{comments:$c}, description:"AC: keep the retry flag."} end))}'
}
cmt() { # id author body [created]
	jq -cn --arg id "$1" --arg a "$2" --arg b "$3" --arg t "${4:-$future}" '{id:$id, author:{displayName:$a}, created:$t, updated:$t, body:$b}'
}
with_assignee() { jq -c --arg a "$1" '.fields.assignee.displayName = $a'; }
link() { jq -cn --arg k "$1" '{type:{inward:"relates to",outward:"relates to"}, outwardIssue:{key:$k, fields:{summary:"linked", status:{name:"To Do"}}}}'; }
headless() { jq -cs '{issues:{nodes:.}}'; }
rest() { jq -cs '{issues:., isLast:true}'; }

prs_none() { echo '[]' > "$FIX/prs.json"; }
pr() { # number title branch state head [checks]
	jq -cn --argjson n "$1" --arg t "$2" --arg b "$3" --arg s "$4" --arg h "$5" --argjson c "${6:-[]}" '
		{number:$n, title:$t, headRefName:$b, state:$s, isDraft:false, updatedAt:"2026-10-07T08:00:00Z", createdAt:"2026-10-01T08:00:00Z",
		 reviewDecision:"", headRefOid:$h, labels:[], url:("https://example.test/pr/\($n)"), body:"PR body", statusCheckRollup:$c}'
}

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
for f in lock model-call timeout tool-results steps follow; do
	# shellcheck disable=SC1090
	source "$LIB/$f.sh"
done
export PATH="$FAKEBIN:$PATH"
CLI="$REPO_ROOT/claude/desk-follow"
RUN="$REPO_ROOT/claude/desk-run"

echo "=== the follow list CLI ==="
sessions << EOF
$SID_A alpha-session true
$SID_B beta-session true
$SID_OTHER some-other-session true
EOF
out="$("$CLI" add ABC-1 2>&1)"; rc=$?
assert_eq "add without a session or \$CLAUDE_CODE_SESSION_ID refuses" "2" "$rc"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" "$CLI" add abc-1 ABC-2 --related XYZ-9)"
assert_contains "add from inside a session uses its id and the current name as label" "following ABC-1, ABC-2, XYZ-9 for alpha-session" "$out"
out="$("$CLI" add --session beta-session --label "Beta work" DEF-5)"
assert_contains "add resolves a session name to its id" "for Beta work" "$out"
assert_eq "the entry is keyed by session id" "$SID_B" "$(jq -r '.entries | to_entries[] | select(.value.label == "Beta work") | .key' "$DESK_FOLLOW_FILE")"
out="$("$CLI" add --session "$SID_A" not-a-key 2>&1)"; rc=$?
assert_eq "a non-key is refused" "2" "$rc"
"$CLI" add --session "$SID_B" DEF-6 > /dev/null
assert_eq "add to an existing follow merges keys" '["DEF-5","DEF-6"]' "$(jq -c --arg s "$SID_B" '.entries[$s].keys' "$DESK_FOLLOW_FILE")"
out="$("$CLI" remove --session "$SID_B" DEF-6)"
assert_contains "remove with keys drops only those" "still following DEF-5" "$out"
out="$("$CLI" list)"
assert_contains "list names each follow with its liveness" "alpha-session  (aaaaaaaa, live)" "$out"
assert_contains "list shows tracked and related keys" "tracks: ABC-1, ABC-2; related: XYZ-9" "$out"
assert_eq "list --json is the machine-readable seam" "2" "$("$CLI" list --json | jq length)"
# A missing option value is a usage error, never a loop: the alarm kills a
# hung call, which then exits 142 instead of 2.
for args in "add --label" "add --session" "run --lookback-minutes"; do
	# shellcheck disable=SC2086
	CLAUDE_CODE_SESSION_ID="$SID_A" perl -e 'alarm 5; exec @ARGV' "$CLI" $args > /dev/null 2>&1; rc=$?
	assert_eq "desk-follow $args with no value is a usage error" "2" "$rc"
done
perl -e 'alarm 5; exec @ARGV' "$RUN" follow --lookback-minutes > /dev/null 2>&1; rc=$?
assert_eq "desk-run follow --lookback-minutes with no value is refused" "2" "$rc"

echo
echo "=== the interval floor ==="
write_config 5
log="$(desk_follow_interval_minutes "$(jq -c .passes.follow "$DESK_CONFIG")" follow 2>&1 > /dev/null)"
assert_eq "an interval under 15 minutes is clamped to 15" "15" "$(desk_follow_interval_minutes "$(jq -c .passes.follow "$DESK_CONFIG")" follow 2> /dev/null)"
assert_contains "and the clamp is logged" "interval_minutes 5 is under the 15-minute floor; using 15" "$log"
write_config 30
assert_eq "an interval above the floor is kept" "30" "$(desk_follow_interval_minutes "$(jq -c .passes.follow "$DESK_CONFIG")" follow 2> /dev/null)"
write_config
assert_eq "no interval: the 15-minute default" "15" "$(desk_follow_interval_minutes '{}' follow 2> /dev/null)"

echo
echo "=== a baseline run records snapshots and sends nothing ==="
{
	issue ABC-1 "In Progress" "" "[$(link LNK-7)]"
	issue ABC-11 "To Do" ABC-1
	issue ABC-2 "To Do"
	issue XYZ-9 "To Do"
	issue DEF-5 "To Do"
} | headless > "$FIX/scope-result.json"
echo '{"issues":{"nodes":[]}}' > "$FIX/changes-result.json"
pr 40 "[ABC-11] Build the thing" "abc-11-build" OPEN h1 '[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"}]' | jq -s . > "$FIX/prs.json"
: > "$CALLS"
"$RUN" follow > "$ROOT/run1.out" 2>&1
assert_eq "the baseline run succeeds" "0" "$?"
assert_eq "one ticket fetch, no send" "fetch" "$(grep -v '^gh' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "the baseline asks only the scope query" "CHANGES: none" "$(cat "$FOLLOW_TEST_LAST_PROMPT")"
assert_contains "the scope query covers tracked keys and children" "SCOPE: key in (ABC-1, ABC-2, DEF-5, XYZ-9) OR parent in (ABC-1, ABC-2, DEF-5)" "$(cat "$FOLLOW_TEST_LAST_PROMPT")"
assert_eq "a child is in scope" "true" "$(jq --arg s "$SID_A" '.queues[$s].scope | index("ABC-11") != null' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "a linked ticket is in scope" "true" "$(jq --arg s "$SID_A" '.queues[$s].scope | index("LNK-7") != null' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "nothing is queued" "0" "$(jq '[.queues[].changes[]] | length' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "the PR is snapshotted" "h1" "$(jq -r '.prs["org/repo#40"].head' "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== the next run forwards what is substantive to the live session ==="
# Pretend the last run was a while ago, past the scheduled interval.
jq '.last_run.at -= 3600 | .last_jira_ok -= 3600 | .last_gh_ok -= 3600 | .scope.refreshed_at -= 600' "$DESK_FOLLOW_STATE_FILE" > "$ROOT/s" && mv "$ROOT/s" "$DESK_FOLLOW_STATE_FILE"
future="$(date -u -v+1H +%Y-%m-%dT%H:%M:%S.000+0000 2> /dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%S.000+0000)"
{
	issue ABC-11 "Done" ABC-1 "[]" "[{\"id\":\"901\",\"author\":{\"displayName\":\"Dev One\"},\"created\":\"$future\",\"updated\":\"$future\",\"body\":\"Merged; steps 2-4 not checked yet.<!-- bot-meta {\\\"channel\\\":\\\"C0X\\\"} -->\"}]"
	issue LNK-7 "In Progress"
	issue OTH-3 "To Do" "" "[]" "[$(cmt 905 "Dev Two" "This depends on ABC-2 landing first.")]" "" "Another team's ticket"
	issue ABC-2 "To Do" "" "[]" "[$(cmt 906 "Automation" "Moved by rule")]"
} | rest > "$FIX/changes-result.json"
pr 40 "[ABC-11] Build the thing" "abc-11-build" MERGED h2 '[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"evals","status":"COMPLETED","conclusion":"FAILURE"}]' \
	| jq -s '.[0].updatedAt = "2026-10-07T09:00:00Z"' > "$FIX/prs.json"
jq -n --arg t "$future" '{comments:[
		{id:"IC_1",author:{login:"dev1"},createdAt:$t,body:"Dropped the retry flag."},
		{id:"IC_2",author:{login:"github-actions"},createdAt:$t,body:"Slack announcement: thread link"},
		{id:"IC_3",author:{login:"dev2"},createdAt:$t,body:"FYI the bot said:\n🤖 Review Bot: looks fine"}],
	reviews:[{id:"R_1",author:{login:"dev1"},submittedAt:$t,state:"COMMENTED",body:"🤖 Review Bot — automated review. Summary: fine."}]}' > "$FIX/pr-40.json"
: > "$CALLS"
: > "$FOLLOW_TEST_SENT"
"$RUN" follow --scheduled > "$ROOT/run2.out" 2>&1
assert_eq "the run succeeds" "0" "$?"
assert_contains "the changes query asks for scope, children and mentions in the window" 'text ~ "\"ABC-1\""' "$(cat "$FOLLOW_TEST_LAST_PROMPT")"
assert_contains "and bounds it by relative minutes" "AND updated >= -" "$(cat "$FOLLOW_TEST_LAST_PROMPT")"
assert_eq "one send, to alpha's current name" "alpha-session" "$(jq -r '.to' "$FOLLOW_TEST_SENT" | head -n1)"
msg="$(jq -r 'select(.to == "alpha-session") | .message' "$FOLLOW_TEST_SENT")"
assert_eq "the message starts with the marker" "[desk-follow] Update for alpha-session" "$(head -n1 <<< "$msg" | cut -d: -f1)"
assert_contains "the preamble rides along" "STANDING PREAMBLE" "$msg"
assert_not_contains "a child's status-only move is not listed" "status To Do → Done" "$msg"
assert_contains "a new comment is forwarded" 'new comment by Dev One: "Merged; steps 2-4 not checked yet."' "$msg"
assert_contains "a linked ticket's rename is forwarded, its status move with it" 'LNK-7 "Summary of LNK-7" (linked to ABC-1): status To Do → In Progress; renamed from "linked"' "$msg"
assert_not_contains "a bot's hidden HTML comment is left out" "bot-meta" "$msg"
assert_contains "a comment on a ticket that mentions a tracked key is forwarded" '(mentions ABC-2): new comment by Dev Two: "This depends on ABC-2 landing first."' "$msg"
assert_not_contains "that ticket's first sighting is not listed" "new under the follow" "$msg"
assert_contains "a PR on a child's key is forwarded, with its new state and commits" "PR #40" "$msg"
assert_contains "the failing check is named" "1 failed (evals)" "$msg"
assert_contains "a new PR comment is forwarded" 'comment by dev1: "Dropped the retry flag."' "$msg"
assert_not_contains "a bot account's comment is not" "Slack announcement" "$msg"
assert_not_contains "a review opening with a bot's signature is not" "automated review" "$msg"
assert_contains "a person pasting bot output is" 'comment by dev2: "FYI the bot said: 🤖 Review Bot: looks fine"' "$msg"
assert_contains "the footer counts the status move" "1 status move" "$msg"
assert_contains "the bot comments" "2 bot comments" "$msg"
assert_contains "the bot review" "1 bot review" "$msg"
assert_contains "and the first-seen ticket" "1 first-seen ticket" "$msg"
assert_eq "the footer is the message's last line" "Skipped since the last update, not listed" "$(tail -n1 <<< "$msg" | cut -d: -f1)"
assert_eq "beta has nothing that moved, so no message" "0" "$(jq -c 'select(.to == "beta-session")' "$FOLLOW_TEST_SENT" | wc -l | tr -d ' ')"
assert_eq "the queue is emptied on a confirmed send" "0" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "last seen advances" "alpha-session" "$(jq -r --arg s "$SID_A" '.last_sent[$s].name' "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== a scheduled run inside the interval does nothing; a manual one runs ==="
: > "$CALLS"
"$RUN" follow --scheduled > /dev/null 2>&1
assert_eq "scheduled, just after a run: no fetch" "" "$(cat "$CALLS")"
"$RUN" follow > /dev/null 2>&1
assert_contains "manual: it runs" "fetch" "$(cat "$CALLS")"

echo
echo "=== a session that is not running keeps its queue, and gets it all at once ==="
sessions << EOF
$SID_A alpha-session false
$SID_B beta-session true
EOF
issue ABC-2 "To Do" | with_assignee "Dev Two" | rest > "$FIX/changes-result.json"
prs_none
: > "$FOLLOW_TEST_SENT"
"$RUN" follow > /dev/null 2>&1
assert_eq "nothing is sent to a session that is not running" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_eq "its change waits in the queue" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
issue ABC-2 "To Do" | with_assignee "Dev Three" | rest > "$FIX/changes-result.json"
"$RUN" follow > /dev/null 2>&1
assert_eq "a second change queues behind it" "2" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
sessions << EOF
$SID_A alpha-renamed true
$SID_B beta-session true
EOF
echo '{"issues":[], "isLast": true}' > "$FIX/changes-result.json"
"$RUN" follow > /dev/null 2>&1
assert_eq "once live: one message, to its new name" "alpha-renamed" "$(jq -r .to "$FOLLOW_TEST_SENT" | tr '\n' ' ' | sed 's/ $//')"
msg="$(jq -r .message "$FOLLOW_TEST_SENT")"
assert_contains "it carries the first queued change" "assignee Dev One → Dev Two" "$msg"
assert_contains "and the second" "assignee Dev Two → Dev Three" "$msg"
assert_contains "it says when the last update went out" "Changes since " "$msg"
assert_eq "and the queue is empty afterwards" "0" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== a name that does not address the session alone holds the queue ==="
issue ABC-2 "To Do" | with_assignee "Dev Four" | rest > "$FIX/changes-result.json"
sessions << EOF
$SID_A alpha-renamed true
$SID_OTHER alpha-renamed true
$SID_B beta-session true
EOF
: > "$FOLLOW_TEST_SENT"
"$RUN" follow > "$ROOT/dup.out" 2>&1
assert_eq "no send when two sessions share the name" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_contains "and it says why" "does not address this session alone" "$(cat "$ROOT/dup.out")"

echo
echo "=== the send is pinned to the resolved name ==="
sessions << EOF
$SID_A alpha-renamed true
$SID_B beta-session true
$SID_OTHER some-other-session true
EOF
: > "$FOLLOW_TEST_SENT"
FAKE_SEND_TO=some-other-session "$RUN" follow > /dev/null 2>&1
assert_eq "the model tried another peer" "some-other-session" "$(jq -r .to "$FOLLOW_TEST_SENT")"
assert_eq "the deny hook refused it, so the queue stays" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "a send that never ran backs off" "true" "$(jq --arg s "$SID_A" '.queues[$s].retry_at > .last_run.at' "$DESK_FOLLOW_STATE_FILE")"
FAKE_SEND_RESULT='{"success":false,"message":"No agent named alpha-renamed is reachable."}' "$RUN" follow > "$ROOT/unreach.out" 2>&1
assert_eq "an unreachable name is not a confirmed send" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
assert_contains "the log says it failed and when it tries next" "the send to alpha-renamed failed — 1 change(s) stay queued, next try at" "$(cat "$ROOT/unreach.out")"
assert_eq "a second failure doubles the wait" "true" "$(jq --arg s "$SID_A" '.queues[$s].failed_sends == 2 and (.queues[$s].retry_at - .last_run.at) == (30 * 60 - 60)' "$DESK_FOLLOW_STATE_FILE")"
jq '.last_run.at -= 3600' "$DESK_FOLLOW_STATE_FILE" > "$ROOT/s" && mv "$ROOT/s" "$DESK_FOLLOW_STATE_FILE"
: > "$FOLLOW_TEST_SENT"
"$RUN" follow --scheduled > "$ROOT/backoff.out" 2>&1
assert_eq "a scheduled run inside the back-off sends nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_contains "and says until when" "the last send failed — 1 change(s) stay queued until the next try at" "$(cat "$ROOT/backoff.out")"

echo
echo "=== a send that runs but never confirms is not repeated forever ==="
held_result='{"success":true,"message":"“[desk-follow] …” → alpha-renamed (another Claude session on this machine; the message was held for that session'"'"'s approval)","msg_id":"m1"}'
FAKE_SEND_RESULT="$held_result" "$RUN" follow > "$ROOT/held1.out" 2>&1
assert_eq "a held delivery is not a confirmed send" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
assert_contains "the log says it ran unconfirmed, with the result" "ran but was not confirmed — 1 change(s) stay queued for one more try (result: {\"success\":true" "$(cat "$ROOT/held1.out")"
assert_eq "a send that ran clears the back-off" "false" "$(jq --arg s "$SID_A" '.queues[$s] | has("retry_at")' "$DESK_FOLLOW_STATE_FILE")"
: > "$FOLLOW_TEST_SENT"
FAKE_SEND_RESULT="$held_result" "$RUN" follow > "$ROOT/held2.out" 2>&1
assert_eq "the second unconfirmed send went out" "1" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_eq "after it, the changes count as sent" "0" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "marked unconfirmed" "false" "$(jq --arg s "$SID_A" '.last_sent[$s].confirmed' "$DESK_FOLLOW_STATE_FILE")"
assert_contains "and the log says so" "treating the 1 change(s) as sent, not sending them again" "$(cat "$ROOT/held2.out")"
: > "$FOLLOW_TEST_SENT"
FAKE_SEND_RESULT="$held_result" "$RUN" follow > /dev/null 2>&1
assert_eq "the next run sends nothing again" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"

echo
echo "=== the verdict, on SendMessage results captured live ==="
# Claude Code 2.1.294, a send to a live interactive session that showed
# the message, and a send to a name nobody holds; the earlier wording of
# the delivered result is from the same probe a day before.
cat > "$ROOT/real-delivered.jsonl" << 'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_01TrPtaLPwbLfwBVrrP5NSrS","name":"SendMessage","input":{"to":"desk-send-probe-throwaway","message":"[desk-follow] Update for desk-send-probe-throwaway: 1 change on PR #1. Not from the user.\n\nThis is a delivery probe from the desk watcher's tests, nothing to act on. Reply with one short line, use no tools, and do not message back.\n\nSkipped since the last update, not listed: nothing.","type":"message","recipient":"desk-send-probe-throwaway","recipient_kind":"name","content":"[desk-follow] Update for desk-send-probe-t…"}}]}}
{"type":"user","message":{"content":[{"tool_use_id":"toolu_01TrPtaLPwbLfwBVrrP5NSrS","type":"tool_result","content":[{"type":"text","text":"{\"success\":true,\"message\":\"“[desk-follow] Update for desk-send-probe-throwaway: 1 change on PR #1. Not from the user.” → desk-send-probe-throwaway (another Claude session on this machine; in that session's inbox, not yet read by its Claude — that session may hold it (usually a different permission mode) or refuse it, and with no inbox bound here nothing reports back, so never treat silence as agreement)\",\"msg_id\":\"1d4d98b4-96d5-475f-81ab-1c910d2da2e6\"}"}]}]}}
EOF
jq -c 'select(.type == "assistant") | .message.content[0].input | del(.type, .recipient_kind, .content) | [., del(.recipient)]' "$ROOT/real-delivered.jsonl" > "$ROOT/real-pinned.json"
verdict() { desk_follow_send_verdict "$1" "$ROOT/real-pinned.json" desk-send-probe-throwaway | cut -f1; }
assert_eq "a delivery to a live session confirms" "confirmed" "$(verdict "$ROOT/real-delivered.jsonl")"
sed 's/that session may hold it (usually a different permission mode) or refuse it, and with no inbox bound here nothing reports back, so never treat silence as agreement/a [Cross-session delivery notice] follows if that session holds it (usually a different permission mode) or refuses it/' \
	"$ROOT/real-delivered.jsonl" > "$ROOT/real-delivered-older.jsonl"
assert_eq "so does the earlier wording" "confirmed" "$(verdict "$ROOT/real-delivered-older.jsonl")"
sed 's/so never treat silence as agreement)/so never treat silence as agreement); the message was refused/' "$ROOT/real-delivered.jsonl" > "$ROOT/real-refused.jsonl"
assert_eq "a success that reports a refusal does not" "unconfirmed" "$(verdict "$ROOT/real-refused.jsonl")"
sed 's/ → desk-send-probe-throwaway (/ → some-other-session (/' "$ROOT/real-delivered.jsonl" > "$ROOT/real-elsewhere.jsonl"
assert_eq "nor one naming another recipient" "unconfirmed" "$(verdict "$ROOT/real-elsewhere.jsonl")"
{
	head -n1 "$ROOT/real-delivered.jsonl"
	cat << 'EOF'
{"type":"user","message":{"content":[{"tool_use_id":"toolu_01TrPtaLPwbLfwBVrrP5NSrS","type":"tool_result","content":[{"type":"text","text":"{\"success\":false,\"message\":\"No agent named 'desk-send-probe-throwaway' is reachable.\\nCheck the spelling, or use the agent ID from a background agent's spawn result.\"}"}]}]}}
EOF
} > "$ROOT/real-unreachable.jsonl"
assert_eq "an unreachable name fails" "failed" "$(verdict "$ROOT/real-unreachable.jsonl")"
head -n1 "$ROOT/real-delivered.jsonl" > "$ROOT/real-no-result.jsonl"
assert_eq "a call with no result fails" "failed" "$(verdict "$ROOT/real-no-result.jsonl")"
assert_contains "the verdict carries the result for the log" "No agent named" "$(desk_follow_send_verdict "$ROOT/real-unreachable.jsonl" "$ROOT/real-pinned.json" desk-send-probe-throwaway | cut -f2)"

# The hook itself, on the settings the runner writes.
hook="$LIB/deny-unlisted-tool.sh"
printf '[{"to":"alpha-renamed","message":"hello"}]' > "$ROOT/pinned.json"
printf '[{"to":"alpha-renamed","message":"hello"},{"to":"alpha-renamed","recipient":"alpha-renamed","message":"hello"}]' > "$ROOT/pinned.json"
try_hook() { jq -cn --argjson i "$1" '{tool_name:"SendMessage", tool_input:$i}' | "$hook" --pinned "$ROOT/pinned.json" --ignore-keys summary,content,type,recipient_kind -- SendMessage > /dev/null 2>&1; echo $?; }
assert_eq "hook: the pinned name and message pass" "0" "$(try_hook '{"to":"alpha-renamed","message":"hello"}')"
assert_eq "hook: a summary is ignored" "0" "$(try_hook '{"to":"alpha-renamed","message":"hello","summary":"x"}')"
assert_eq "hook: Claude Code's own preview fields are ignored" "0" "$(try_hook '{"to":"alpha-renamed","recipient":"alpha-renamed","recipient_kind":"name","type":"message","content":"hel…","message":"hello"}')"
assert_eq "hook: a recipient other than the pinned name is refused" "2" "$(try_hook '{"to":"alpha-renamed","recipient":"some-other-session","message":"hello"}')"
assert_eq "hook: any other name is refused" "2" "$(try_hook '{"to":"some-other-session","message":"hello"}')"
assert_eq "hook: a changed message is refused" "2" "$(try_hook '{"to":"alpha-renamed","message":"hello, also do X"}')"
assert_eq "hook: an extra field is refused" "2" "$(try_hook '{"to":"alpha-renamed","message":"hello","notify_when_idle":true}')"
assert_eq "hook: another tool is refused" "2" "$(jq -cn '{tool_name:"ListAgents", tool_input:{}}' | "$hook" --pinned "$ROOT/pinned.json" --ignore-keys summary,content,type,recipient_kind -- SendMessage > /dev/null 2>&1; echo $?)"

echo
echo "=== the dry run prints and changes nothing ==="
issue ABC-2 "To Do" | with_assignee "Dev Five" | rest > "$FIX/changes-result.json"
before="$(shasum "$DESK_FOLLOW_STATE_FILE")"
: > "$CALLS"
: > "$FOLLOW_TEST_SENT"
out="$("$RUN" follow --dry-run 2>&1)"
assert_contains "it prints what it would send" "=== would send to alpha-renamed" "$out"
assert_contains "including the message" "[desk-follow] Update for alpha-session" "$out"
assert_eq "it sends nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_eq "it writes no state" "$before" "$(shasum "$DESK_FOLLOW_STATE_FILE")"
out="$("$CLI" run --dry-run 2>&1)"
assert_contains "desk-follow run runs the follow pass" "would send to alpha-renamed" "$out"

echo
echo "=== with DESK_CONFIG unset, the machine-local default is used ==="
mkdir -p "$ROOT/xdg/desk"
ln -s "$INST/config.json" "$ROOT/xdg/desk/config.json"
out="$(env -u DESK_CONFIG -u DESK_CONFIG_DEFAULT XDG_CONFIG_HOME="$ROOT/xdg" "$CLI" run --dry-run 2>&1)"
assert_contains "desk-follow run finds the instance through the default link" "follow: dry run" "$out"
assert_not_contains "and its prompts resolve beside the real config, not the link" "Could not open file" "$out"
out="$(env -u DESK_CONFIG -u DESK_CONFIG_DEFAULT XDG_CONFIG_HOME="$ROOT/xdg" "$RUN" follow --dry-run 2>&1)"
assert_contains "so does desk-run" "follow: dry run" "$out"
out="$(env -u DESK_CONFIG -u DESK_CONFIG_DEFAULT XDG_CONFIG_HOME="$ROOT/no-xdg" "$CLI" run --dry-run 2>&1)"; rc=$?
assert_eq "with neither, it refuses" "2" "$rc"
assert_contains "and names the default it looked for" "$ROOT/no-xdg/desk/config.json" "$out"

echo
echo "=== a failed ticket fetch keeps the window ==="
jira_before="$(jq .last_jira_ok "$DESK_FOLLOW_STATE_FILE")"
FAKE_JIRA_FAIL=1 "$RUN" follow > "$ROOT/fail.out" 2>&1
assert_eq "the run reports partial" "1" "$?"
assert_eq "the ticket window does not move" "$jira_before" "$(jq .last_jira_ok "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== gh is read-only ==="
desk_follow_gh pr merge 40 > /dev/null 2>&1
assert_eq "gh pr merge is refused" "2" "$?"
desk_follow_gh api repos > /dev/null 2>&1
assert_eq "gh api is refused" "2" "$?"

echo
echo "=== the message stays under its cap ==="
q="$(jq -n '{changes: [range(0; 60) | {at: 1800000000, ref: "ABC-\(.)", title: "t", context: "", what: ("x" * 300)}], dropped: 3}')"
m="$(desk_follow_message '{"label":"L"}' "$q" n "$INST/prompts/follow-preamble.md" 4000 UTC)"
[ "${#m}" -le 4000 ] && ok "a long queue fits the cap (${#m} chars)" || bad "a long queue fits the cap (${#m} chars)"
assert_contains "the rest are named, not lost" "more, too long to include" "$m"
assert_contains "dropped changes are counted" "Plus 3 older changes" "$m"

echo
echo "=== everything tracked closed: the seam for retiring a follow ==="
{ issue DEF-5 "Done"; } | rest > "$FIX/changes-result.json"
"$RUN" follow > /dev/null 2>&1
assert_eq "beta's only ticket is done: recorded" "true" "$(jq --arg s "$SID_B" '.all_closed | has($s)' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "alpha's are not" "false" "$(jq --arg s "$SID_A" '.all_closed | has($s)' "$DESK_FOLLOW_STATE_FILE")"
assert_contains "list suggests retiring it" "everything it tracks is closed" "$("$CLI" list)"

echo
echo "=== removing a follow drops its queue ==="
"$CLI" remove --session "$SID_B" > /dev/null
"$RUN" follow > /dev/null 2>&1
assert_eq "no queue for a session no longer followed" "false" "$(jq --arg s "$SID_B" '.queues | has($s)' "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== a last page that says more follow fails the fetch ==="
jira_before="$(jq .last_jira_ok "$DESK_FOLLOW_STATE_FILE")"
issue ABC-2 "Blocked" | jq -cs '{issues:., isLast:false, nextPageToken:"p2"}' > "$FIX/changes-result.json"
"$RUN" follow > /dev/null 2>&1
assert_eq "a short pagination keeps the ticket window" "$jira_before" "$(jq .last_jira_ok "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== a run with only skipped changes sends nothing, and the counts carry ==="
sessions << EOF
$SID_A alpha-renamed true
EOF
"$CLI" add --session "$SID_A" ABC-1 > /dev/null
jq --arg s "$SID_A" '.queues[$s].changes = [] | .queues[$s].skipped = {}' "$DESK_FOLLOW_STATE_FILE" > "$ROOT/s" && mv "$ROOT/s" "$DESK_FOLLOW_STATE_FILE"
{
	issue ABC-1 "In QA" "" "[$(link LNK-7)]" "[$(cmt 907 "github-actions" "Deployed to dev")]"
} | rest > "$FIX/changes-result.json"
prs_none
: > "$FOLLOW_TEST_SENT"
"$RUN" follow > /dev/null 2>&1
assert_eq "a status move and a bot comment alone send nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_eq "nothing is queued" "0" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "the skipped changes are counted" '{"status moves":1,"bot comments":1}' "$(jq -c --arg s "$SID_A" '.queues[$s].skipped' "$DESK_FOLLOW_STATE_FILE")"
issue ABC-1 "In QA" "" "[$(link LNK-7)]" "[$(cmt 907 "github-actions" "Deployed to dev"),$(cmt 908 "Dev One" "QA found a gap in the plan.")]" | rest > "$FIX/changes-result.json"
"$RUN" follow > /dev/null 2>&1
msg="$(jq -r .message "$FOLLOW_TEST_SENT")"
assert_contains "the next substantive change goes out" 'new comment by Dev One: "QA found a gap in the plan."' "$msg"
assert_contains "with the earlier skips in its footer" "1 status move" "$msg"
assert_eq "and the counts reset after the send" '{}' "$(jq -c --arg s "$SID_A" '.queues[$s].skipped' "$DESK_FOLLOW_STATE_FILE")"

echo
echo "=== a dry run with a lookback and no state: only what moved ==="
{ issue ABC-2 "In Review" "" "[]" "[$(cmt 909 "Dev One" "Picked this up.")]"; } | rest > "$FIX/changes-result.json"
out="$(DESK_FOLLOW_STATE_FILE="$ROOT/fresh-state.json" "$RUN" follow --dry-run --lookback-minutes 60 2>&1)"
assert_contains "a comment in the window is listed" 'new comment by Dev One: "Picked this up."' "$out"
assert_not_contains "a ticket with no snapshot is not listed as news" "new under the follow" "$out"
assert_contains "it is counted instead" "first-seen ticket" "$out"
assert_not_contains "a ticket only the scope query returned is not" "ABC-11" "$out"
[ -f "$ROOT/fresh-state.json" ] && bad "the dry run wrote state" || ok "the dry run wrote no state"

echo
echo "=== the older names still work ==="
MIG="$ROOT/migrate-state"
mkdir -p "$MIG"
printf '{"entries":{"%s":{"label":"old","keys":["ABC-1"],"related":[]}}}\n' "$SID_A" > "$MIG/watch.json"
printf '{"last_run":{"at":1}}\n' > "$MIG/watch-state.json"
out="$(env -u DESK_FOLLOW_FILE -u DESK_FOLLOW_STATE_FILE DESK_STATE_DIR="$MIG" "$CLI" list 2>&1)"
assert_contains "a follow list at the old path is read" "old  (aaaaaaaa" "$out"
assert_eq "and moved to the new one" "yes no" "$([ -f "$MIG/follow.json" ] && echo yes || echo no) $([ -f "$MIG/watch.json" ] && echo yes || echo no)"
assert_eq "the state moves too, unchanged" '{"last_run":{"at":1}}' "$(jq -c . "$MIG/follow-state.json" 2> /dev/null)"
printf '{"entries":{}}\n' > "$MIG/watch.json"
env -u DESK_FOLLOW_FILE -u DESK_FOLLOW_STATE_FILE DESK_STATE_DIR="$MIG" "$CLI" list > /dev/null 2>&1
assert_eq "an old file never overwrites a new one" "old" "$(jq -r --arg s "$SID_A" '.entries[$s].label' "$MIG/follow.json")"
out="$(env -u DESK_FOLLOW_FILE DESK_WATCH_FILE="$MIG/follow.json" DESK_STATE_DIR="$ROOT/elsewhere" "$CLI" list 2>&1)"
assert_contains "the older override is still read" "old  (aaaaaaaa" "$out"
jq '.passes.follow.kind = "watch"' "$INST/config.json" > "$ROOT/c" && cp "$ROOT/c" "$INST/config.json"
out="$("$CLI" run --dry-run 2>&1)"
assert_contains "a pass of the older kind \"watch\" still runs as the follow pass" "follow: dry run" "$out"

echo
echo "=== a ticket another session owns goes only to that session ==="
SID_P="dddddddd-4444-4444-8444-444444444444"
SID_Q="eeeeeeee-5555-4555-8555-555555555555"
SID_R="ffffffff-6666-4666-8666-666666666666"
export DESK_FOLLOW_FILE="$ROOT/own-follow.json" DESK_FOLLOW_STATE_FILE="$ROOT/own-follow-state.json"
sessions << EOF
$SID_P papa-session true
$SID_Q quebec-session true
$SID_R romeo-session true
EOF
"$CLI" add --session "$SID_P" OWN-1 SHR-3 > /dev/null
"$CLI" add --session "$SID_Q" QQ-2 SHR-3 > /dev/null
"$CLI" add --session "$SID_R" RR-1 --related OWN-1 > /dev/null
# Q's child links to P's key, and P's key links back to it, so each is one
# hop from the other's scope.
{
	issue OWN-1 "In Progress" "" "[$(link QQ-21)]"
	issue QQ-2 "In Progress"
	issue QQ-21 "To Do" QQ-2 "[$(link OWN-1)]"
	issue SHR-3 "To Do"
	issue RR-1 "To Do"
} | headless > "$FIX/scope-result.json"
echo '{"issues":{"nodes":[]}}' > "$FIX/changes-result.json"
prs_none
"$RUN" follow > /dev/null 2>&1
assert_eq "a link to another session's key stays out of scope" "false" "$(jq --arg s "$SID_Q" '.queues[$s].scope | index("OWN-1") != null' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "so does a link to another session's child" "false" "$(jq --arg s "$SID_P" '.queues[$s].scope | index("QQ-21") != null' "$DESK_FOLLOW_STATE_FILE")"
assert_eq "a key both sessions own is in both scopes" "true true" "$(jq -r --arg p "$SID_P" --arg q "$SID_Q" '[.queues[$p, $q].scope | index("SHR-3") != null] | join(" ")' "$DESK_FOLLOW_STATE_FILE")"
{
	issue OWN-1 "In Progress" "" "[$(link QQ-21)]" "[$(cmt 951 "Dev One" "Plan changed for QQ-2 too.")]"
	issue SHR-3 "To Do" "" "[]" "[$(cmt 952 "Dev Two" "Shared news.")]"
	issue QQ-21 "To Do" QQ-2 "[$(link OWN-1)]" "[$(cmt 953 "Dev Three" "Child news.")]"
} | rest > "$FIX/changes-result.json"
pr 41 "[SHR-3] Shared work" "shr-3-work" OPEN h1 | jq -s --arg t "$future" '.[0].createdAt = $t | .[0].updatedAt = $t' > "$FIX/prs.json"
# Q is renamed since it was followed: the line names it as it is called now.
sessions << EOF
$SID_P papa-session true
$SID_Q quebec-renamed true
$SID_R romeo-session true
EOF
: > "$FOLLOW_TEST_SENT"
"$RUN" follow > /dev/null 2>&1
msg_p="$(jq -r 'select(.to == "papa-session") | .message' "$FOLLOW_TEST_SENT")"
msg_q="$(jq -r 'select(.to == "quebec-renamed") | .message' "$FOLLOW_TEST_SENT")"
msg_r="$(jq -r 'select(.to == "romeo-session") | .message' "$FOLLOW_TEST_SENT")"
assert_contains "the owner gets its ticket's news" 'new comment by Dev One: "Plan changed for QQ-2 too."' "$msg_p"
assert_not_contains "a session it only links to, or that it mentions, does not" "Plan changed" "$msg_q"
assert_contains "a shared key's news goes to one owner" 'new comment by Dev Two: "Shared news."' "$msg_p"
assert_contains "and to the other" 'new comment by Dev Two: "Shared news."' "$msg_q"

echo
echo "=== a change another followed session also has says so ==="
assert_contains "a shared key's line names the other owner by its current name" \
	'SHR-3 "Summary of SHR-3" (also followed by quebec-renamed): new comment by Dev Two' "$msg_p"
assert_contains "and the other owner's line names the first" \
	'SHR-3 "Summary of SHR-3" (also followed by papa-session): new comment by Dev Two' "$msg_q"
assert_contains "a key another session lists as related names that session" \
	'OWN-1 "Summary of OWN-1" (also followed by romeo-session): new comment by Dev One' "$msg_p"
assert_contains "and the related session's line names the owner" \
	'OWN-1 "Summary of OWN-1" (also followed by papa-session): new comment by Dev One' "$msg_r"
assert_contains "a child line keeps its relation and has no other follower" \
	'QQ-21 "Summary of QQ-21" (child of QQ-2): new comment by Dev Three' "$msg_q"
assert_contains "a PR on a shared key names the other session" \
	'PR #41 "[SHR-3] Shared work" (SHR-3; also followed by quebec-renamed): opened' "$msg_p"
assert_not_contains "a session is never told it follows its own ticket" "also followed by quebec-renamed" "$msg_q"

echo
echo "=== a session made a followed session from outside is told, once ==="
export DESK_FOLLOW_FILE="$STATE/intro-follow.json" DESK_FOLLOW_STATE_FILE="$STATE/intro-follow-state.json"
rm -f "$DESK_FOLLOW_FILE" "$DESK_FOLLOW_STATE_FILE"
SID_I="dddddddd-4444-4444-8444-444444444444"
sessions << EOF
$SID_A alpha-session true
$SID_B beta-session true
$SID_I india-session true
EOF
: > "$FOLLOW_TEST_SENT"
out="$(CLAUDE_CODE_SESSION_ID="$SID_B" "$CLI" add --session "$SID_A" INT-1 --related INT-9)"
assert_contains "the add reports the follow and that the session was told" "told alpha-session it is a followed session" "$out"
assert_eq "exactly one message went out, to the target" "alpha-session" "$(jq -r '.to' "$FOLLOW_TEST_SENT")"
intro="$(jq -r '.message' "$FOLLOW_TEST_SENT")"
assert_eq "it carries the follow marker" "[desk-follow]" "$(head -n1 <<< "$intro" | cut -d' ' -f1)"
assert_contains "it says the session is now followed" "now a followed session" "$intro"
assert_contains "it names the tracked ticket" "INT-1" "$intro"
assert_contains "and the related one" "INT-9 (only as themselves)" "$intro"
assert_contains "it points at the skill" "desk-follow skill" "$intro"
assert_contains "and at what a handoff carries" '"Before compacting"' "$intro"
assert_eq "nothing is left queued" "null" "$(jq -c --arg s "$SID_A" '.entries[$s].intro_due_at' "$DESK_FOLLOW_FILE")"

: > "$FOLLOW_TEST_SENT"
CLAUDE_CODE_SESSION_ID="$SID_B" "$CLI" add --session "$SID_A" INT-1 > /dev/null
assert_eq "adding the same keys again sends nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
out="$(CLAUDE_CODE_SESSION_ID="$SID_B" "$CLI" add --session "$SID_A" INT-2)"
assert_eq "adding a new key sends again" "1" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_contains "naming the new key too" "INT-1, INT-2" "$(jq -r '.message' "$FOLLOW_TEST_SENT")"

: > "$FOLLOW_TEST_SENT"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" "$CLI" add INT-3)"
assert_eq "a session following its own tickets is sent nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
assert_not_contains "and the add says nothing of telling it" "told" "$out"
out="$("$CLI" remove --session "$SID_A" INT-3)"
assert_eq "removing keys sends nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"

: > "$FOLLOW_TEST_SENT"
out="$(FAKE_SEND_TO=somebody-else CLAUDE_CODE_SESSION_ID="$SID_B" "$CLI" add --session "$SID_I" INT-5)"
assert_contains "a send the pinned path refuses is queued instead" "goes with its first update" "$out"
assert_eq "the intro waits in the entry" "true" "$(jq --arg s "$SID_I" '.entries[$s].intro_due_at != null' "$DESK_FOLLOW_FILE")"

echo
echo "=== an intro for a session that is not running leads its first update, once ==="
sessions << EOF
$SID_A alpha-session true
$SID_B beta-session true
$SID_I india-session false
EOF
"$CLI" remove --session "$SID_I" > /dev/null
: > "$FOLLOW_TEST_SENT"
out="$(CLAUDE_CODE_SESSION_ID="$SID_B" "$CLI" add --session "$SID_I" INT-5)"
assert_contains "a session that is not running is not messaged" "goes with its first update" "$out"
assert_eq "no send was attempted" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
"$CLI" remove --session "$SID_A" > /dev/null
{ issue INT-5 "To Do"; } | headless > "$FIX/scope-result.json"
echo '{"issues":{"nodes":[]}}' > "$FIX/changes-result.json"
echo '[]' > "$FIX/prs.json"
"$RUN" follow > /dev/null 2>&1
assert_eq "the baseline run sends nothing" "0" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
sessions << EOF
$SID_I india-session true
EOF
jq '.last_run.at -= 3600 | .last_jira_ok -= 3600 | .last_gh_ok -= 3600 | .scope.refreshed_at -= 600' "$DESK_FOLLOW_STATE_FILE" > "$ROOT/s" && mv "$ROOT/s" "$DESK_FOLLOW_STATE_FILE"
{ issue INT-5 "To Do" "" "[]" "[$(cmt 971 "Dev One" "First news.")]"; } | rest > "$FIX/changes-result.json"
"$RUN" follow --scheduled > /dev/null 2>&1
assert_eq "the first update goes out" "1" "$(wc -l < "$FOLLOW_TEST_SENT" | tr -d ' ')"
msg="$(jq -r '.message' "$FOLLOW_TEST_SENT")"
assert_contains "and carries the intro" "now a followed session" "$msg"
assert_contains "ahead of the changes" "First news." "$msg"
assert_eq "the intro comes before the standing preamble and the changes" "now a followed session" "$(grep -n -o -e 'now a followed session' -e 'STANDING PREAMBLE' -e 'First news' <<< "$msg" | head -n1 | cut -d: -f2-)"
assert_eq "the intro is marked delivered" "true" "$(jq --arg s "$SID_I" '.intro_done[$s] > 0' "$DESK_FOLLOW_STATE_FILE")"
: > "$FOLLOW_TEST_SENT"
jq '.last_run.at -= 3600 | .last_jira_ok -= 3600 | .last_gh_ok -= 3600' "$DESK_FOLLOW_STATE_FILE" > "$ROOT/s" && mv "$ROOT/s" "$DESK_FOLLOW_STATE_FILE"
{ issue INT-5 "To Do" "" "[]" "[$(cmt 972 "Dev One" "Second news.")]"; } | rest > "$FIX/changes-result.json"
"$RUN" follow --scheduled > /dev/null 2>&1
msg="$(jq -r '.message' "$FOLLOW_TEST_SENT")"
assert_contains "the next update goes out" "Second news." "$msg"
assert_not_contains "without the intro again" "now a followed session" "$msg"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
