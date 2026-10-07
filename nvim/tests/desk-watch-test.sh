#!/usr/bin/env bash
# The watch pass (claude/desk-lib/watch.sh, claude/desk-watch): the watch
# list CLI, the interval floor, a baseline run, a run that forwards changes
# to a live session, a queue held for a session that is not running and
# delivered whole once it is, the send pinned to the resolved name (a send
# to any other name is refused by the deny hook), the dry run, and the
# seam for retiring a watch whose tickets are all closed.
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
export DESK_WATCH_FILE="$STATE/watch.json"
export DESK_WATCH_STATE_FILE="$STATE/watch-state.json"
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
if [ "$tools" = "SendMessage" ]; then
	echo "send $(pwd)" >> "$WATCH_TEST_CALLS"
	input="$(jq -c '.[0]' pinned-args.json)"
	[ -n "${FAKE_SEND_TO:-}" ] && input="$(jq -c --arg to "$FAKE_SEND_TO" '.to = $to' <<< "$input")"
	input="$(jq -c '. + {summary: "watcher update"}' <<< "$input")"
	printf '%s\n' "$input" >> "$WATCH_TEST_SENT"
	cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")"
	emit_use t1 SendMessage "$input"
	if jq -cn --argjson i "$input" '{tool_name:"SendMessage", tool_input:$i}' | bash -c "$cmd" > /dev/null 2>&1; then
		emit_result t1 "${FAKE_SEND_RESULT:-Message sent.}" false
	else
		emit_result t1 "PreToolUse hook denied this call" true
	fi
	echo '{"type":"result","subtype":"success","total_cost_usd":0.02}'
	exit 0
fi
echo "fetch" >> "$WATCH_TEST_CALLS"
cp prompt.txt "$WATCH_TEST_LAST_PROMPT"
scope="$(sed -n 's/^SCOPE: //p' prompt.txt)"
changes="$(sed -n 's/^CHANGES: //p' prompt.txt)"
if [ "$scope" != none ]; then
	emit_use s1 mcp__tickets__search "$(jq -cn --arg q "$scope" '{jql:$q}')"
	emit_result s1 "$(cat "$WATCH_TEST_FIX/scope-result.json")" false
fi
if [ "$changes" != none ] && [ -z "${FAKE_JIRA_FAIL:-}" ]; then
	emit_use c1 mcp__tickets__search "$(jq -cn --arg q "$changes" '{jql:$q}')"
	emit_result c1 "$(cat "$WATCH_TEST_FIX/changes-result.json")" false
fi
echo '{"type":"result","subtype":"success","total_cost_usd":0.01}'
FAKE
chmod +x "$FAKEBIN/claude"
export WATCH_TEST_CALLS="$CALLS" WATCH_TEST_FIX="$FIX" WATCH_TEST_SENT="$ROOT/sent.jsonl" WATCH_TEST_LAST_PROMPT="$ROOT/last-prompt.txt"
: > "$WATCH_TEST_SENT"
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
printf 'SCOPE: {{scope_jql}}\nCHANGES: {{changes_jql}}\nFIELDS: {{changes_fields}}\n' > "$INST/prompts/watch-fetch.md"
printf 'Send to {{to}}:\n{{message}}\n' > "$INST/prompts/watch-send.md"
printf 'STANDING PREAMBLE: end with [needs-you] only when the bar is met.\n' > "$INST/prompts/watch-preamble.md"
write_config() { # interval
	jq -n --argjson iv "${1:-15}" '{
		timezone: "UTC", ticket_search_tool: "x", mail_search_tool: "x", ticket_status_step_id: "x", mail_fetch_step_id: "x",
		notes_repo: "/nonexistent", files: ["notes.md"],
		passes: {watch: {kind: "watch", interval_minutes: $iv,
			jira: {prompt: "prompts/watch-fetch.md", tool: "mcp__tickets__search"},
			github_repos: ["org/repo"],
			send: {prompt: "prompts/watch-send.md"},
			preamble: "prompts/watch-preamble.md"}}}' > "$INST/config.json"
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
for f in lock model-call timeout tool-results steps watch; do
	# shellcheck disable=SC1090
	source "$LIB/$f.sh"
done
export PATH="$FAKEBIN:$PATH"
CLI="$REPO_ROOT/claude/desk-watch"
RUN="$REPO_ROOT/claude/desk-run"

echo "=== the watch list CLI ==="
sessions << EOF
$SID_A alpha-session true
$SID_B beta-session true
$SID_OTHER some-other-session true
EOF
out="$("$CLI" add ABC-1 2>&1)"; rc=$?
assert_eq "add without a session or \$CLAUDE_CODE_SESSION_ID refuses" "2" "$rc"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" "$CLI" add abc-1 ABC-2 --related XYZ-9)"
assert_contains "add from inside a session uses its id and the current name as label" "watching ABC-1, ABC-2, XYZ-9 for alpha-session" "$out"
out="$("$CLI" add --session beta-session --label "Beta work" DEF-5)"
assert_contains "add resolves a session name to its id" "for Beta work" "$out"
assert_eq "the entry is keyed by session id" "$SID_B" "$(jq -r '.entries | to_entries[] | select(.value.label == "Beta work") | .key' "$DESK_WATCH_FILE")"
out="$("$CLI" add --session "$SID_A" not-a-key 2>&1)"; rc=$?
assert_eq "a non-key is refused" "2" "$rc"
"$CLI" add --session "$SID_B" DEF-6 > /dev/null
assert_eq "add to an existing watch merges keys" '["DEF-5","DEF-6"]' "$(jq -c --arg s "$SID_B" '.entries[$s].keys' "$DESK_WATCH_FILE")"
out="$("$CLI" remove --session "$SID_B" DEF-6)"
assert_contains "remove with keys drops only those" "still watching DEF-5" "$out"
out="$("$CLI" list)"
assert_contains "list names each watch with its liveness" "alpha-session  (aaaaaaaa, live)" "$out"
assert_contains "list shows tracked and related keys" "tracks: ABC-1, ABC-2; related: XYZ-9" "$out"
assert_eq "list --json is the machine-readable seam" "2" "$("$CLI" list --json | jq length)"

echo
echo "=== the interval floor ==="
write_config 5
log="$(desk_watch_interval_minutes "$(jq -c .passes.watch "$DESK_CONFIG")" watch 2>&1 > /dev/null)"
assert_eq "an interval under 15 minutes is clamped to 15" "15" "$(desk_watch_interval_minutes "$(jq -c .passes.watch "$DESK_CONFIG")" watch 2> /dev/null)"
assert_contains "and the clamp is logged" "interval_minutes 5 is under the 15-minute floor; using 15" "$log"
write_config 30
assert_eq "an interval above the floor is kept" "30" "$(desk_watch_interval_minutes "$(jq -c .passes.watch "$DESK_CONFIG")" watch 2> /dev/null)"
write_config
assert_eq "no interval: the 15-minute default" "15" "$(desk_watch_interval_minutes '{}' watch 2> /dev/null)"

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
"$RUN" watch > "$ROOT/run1.out" 2>&1
assert_eq "the baseline run succeeds" "0" "$?"
assert_eq "one ticket fetch, no send" "fetch" "$(grep -v '^gh' "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "the baseline asks only the scope query" "CHANGES: none" "$(cat "$WATCH_TEST_LAST_PROMPT")"
assert_contains "the scope query covers tracked keys and children" "SCOPE: key in (ABC-1, ABC-2, DEF-5, XYZ-9) OR parent in (ABC-1, ABC-2, DEF-5)" "$(cat "$WATCH_TEST_LAST_PROMPT")"
assert_eq "a child is in scope" "true" "$(jq --arg s "$SID_A" '.queues[$s].scope | index("ABC-11") != null' "$DESK_WATCH_STATE_FILE")"
assert_eq "a linked ticket is in scope" "true" "$(jq --arg s "$SID_A" '.queues[$s].scope | index("LNK-7") != null' "$DESK_WATCH_STATE_FILE")"
assert_eq "nothing is queued" "0" "$(jq '[.queues[].changes[]] | length' "$DESK_WATCH_STATE_FILE")"
assert_eq "the PR is snapshotted" "h1" "$(jq -r '.prs["org/repo#40"].head' "$DESK_WATCH_STATE_FILE")"

echo
echo "=== the next run forwards every movement to the live session ==="
# Pretend the last run was a while ago, past the scheduled interval.
jq '.last_run.at -= 3600 | .last_jira_ok -= 3600 | .last_gh_ok -= 3600 | .scope.refreshed_at -= 600' "$DESK_WATCH_STATE_FILE" > "$ROOT/s" && mv "$ROOT/s" "$DESK_WATCH_STATE_FILE"
future="$(date -u -v+1H +%Y-%m-%dT%H:%M:%S.000+0000 2> /dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%S.000+0000)"
{
	issue ABC-11 "Done" ABC-1 "[]" "[{\"id\":\"901\",\"author\":{\"displayName\":\"Dev One\"},\"created\":\"$future\",\"updated\":\"$future\",\"body\":\"Merged; steps 2-4 not checked yet.\"}]"
	issue LNK-7 "In Progress"
	issue OTH-3 "To Do" "" "[]" "[]" "" "Mentions ABC-2 in passing"
} | rest > "$FIX/changes-result.json"
pr 40 "[ABC-11] Build the thing" "abc-11-build" MERGED h2 '[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"evals","status":"COMPLETED","conclusion":"FAILURE"}]' \
	| jq -s '.[0].updatedAt = "2026-10-07T09:00:00Z"' > "$FIX/prs.json"
jq -n --arg t "$future" '{comments:[{id:"IC_1",author:{login:"dev1"},createdAt:$t,body:"Dropped the retry flag."}],reviews:[]}' > "$FIX/pr-40.json"
: > "$CALLS"
: > "$WATCH_TEST_SENT"
"$RUN" watch --scheduled > "$ROOT/run2.out" 2>&1
assert_eq "the run succeeds" "0" "$?"
assert_contains "the changes query asks for scope, children and mentions in the window" 'text ~ "\"ABC-1\""' "$(cat "$WATCH_TEST_LAST_PROMPT")"
assert_contains "and bounds it by relative minutes" "AND updated >= -" "$(cat "$WATCH_TEST_LAST_PROMPT")"
assert_eq "one send, to alpha's current name" "alpha-session" "$(jq -r '.to' "$WATCH_TEST_SENT" | head -n1)"
msg="$(jq -r 'select(.to == "alpha-session") | .message' "$WATCH_TEST_SENT")"
assert_eq "the message starts with the marker" "[desk-watch] Watcher update for alpha-session" "$(head -n1 <<< "$msg" | cut -d: -f1)"
assert_contains "the preamble rides along" "STANDING PREAMBLE" "$msg"
assert_contains "a child's status change is forwarded" 'ABC-11 "Summary of ABC-11" (child of ABC-1): status To Do → Done' "$msg"
assert_contains "a new comment is forwarded" 'new comment by Dev One: "Merged; steps 2-4 not checked yet."' "$msg"
assert_contains "a linked ticket's change is forwarded" "LNK-7" "$msg"
assert_contains "a ticket that mentions a tracked key is forwarded" "(mentions ABC-2)" "$msg"
assert_contains "a PR on a child's key is forwarded, with its new state and commits" "PR #40" "$msg"
assert_contains "the failing check is named" "1 failed (evals)" "$msg"
assert_contains "a new PR comment is forwarded" 'comment by dev1: "Dropped the retry flag."' "$msg"
assert_eq "beta has nothing that moved, so no message" "0" "$(jq -c 'select(.to == "beta-session")' "$WATCH_TEST_SENT" | wc -l | tr -d ' ')"
assert_eq "the queue is emptied on a confirmed send" "0" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_WATCH_STATE_FILE")"
assert_eq "last seen advances" "alpha-session" "$(jq -r --arg s "$SID_A" '.last_sent[$s].name' "$DESK_WATCH_STATE_FILE")"

echo
echo "=== a scheduled run inside the interval does nothing; a manual one runs ==="
: > "$CALLS"
"$RUN" watch --scheduled > /dev/null 2>&1
assert_eq "scheduled, just after a run: no fetch" "" "$(cat "$CALLS")"
"$RUN" watch > /dev/null 2>&1
assert_contains "manual: it runs" "fetch" "$(cat "$CALLS")"

echo
echo "=== a session that is not running keeps its queue, and gets it all at once ==="
sessions << EOF
$SID_A alpha-session false
$SID_B beta-session true
EOF
echo '{"issues":[], "isLast": true}' > "$FIX/changes-result.json"
issue ABC-2 "In Review" | rest > "$FIX/changes-result.json"
prs_none
: > "$WATCH_TEST_SENT"
"$RUN" watch > /dev/null 2>&1
assert_eq "nothing is sent to a session that is not running" "0" "$(wc -l < "$WATCH_TEST_SENT" | tr -d ' ')"
assert_eq "its change waits in the queue" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_WATCH_STATE_FILE")"
issue ABC-2 "Done" | rest > "$FIX/changes-result.json"
"$RUN" watch > /dev/null 2>&1
assert_eq "a second change queues behind it" "2" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_WATCH_STATE_FILE")"
sessions << EOF
$SID_A alpha-renamed true
$SID_B beta-session true
EOF
echo '{"issues":[], "isLast": true}' > "$FIX/changes-result.json"
"$RUN" watch > /dev/null 2>&1
assert_eq "once live: one message, to its new name" "alpha-renamed" "$(jq -r .to "$WATCH_TEST_SENT" | tr '\n' ' ' | sed 's/ $//')"
msg="$(jq -r .message "$WATCH_TEST_SENT")"
assert_contains "it carries the first queued change" "status To Do → In Review" "$msg"
assert_contains "and the second" "status In Review → Done" "$msg"
assert_contains "it says when the last update went out" "Changes since " "$msg"
assert_eq "and the queue is empty afterwards" "0" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_WATCH_STATE_FILE")"

echo
echo "=== a name that does not address the session alone holds the queue ==="
issue ABC-2 "Reopened" | rest > "$FIX/changes-result.json"
sessions << EOF
$SID_A alpha-renamed true
$SID_OTHER alpha-renamed true
$SID_B beta-session true
EOF
: > "$WATCH_TEST_SENT"
"$RUN" watch > "$ROOT/dup.out" 2>&1
assert_eq "no send when two sessions share the name" "0" "$(wc -l < "$WATCH_TEST_SENT" | tr -d ' ')"
assert_contains "and it says why" "does not address this session alone" "$(cat "$ROOT/dup.out")"

echo
echo "=== the send is pinned to the resolved name ==="
sessions << EOF
$SID_A alpha-renamed true
$SID_B beta-session true
$SID_OTHER some-other-session true
EOF
: > "$WATCH_TEST_SENT"
FAKE_SEND_TO=some-other-session "$RUN" watch > /dev/null 2>&1
assert_eq "the model tried another peer" "some-other-session" "$(jq -r .to "$WATCH_TEST_SENT")"
assert_eq "the deny hook refused it, so the queue stays" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_WATCH_STATE_FILE")"
FAKE_SEND_RESULT="Message held for the user's approval." "$RUN" watch > /dev/null 2>&1
assert_eq "a held delivery is not a confirmed send" "1" "$(jq --arg s "$SID_A" '.queues[$s].changes | length' "$DESK_WATCH_STATE_FILE")"

# The hook itself, on the settings the runner writes.
hook="$LIB/deny-unlisted-tool.sh"
printf '[{"to":"alpha-renamed","message":"hello"}]' > "$ROOT/pinned.json"
try_hook() { jq -cn --argjson i "$1" '{tool_name:"SendMessage", tool_input:$i}' | "$hook" --pinned "$ROOT/pinned.json" --ignore-keys summary -- SendMessage > /dev/null 2>&1; echo $?; }
assert_eq "hook: the pinned name and message pass" "0" "$(try_hook '{"to":"alpha-renamed","message":"hello"}')"
assert_eq "hook: a summary is ignored" "0" "$(try_hook '{"to":"alpha-renamed","message":"hello","summary":"x"}')"
assert_eq "hook: any other name is refused" "2" "$(try_hook '{"to":"some-other-session","message":"hello"}')"
assert_eq "hook: a changed message is refused" "2" "$(try_hook '{"to":"alpha-renamed","message":"hello, also do X"}')"
assert_eq "hook: an extra field is refused" "2" "$(try_hook '{"to":"alpha-renamed","message":"hello","notify_when_idle":true}')"
assert_eq "hook: another tool is refused" "2" "$(jq -cn '{tool_name:"ListAgents", tool_input:{}}' | "$hook" --pinned "$ROOT/pinned.json" --ignore-keys summary -- SendMessage > /dev/null 2>&1; echo $?)"

echo
echo "=== the dry run prints and changes nothing ==="
before="$(shasum "$DESK_WATCH_STATE_FILE")"
: > "$CALLS"
: > "$WATCH_TEST_SENT"
out="$("$RUN" watch --dry-run 2>&1)"
assert_contains "it prints what it would send" "=== would send to alpha-renamed" "$out"
assert_contains "including the message" "[desk-watch] Watcher update for alpha-session" "$out"
assert_eq "it sends nothing" "0" "$(wc -l < "$WATCH_TEST_SENT" | tr -d ' ')"
assert_eq "it writes no state" "$before" "$(shasum "$DESK_WATCH_STATE_FILE")"
out="$("$CLI" run --dry-run 2>&1)"
assert_contains "desk-watch run runs the watch pass" "would send to alpha-renamed" "$out"

echo
echo "=== a failed ticket fetch keeps the window ==="
jira_before="$(jq .last_jira_ok "$DESK_WATCH_STATE_FILE")"
FAKE_JIRA_FAIL=1 "$RUN" watch > "$ROOT/fail.out" 2>&1
assert_eq "the run reports partial" "1" "$?"
assert_eq "the ticket window does not move" "$jira_before" "$(jq .last_jira_ok "$DESK_WATCH_STATE_FILE")"

echo
echo "=== gh is read-only ==="
desk_watch_gh pr merge 40 > /dev/null 2>&1
assert_eq "gh pr merge is refused" "2" "$?"
desk_watch_gh api repos > /dev/null 2>&1
assert_eq "gh api is refused" "2" "$?"

echo
echo "=== the message stays under its cap ==="
q="$(jq -n '{changes: [range(0; 60) | {at: 1800000000, ref: "ABC-\(.)", title: "t", context: "", what: ("x" * 300)}], dropped: 3}')"
m="$(desk_watch_message '{"label":"L"}' "$q" n "$INST/prompts/watch-preamble.md" 4000 UTC)"
[ "${#m}" -le 4000 ] && ok "a long queue fits the cap (${#m} chars)" || bad "a long queue fits the cap (${#m} chars)"
assert_contains "the rest are named, not lost" "more, too long to include" "$m"
assert_contains "dropped changes are counted" "Plus 3 older changes" "$m"

echo
echo "=== everything tracked closed: the seam for retiring a watch ==="
{ issue DEF-5 "Done"; } | rest > "$FIX/changes-result.json"
"$RUN" watch > /dev/null 2>&1
assert_eq "beta's only ticket is done: recorded" "true" "$(jq --arg s "$SID_B" '.all_closed | has($s)' "$DESK_WATCH_STATE_FILE")"
assert_eq "alpha's are not" "false" "$(jq --arg s "$SID_A" '.all_closed | has($s)' "$DESK_WATCH_STATE_FILE")"
assert_contains "list suggests retiring it" "everything it tracks is closed" "$("$CLI" list)"

echo
echo "=== removing a watch drops its queue ==="
"$CLI" remove --session "$SID_B" > /dev/null
"$RUN" watch > /dev/null 2>&1
assert_eq "no queue for a session no longer watched" "false" "$(jq --arg s "$SID_B" '.queues | has($s)' "$DESK_WATCH_STATE_FILE")"

echo
echo "=== a dry run with a lookback and no state: only what moved ==="
{ issue ABC-2 "In Review"; } | rest > "$FIX/changes-result.json"
out="$(DESK_WATCH_STATE_FILE="$ROOT/fresh-state.json" "$RUN" watch --dry-run --lookback-minutes 60 2>&1)"
assert_contains "the ticket that moved is listed" 'ABC-2 "Summary of ABC-2": first seen by the watcher' "$out"
assert_not_contains "a ticket only the scope query returned is not" "ABC-11" "$out"
[ -f "$ROOT/fresh-state.json" ] && bad "the dry run wrote state" || ok "the dry run wrote no state"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
