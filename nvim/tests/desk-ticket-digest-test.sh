#!/usr/bin/env bash
# The ticket digest (claude/desk-lib/ticket-digest.sh, follow-diff.jq in
# ticket_digest mode): the window and its floor, reading only the runner's
# own query back (a saved oversized result included), what is forwarded
# and what is only counted (bots, the user's own posts and PRs, dependency
# PRs unless kept, status moves, PR updates), what a follow session
# already covers, grouping and the cap, snapshots installed only once the
# pass's window moves, and the whole thing through desk-run, with the next
# day's pass covering what a failed one missed. Offline: `claude` and `gh`
# are fakes.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$REPO_ROOT/claude/desk-lib"
DESK_RUN="$REPO_ROOT/claude/desk-run"

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

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export DESK_TICKET_CACHE="$STATE/ticket-status.json"
export DESK_FOLLOW_FILE="$STATE/follow.json"
export DESK_FOLLOW_STATE_FILE="$STATE/follow-state.json"
export DESK_TICKET_DIGEST_STATE_FILE="$STATE/ticket-digest-state.json"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
# The reader caches per config dir under the real state dir unless told otherwise.
export CLAUDE_SESSION_READER_CACHE="$ROOT/reader-cache"
mkdir -p "$STATE" "$CLAUDE_CONFIG_DIR"

FIX="$ROOT/fix"
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FIX" "$FAKEBIN"

# gh: `pr list` replies $FIX/prs.json, `pr view N` replies $FIX/pr-N.json.
cat > "$FAKEBIN/gh" << FAKE
#!/usr/bin/env bash
case "\$1 \$2" in
	"pr list") cat "$FIX/prs.json" ;;
	"pr view") cat "$FIX/pr-\$3.json" 2> /dev/null || echo '{"comments":[],"reviews":[]}' ;;
	*) exit 9 ;;
esac
FAKE
chmod +x "$FAKEBIN/gh"
export DESK_GH_BIN="$FAKEBIN/gh"

# A followed session: it tracks ABC-100, and its scope holds ABC-3.
SID="aaaaaaaa-1111-4111-8111-111111111111"
jq -n --arg s "$SID" '{entries: {($s): {label: "epic", keys: ["ABC-100"], related: [], added_at: 0}}}' > "$DESK_FOLLOW_FILE"
jq -n --arg s "$SID" '{queues: {($s): {changes: [], scope: ["ABC-100", "ABC-3"]}}, scope: {children: {"ABC-100": []}}}' > "$DESK_FOLLOW_STATE_FILE"

NOW=1791450000 # 2026-10-08T09:00:00Z
iso() { jq -rn --argjson t "$1" '$t | strftime("%Y-%m-%dT%H:%M:%S.000+0000")'; }
H1="$(iso $((NOW - 3600)))"
OLD="$(iso $((NOW - 30 * 86400)))"

comment() { # id author body created
	jq -cn --arg i "$1" --arg a "$2" --arg b "$3" --arg c "$4" '{id:$i, author:{displayName:$a}, body:$b, created:$c, updated:$c}'
}
issue() { # key status comments-json [parent] [description] [updated] [created]
	jq -cn --arg k "$1" --arg s "$2" --argjson c "$3" --arg p "${4:-}" --arg d "${5:-the plan}" \
		--arg u "${6:-$H1}" --arg cr "${7:-$OLD}" '
		{key:$k, fields:{summary:("Summary of " + $k), status:{name:$s, statusCategory:{key:"indeterminate"}},
		  issuetype:{name:"Task"}, assignee:{displayName:"Dev One"}, labels:[], resolution:null,
		  parent:(if $p == "" then null else {key:$p} end), issuelinks:[], updated:$u, created:$cr,
		  description:$d, comment:{comments:$c}}}'
}
pr() { # number title author [state] [head] [created] [updated]
	jq -cn --argjson n "$1" --arg t "$2" --arg a "$3" --arg s "${4:-OPEN}" --arg h "${5:-aaaaaaa1}" \
		--arg c "${6:-$H1}" --arg u "${7:-$H1}" '
		{number:$n, title:$t, headRefName:("branch-" + ($n|tostring)), state:$s, isDraft:false, updatedAt:$u,
		 createdAt:$c, reviewDecision:"", headRefOid:$h, labels:[], url:("https://example.invalid/pr/" + ($n|tostring)),
		 body:"", statusCheckRollup:[], author:{login:$a}}'
}

CFG_STEP='{"id":"F-tickets","kind":"fetch","tools":["mcp__tickets__search"],
	"ticket_digest":{"jql":"project = ABC","self":["Sam Self","sam-self"],
		"pr_skip_authors":["^app/dependabot$"],"pr_keep":"security",
		"skip":{"bot_signatures":["^Assess Bot"]}}}'
CONFIG='{"passes":{"follow":{"kind":"follow","github_repos":["org/repo"],
	"skip":{"bot_authors":["^Automation for Jira$","\\[bot\\]$"],"bot_signatures":["^Auto-approved by Review Bot"]}}}}'

# --- the library on its own ---------------------------------------------------

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
source "$LIB/model-call.sh"
source "$LIB/tool-results.sh"
source "$LIB/ticket-digest.sh"
lib_test() {
	local PASS_SCRATCH cfg ph jql d cfg1
	PASS_SCRATCH="$ROOT/pass1"
	mkdir -p "$PASS_SCRATCH/F-tickets-spill"

	cfg="$(desk_ticket_digest_config "$CFG_STEP" "$CONFIG")"
	assert_eq "the follow pass's repos are the default" '["org/repo"]' "$(jq -c .github_repos <<< "$cfg")"
	assert_eq "the step's bot signatures are added to the follow pass's" \
		'["^Auto-approved by Review Bot","^Assess Bot"]' "$(jq -c .skip.bot_signatures <<< "$cfg")"

	ph="$(desk_ticket_digest_window F-tickets "$cfg" $((NOW - 20 * 86400)) "$NOW")"
	assert_eq "a long-open window is floored at max_window_days" \
		"(project = ABC) AND updated >= -5760m" "$(jq -r .ticket_digest_jql <<< "$ph")"
	ph="$(desk_ticket_digest_window F-tickets "$cfg" $((NOW - 86400)) "$NOW")"
	jql="$(jq -r .ticket_digest_jql <<< "$ph")"
	assert_eq "the window starts five minutes before the pass's own" "(project = ABC) AND updated >= -1445m" "$jql"
	assert_eq "the fields are the follow pass's change fields" "true" \
		"$(jq -r '.ticket_digest_fields | contains("comment") and contains("description")' <<< "$ph")"

	# Run 1. The search result was too large to show, so it arrives as a
	# saved file; a second call with another query must not be read.
	{
		issue ABC-1 "In Progress" "[$(comment 11 "Kari Human" "Can Sam decide on the cache?" "$H1"),
			$(comment 12 "Sam Self" "my own note" "$H1"),
			$(comment 13 "Automation for Jira" "moved" "$H1"),
			$(comment 14 "Kari Human" "Assess Bot — assessment" "$H1"),
			$(comment 15 "Kari Human" "an old one" "$OLD")]"
		issue ABC-2 "To Do" "[]"
		issue ABC-3 "To Do" "[$(comment 31 "Kari Human" "followed elsewhere" "$H1")]"
		issue ABC-4 "To Do" "[$(comment 41 "Kari Human" "child of a followed key" "$H1")]" ABC-100
	} | jq -cs '{issues: .}' > "$PASS_SCRATCH/F-tickets-spill/saved.txt"
	{
		jq -cn --arg q "$jql" '{type:"tool_use", id:"u1", name:"mcp__tickets__search", input:{jql:$q}}'
		jq -cn '{type:"tool_use", id:"u2", name:"mcp__tickets__search", input:{jql:"project = ABC AND created >= x"}}'
	} > "$PASS_SCRATCH/F-tickets-tool-uses.jsonl"
	{
		jq -cn '{type:"tool_result", tool_use_id:"u1", content:"Output too large. Output has been saved to /somewhere/tool-results/saved.txt."}'
		jq -cn --argjson i "[$(issue ABC-77 "To Do" "[$(comment 771 "Kari Human" "not the digest query" "$H1")]")]" \
			'{type:"tool_result", tool_use_id:"u2", content:({issues:$i} | tojson)}'
	} > "$PASS_SCRATCH/F-tickets-tool-results.jsonl"
	{
		pr 1 "ABC-9 add the thing" dev-one
		pr 2 "Bump left-pad from 1 to 2" app/dependabot
		pr 3 "[Security] Bump jwt from 1 to 2" app/dependabot
		pr 4 "ABC-8 my own PR" sam-self
		pr 5 "ABC-3 followed work" dev-one
		pr 6 "ABC-10 older work" dev-two OPEN bbbbbbb1 "$OLD"
	} | jq -cs . > "$FIX/prs.json"

	desk_ticket_digest_collect morning F-tickets "$cfg" mcp__tickets__search
	assert_eq "collect succeeds" "0" "$?"
	assert_eq "only the digest query's tickets are read, from the saved file" '["ABC-1","ABC-2","ABC-3","ABC-4"]' \
		"$(jq -c '[.[].key]' "$PASS_SCRATCH/F-tickets-ticket-digest-issues.jsonl")"

	desk_ticket_digest_build morning F-tickets "$cfg" UTC
	d="$(cat "$PASS_SCRATCH/ticket-digest.json")"
	assert_eq "entries: the ticket with a person's comment first, then the PRs that moved" \
		'["ABC-1","org/repo#1","org/repo#3"]' "$(jq -c '[.entries[] | .key // .pr]' <<< "$d")"
	assert_eq "only the person's comment in the window is listed" \
		'["new comment by Kari Human: \"Can Sam decide on the cache?\""]' \
		"$(jq -c '[.entries[] | select(.key == "ABC-1") | .changes[].what]' <<< "$d")"
	assert_eq "the opened PR is news" "true" \
		"$(jq '[.entries[] | select(.pr == "org/repo#1") | .changes[].what | startswith("opened")] | all' <<< "$d")"
	assert_eq "counted: own posts, bot comments, dependency and own PRs, first-seen ones (ABC-1 too, beside its comment)" \
		'{"bot comments":2,"dependency PRs":1,"first-seen PRs":1,"first-seen tickets":2,"own PR moves":1,"own posts":1}' \
		"$(jq -c '.counted' <<< "$d")"
	assert_eq "what a follow covers is left to it (a scope ticket, a tracked key's child, a PR on one)" \
		"3" "$(jq '.left_to_follows' <<< "$d")"
	assert_eq "the snapshots wait in the pass's scratch" "false" \
		"$([ -e "$DESK_TICKET_DIGEST_STATE_FILE" ] && echo true || echo false)"
	desk_ticket_digest_commit
	assert_eq "commit installs them" '["ABC-1","ABC-2","ABC-3","ABC-4"]' \
		"$(jq -c '.tickets | keys' "$DESK_TICKET_DIGEST_STATE_FILE")"

	# Run 2, against run 1's snapshots.
	PASS_SCRATCH="$ROOT/pass2"
	mkdir -p "$PASS_SCRATCH"
	ph="$(desk_ticket_digest_window F-tickets "$cfg" $((NOW - 3000)) "$NOW")"
	jql="$(jq -r .ticket_digest_jql <<< "$ph")"
	jq -cn --arg q "$jql" '{type:"tool_use", id:"u1", name:"mcp__tickets__search", input:{jql:$q}}' > "$PASS_SCRATCH/F-tickets-tool-uses.jsonl"
	{
		issue ABC-1 "In Progress" "[$(comment 11 "Kari Human" "Can Sam decide on the cache?" "$H1")]" "" "a rewritten plan"
		issue ABC-2 "Done" "[]"
	} | jq -cs '{issues: .}' | jq -cn --rawfile t /dev/stdin '{type:"tool_result", tool_use_id:"u1", content:$t}' \
		> "$PASS_SCRATCH/F-tickets-tool-results.jsonl"
	{
		pr 1 "ABC-9 add the thing" dev-one MERGED aaaaaaa1 "$H1" "$(iso $((NOW - 60)))"
		pr 6 "ABC-10 older work" dev-two OPEN bbbbbbb2 "$OLD" "$(iso $((NOW - 60)))"
	} | jq -cs . > "$FIX/prs.json"
	jq -n --arg t "$(iso $((NOW - 600)))" '{comments: [], reviews: [
		{id:"r1", author:{login:"reviewer"}, submittedAt:$t, state:"CHANGES_REQUESTED", body:"Please split this"},
		{id:"r2", author:{login:"some-person"}, submittedAt:$t, state:"APPROVED", body:"Auto-approved by Review Bot: fine"}]}' > "$FIX/pr-1.json"
	desk_ticket_digest_collect morning F-tickets "$cfg" mcp__tickets__search
	desk_ticket_digest_build morning F-tickets "$cfg" UTC
	d="$(cat "$PASS_SCRATCH/ticket-digest.json")"
	assert_eq "a description edit is news, a known comment is not repeated" '["description edited"]' \
		"$(jq -c '[.entries[] | select(.key == "ABC-1") | .changes[].what]' <<< "$d")"
	assert_eq "a merge and a person's review are news, grouped on the PR" \
		'["now merged","review by reviewer: changes_requested, \"Please split this\""]' \
		"$(jq -c '[.entries[] | select(.pr == "org/repo#1") | .changes[].what] | sort' <<< "$d")"
	assert_eq "a status move alone, new commits and a bot's approval are counted" \
		'{"PR updates":1,"bot reviews":1,"status moves":1}' "$(jq -c '.counted' <<< "$d")"

	cfg1="$(jq -c '.max_entries = 1' <<< "$cfg")"
	desk_ticket_digest_build morning F-tickets "$cfg1" UTC
	d="$(cat "$PASS_SCRATCH/ticket-digest.json")"
	assert_eq "the cap keeps the entry with a person's post" '["org/repo#1"]' "$(jq -c '[.entries[] | .key // .pr]' <<< "$d")"
	assert_eq "and names what it left out" '["ABC-1"]' "$(jq -c '.more' <<< "$d")"

	# A fetch that did not come back gives the judge nothing and no snapshots.
	PASS_SCRATCH="$ROOT/pass3"
	mkdir -p "$PASS_SCRATCH"
	desk_ticket_digest_window F-tickets "$cfg" $((NOW - 3000)) "$NOW" > /dev/null
	: > "$PASS_SCRATCH/F-tickets-tool-uses.jsonl"
	: > "$PASS_SCRATCH/F-tickets-tool-results.jsonl"
	desk_ticket_digest_collect morning F-tickets "$cfg" mcp__tickets__search 2> /dev/null
	assert_eq "collect fails when the query never ran" "1" "$?"
	desk_ticket_digest_build morning F-tickets "$cfg" UTC
	assert_eq "the judge file is empty" "{}" "$(cat "$PASS_SCRATCH/ticket-digest.json")"
	assert_eq "no snapshots are staged" "false" "$([ -e "$PASS_SCRATCH/ticket-digest-state.json" ] && echo true || echo false)"
}
lib_test

# --- through desk-run --------------------------------------------------------

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"
rm -f "$DESK_TICKET_DIGEST_STATE_FILE"
repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n  detail\n' > "$repo/notes.md"
git -C "$repo" add notes.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main

INST="$ROOT/instance"
mkdir -p "$INST"
printf 'Search with jql={{ticket_digest_jql}}\nfields={{ticket_digest_fields}}\n' > "$INST/f-tickets.md"
echo "judge" > "$INST/j.md"
jq -n --arg repo "$repo" --argjson step "$CFG_STEP" --argjson c "$CONFIG" '{
	notes_repo: $repo, timezone: "UTC", files: ["notes.md"],
	ticket_search_tool: "mcp__tickets__search", mail_search_tool: "none", ticket_status_step_id: "none", mail_fetch_step_id: "none",
	passes: ({digestpass: {steps: [
		($step + {prompt: "f-tickets.md", connector: false, timeout: 30}),
		{id: "J", kind: "judge", prompt: "j.md", tools: ["Read"], input_files: ["notes.md", "ticket-digest.json"], timeout: 30}
	]}} + $c.passes)}' > "$INST/config.json"

J_SEEN="$ROOT/j-saw.json"
cat > "$FAKEBIN/claude" << FAKE
#!/usr/bin/env bash
J_SEEN="$J_SEEN"
J_FAIL_FLAG="$ROOT/j-fail"
FIXDIR="$FIX"
FAKE
cat >> "$FAKEBIN/claude" << 'FAKE'
case "$(pwd -P)" in
	*-F-tickets-page-*)
		jq -c '{type:"assistant",message:{content:[{type:"tool_use",id:"u2",name:"mcp__tickets__search",input:.[0]}]}}' pinned-args.json
		jq -nc --rawfile t "$FIXDIR/run-page2.json" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"u2",content:$t}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-F-tickets-*)
		q="$(sed -n 's/^Search with jql=//p' prompt.txt)"
		jq -nc --arg q "$q" '{type:"assistant",message:{content:[{type:"tool_use",id:"u1",name:"mcp__tickets__search",input:{jql:$q}}]}}'
		jq -nc --rawfile t "$FIXDIR/run-issues.json" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"u1",content:$t}]}}'
		echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{\"candidates\":[]}"}]}}'
		echo '{"type":"result","subtype":"success"}'
		;;
	*-J-*)
		cp ticket-digest.json "$J_SEEN" 2> /dev/null
		if [ -e "$J_FAIL_FLAG" ]; then
			echo '{"type":"assistant","message":{"content":[{"type":"text","text":"not json"}]}}'
		else
			jq -nc '{type:"assistant",message:{content:[{type:"text",text:({items:[
				{id:"j1",file:"notes.md",kind:"new",target:"top",before:"",after:"- WK: the PR [PR](https://example.invalid/pr/7)",
				 source:"https://example.invalid/pr/7",headline:"pr",tier:"worth_knowing"},
				{id:"j2",file:"notes.md",kind:"new",target:"top",before:"",after:"- WK: made up [PR](https://example.invalid/pr/8)",
				 source:"https://example.invalid/pr/8",headline:"made up",tier:"worth_knowing"}]} | tojson)}]}}'
		fi
		echo '{"type":"result","subtype":"success"}'
		;;
	*) echo '{"type":"result","subtype":"success"}' ;;
esac
FAKE
chmod +x "$FAKEBIN/claude"
export DESK_CLAUDE_BIN="$FAKEBIN/claude"

issue ABC-1 "In Progress" "[$(comment 11 "Kari Human" "a question" "$(iso $(($(date +%s) - 600)))")]" "" "plan" \
	"$(iso $(($(date +%s) - 600)))" | jq -cs '{issues: .}' > "$FIX/run-issues.json"
pr 7 "ABC-7 new work" dev-one OPEN aaaaaaa1 "$(iso $(($(date +%s) - 600)))" "$(iso $(($(date +%s) - 600)))" \
	| jq -cs . > "$FIX/prs.json"

touch "$ROOT/j-fail"
DESK_CONFIG="$INST/config.json" "$DESK_RUN" digestpass > "$ROOT/run1.out" 2>&1
assert_eq "a pass whose judge fails exits non-zero" "1" "$?"
assert_eq "the judge was handed the digest" '["ABC-1","org/repo#7"]' "$(jq -c '[.entries[] | .key // .pr]' "$J_SEEN" 2> /dev/null)"
assert_eq "a failed pass installs no snapshots" "false" "$([ -e "$DESK_TICKET_DIGEST_STATE_FILE" ] && echo true || echo false)"

DESK_CONFIG="$INST/config.json" "$DESK_RUN" digestpass > "$ROOT/run1b.out" 2>&1
assert_true "a later slot the same day runs nothing" "$(grep -q 'already ran today' "$ROOT/run1b.out" && echo true || echo false)"

# The next day: the failed pass never moved the window, so this one covers it.
rm -f "$ROOT/j-fail" "$J_SEEN"
jq 'del(.passes.digestpass.scheduled_date)' "$DESK_STATUS_FILE" > "$ROOT/st.json" && mv "$ROOT/st.json" "$DESK_STATUS_FILE"
DESK_CONFIG="$INST/config.json" "$DESK_RUN" digestpass > "$ROOT/run2.out" 2>&1
rc=$?
assert_eq "the next pass passes" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    /' "$ROOT/run2.out"
assert_eq "its window still covers what the failed pass saw" '["ABC-1","org/repo#7"]' \
	"$(jq -c '[.entries[] | .key // .pr]' "$J_SEEN" 2> /dev/null)"
assert_eq "an ok pass installs the snapshots" '["ABC-1"]' "$(jq -c '.tickets | keys' "$DESK_TICKET_DIGEST_STATE_FILE" 2> /dev/null)"
proposal="$(git -C "$repo" show refs/desk/proposal:proposal.json 2> /dev/null)"
assert_eq "a digest PR's link is an allowed source, a link it never listed is not" '["pr"]' \
	"$(jq -c '[.items[].headline]' <<< "$proposal" 2> /dev/null)"

# A search past one page: desk-run pages it, and the judge gets both pages.
rm -f "$J_SEEN"
t_new="$(iso $(($(date +%s) - 60)))"
issue ABC-21 "In Progress" "[$(comment 31 "Kari Human" "page one" "$t_new")]" "" "plan" "$t_new" \
	| jq -cs '{issues: ., nextPageToken: "t2", isLast: false}' > "$FIX/run-issues.json"
issue ABC-22 "In Progress" "[$(comment 41 "Kari Human" "page two" "$t_new")]" "" "plan" "$t_new" \
	| jq -cs '{issues: ., isLast: true}' > "$FIX/run-page2.json"
jq 'del(.passes.digestpass.scheduled_date)' "$DESK_STATUS_FILE" > "$ROOT/st.json" && mv -f "$ROOT/st.json" "$DESK_STATUS_FILE"
DESK_CONFIG="$INST/config.json" "$DESK_RUN" digestpass > "$ROOT/run3.out" 2>&1
rc=$?
assert_eq "a pass whose search runs past a page passes" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    /' "$ROOT/run3.out"
assert_eq "desk-run fetches the second page, and the judge gets both" '["ABC-21","ABC-22"]' \
	"$(jq -c '[.entries[] | .key // empty] | sort' "$J_SEEN" 2> /dev/null)"

echo
echo "=== a search past one page is paged by the runner, which alone can read the token ==="
source "$LIB/timeout.sh"
source "$LIB/steps.sh"
cat > "$FAKEBIN/claude-pages" << 'FAKE'
#!/usr/bin/env bash
# One page call: the pinned args, checked by the deny hook, answered from
# $PAGE_FIX/<token>.json, or saved to the project folder as a too-large
# result when $PAGE_FIX/<token>.spill exists.
settings=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = --settings ] && settings="${args[$((i + 1))]}"; done
input="$(jq -c '.[0]' pinned-args.json)"
echo "$input" >> "$PAGE_LOG"
tok="$(jq -r .nextPageToken <<< "$input")"
cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")"
jq -cn --argjson i "$input" --arg id "p$tok" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:"mcp__tickets__search",input:$i}]}}'
if jq -cn --argjson i "$input" '{tool_name:"mcp__tickets__search", tool_input:$i}' | bash -c "$cmd" > /dev/null 2>&1; then
	if [ -e "$PAGE_FIX/$tok.spill" ]; then
		saved="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(pwd -P)" | tr -c 'A-Za-z0-9' '-')/sess/tool-results/page-$tok.txt"
		mkdir -p "$(dirname "$saved")"
		cp "$PAGE_FIX/$tok.json" "$saved"
		jq -cn --arg id "p$tok" --arg p "$saved" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:("Error: result exceeds maximum allowed tokens. Output has been saved to " + $p + ".")}]}}'
	else
		jq -cn --arg id "p$tok" --rawfile t "$PAGE_FIX/$tok.json" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:$t}]}}'
	fi
fi
echo '{"type":"result","subtype":"success","total_cost_usd":0.01}'
FAKE
chmod +x "$FAKEBIN/claude-pages"
export PAGE_LOG="$ROOT/page-calls.log" PAGE_FIX="$ROOT/page-fix"
PAGE_Q="(project = ABC) AND updated >= -60m"
# page_setup <dir>: a first page, saved as too large, that names token t2.
page_setup() {
	rm -rf "$1" "$PAGE_FIX"
	mkdir -p "$1/F-tickets-spill" "$PAGE_FIX"
	: > "$PAGE_LOG"
	issue ABC-1 "To Do" "[]" | jq -cs '{issues: ., nextPageToken: "t2", isLast: false}' > "$1/F-tickets-spill/saved.txt"
	jq -cn --arg q "$PAGE_Q" '{type:"tool_use", id:"u1", name:"mcp__tickets__search", input:{jql:$q, cloudId:"site", maxResults:100}}' > "$1/F-tickets-tool-uses.jsonl"
	jq -cn '{type:"tool_result", tool_use_id:"u1", content:"Output too large. Output has been saved to /somewhere/tool-results/saved.txt."}' > "$1/F-tickets-tool-results.jsonl"
}
page_page() { # token, then issue keys; a last page when $PAGE_NEXT is unset
	local tok="$1"; shift
	local k
	for k in "$@"; do issue "$k" "To Do" "[]"; done | jq -cs --arg n "${PAGE_NEXT:-}" \
		'{issues: .} + (if $n == "" then {isLast: true} else {nextPageToken: $n, isLast: false} end)' > "$PAGE_FIX/$tok.json"
}
page_keys() { # dir
	local cfg
	cfg="$(desk_ticket_digest_config "$CFG_STEP" "$CONFIG")"
	jq -cn --arg q "$PAGE_Q" --argjson s "$NOW" '{since: $s, now: $s, jql: $q}' > "$1/F-tickets-ticket-digest-window.jsonl"
	echo '[]' > "$FIX/prs.json"
	PASS_SCRATCH="$1" desk_ticket_digest_collect morning F-tickets "$cfg" mcp__tickets__search > /dev/null 2>&1
	jq -c '[.[].key] | sort' "$1/F-tickets-ticket-digest-issues.jsonl" 2> /dev/null || echo none
}
# page_run <dir>: the paging, its log in <dir>/page.log, under a watchdog
# of its own so a loop that never stops fails the test instead of hanging it.
page_run() {
	PASS_SCRATCH="$1" DESK_CLAUDE_BIN="$FAKEBIN/claude-pages" \
		desk_fetch_remaining_pages morning F-tickets mcp__tickets__search "$PAGE_Q" '{"id":"F-tickets","timeout":30}' 2> "$1/page.log" &
	local pid=$! dog rc
	( sleep 60; kill "$pid" 2> /dev/null ) &
	dog=$!
	wait "$pid"
	rc=$?
	kill "$dog" 2> /dev/null
	wait "$dog" 2> /dev/null
	[ "$rc" -eq 0 ] || bad "the paging ended by its watchdog or an error (status $rc)"
}

D="$ROOT/pages-a"
page_setup "$D"
PAGE_NEXT=t3 page_page t2 ABC-2
touch "$PAGE_FIX/t2.spill"
page_page t3 ABC-3
page_run "$D"
assert_eq "two more pages fetched, each with the token the last one gave" '["t2","t3"]' "$(jq -cs '[.[].nextPageToken]' "$PAGE_LOG")"
assert_eq "with the first call's own arguments" '["site"]' "$(jq -cs '[.[].cloudId] | unique' "$PAGE_LOG")"
assert_eq "a later page saved as too large is read too, and the digest comes back whole" '["ABC-1","ABC-2","ABC-3"]' "$(page_keys "$D")"

D="$ROOT/pages-b"
page_setup "$D"
PAGE_NEXT=t3 page_page t2 ABC-2
PAGE_NEXT=t2 page_page t3 ABC-3
page_run "$D"
assert_eq "a token already followed, even two pages back, stops the paging" '["t2","t3"]' "$(jq -cs '[.[].nextPageToken]' "$PAGE_LOG")"
assert_eq "...and the search counts as not whole" "none" "$(page_keys "$D")"

D="$ROOT/pages-c"
page_setup "$D"
PAGE_NEXT=t3 page_page t2
page_run "$D"
assert_eq "an empty page that still names a token stops the paging" '["t2"]' "$(jq -cs '[.[].nextPageToken]' "$PAGE_LOG")"

D="$ROOT/pages-e"
page_setup "$D"
PAGE_NEXT=t3 page_page t2 ABC-1
page_page t3 ABC-3
page_run "$D"
assert_eq "a page holding only tickets an earlier page held stops the paging, whatever its token" '["t2"]' "$(jq -cs '[.[].nextPageToken]' "$PAGE_LOG")"
assert_eq "...and the search counts as not whole" "none" "$(page_keys "$D")"

D="$ROOT/pages-f"
page_setup "$D"
jq -cn '{issues: []}' > "$D/F-tickets-spill/saved.txt"
page_run "$D"
assert_eq "an empty page naming no token is the end, not a page that says more follow" "0:false" \
	"$(wc -l < "$PAGE_LOG" | tr -d ' '):$(grep -q 'came back empty' "$D/page.log" && echo true || echo false)"

D="$ROOT/pages-d"
page_setup "$D"
page_page t2 ABC-2
PASS_SCRATCH="$D" DESK_DENY_HOOK_SCRIPT="$ROOT/no-such-hook.sh" DESK_CLAUDE_BIN="$FAKEBIN/claude-pages" \
	desk_fetch_remaining_pages morning F-tickets mcp__tickets__search "$PAGE_Q" '{"id":"F-tickets","timeout":30}' 2> /dev/null
assert_eq "a missing deny hook makes no unpinned call" "0" "$(wc -l < "$PAGE_LOG" | tr -d ' ')"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
