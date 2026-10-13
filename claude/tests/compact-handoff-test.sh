#!/usr/bin/env bash
# Exercises claude/hooks/compact-handoff.sh against invented hook input and a
# fixture skill.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/compact-handoff.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/skill.md" <<'EOF'
# Handoff
## Prompt 1 — what goes with `/compact`
keep-list guidance
## Prompt 2 — the kick-off
kick-off guidance
## Delivering
fence guidance
EOF
export COMPACT_HANDOFF_SKILL="$TMP/skill.md"

out=$(echo '{"trigger":"auto","custom_instructions":null}' | "$HOOK" pre)
check "pre: carries both prompt sections" '[[ $out == *"keep-list guidance"* && $out == *"kick-off guidance"* ]]'
check "pre: stops before Delivering" '[[ $out != *"fence guidance"* ]]'
check "pre: asks for the kick-off section" '[[ $out == *"## Suggested kick-off"* ]]'
check "pre: asks for the waiting-on-you section" '[[ $out == *"## Waiting on you"* ]]'
check "pre: keeps the kick-off from restating it" '[[ $out == *"does not restate those items"* ]]'

out=$(echo '{"trigger":"manual","custom_instructions":"handoff prompt"}' | "$HOOK" pre)
check "pre: adds nothing to given instructions" '[ -z "$out" ]'

out=$(echo '{"trigger":"manual","custom_instructions":""}' | "$HOOK" pre)
check "pre: a bare /compact gets the guidance" '[[ $out == *"keep-list guidance"* ]]'

out=$(echo '{"custom_instructions":null}' | COMPACT_HANDOFF_SKILL="$TMP/missing.md" "$HOOK" pre 2>/dev/null)
check "pre: falls back when the skill is missing" '[[ $out == *"with its scope"* ]]'

cat >"$TMP/layer.md" <<'EOF'
# Workspace handoff
## What the pre-check adds here
precheck text
## What Prompt 1 must carry
layer keep-list
## What Prompt 2 must carry
layer kick-off
## Unrelated
other text
EOF
out=$(echo '{"custom_instructions":null}' | COMPACT_HANDOFF_LAYERS="$TMP/missing.md:$TMP/layer.md" "$HOOK" pre 2>/dev/null)
check "pre: appends a layer's prompt sections" '[[ $out == *"layer keep-list"* && $out == *"layer kick-off"* && $out == *"keep-list guidance"* ]]'
check "pre: leaves a layer's other sections out" '[[ $out != *"precheck text"* && $out != *"other text"* ]]'
mkdir -p "$TMP/home" && cp "$TMP/layer.md" "$TMP/home/layer.md"
out=$(echo '{"custom_instructions":null}' | HOME="$TMP/home" COMPACT_HANDOFF_LAYERS="~/layer.md" "$HOOK" pre 2>/dev/null)
check "pre: expands a leading ~/ in a layer path" '[[ $out == *"layer keep-list"* ]]'

summary=$'## Summary\nwork\n\n## Suggested kick-off\n\nContinue the sweep.\nAsk before pushing.\n\n'
out=$(jq -n --arg s "$summary" '{session_id:"s1",compact_summary:$s}' | "$HOOK" post)
check "post: shows the kick-off as text" '[[ $out == *$'"'"'Continue the sweep.\nAsk before pushing.'"'"' ]]'
check "post: the rule opens its own line" '[ "$(sed -n 2p <<<"$out")" = "──── Suggested kick-off ────" ]'

summary=$'## Suggested kick-off\nFirst.\n## Later section\nnot this'
out=$(jq -n --arg s "$summary" '{session_id:"s2",compact_summary:$s}' | "$HOOK" post)
check "post: stops at the next heading" '[ "$(tail -1 <<<"$out")" = "First." ]'

summary=$'## Suggested kick-off\nNo trailing </summary> tag?\nLast.\n</summary>'
out=$(jq -n --arg s "$summary" '{session_id:"s4",compact_summary:$s}' | "$HOOK" post)
check "post: stops at the closing summary tag" '[ "$(tail -1 <<<"$out")" = "Last." ]'
check "post: keeps a mention of the tag" '[[ $out == *"No trailing </summary> tag?"* ]]'

summary=$'## Suggested kick-off\nLast.</summary>'
out=$(jq -n --arg s "$summary" '{session_id:"s5",compact_summary:$s}' | "$HOOK" post)
check "post: stops at a tag ending a line" '[ "$(tail -1 <<<"$out")" = "Last." ]'

summary=$'## Summary\nwork\n\n## Waiting on you\n\n- Decide X.\n- Try Y.\n\n## Suggested kick-off\n\nGo on.\n'
out=$(jq -n --arg s "$summary" '{session_id:"w1",compact_summary:$s}' | "$HOOK" post)
check "post: shows what waits on the user" '[[ $out == *$'"'"'──── Waiting on you ────\n\n- Decide X.\n- Try Y.\n\n──── Suggested kick-off ────\n\nGo on.'"'"' ]]'
check "post: first line is the zero-width space" '[ "$(head -1 <<<"$out")" = $'"'"'\xe2\x80\x8b'"'"' ]'

summary=$'## Waiting on you\n\n## Suggested kick-off\nGo on.'
out=$(jq -n --arg s "$summary" '{session_id:"w2",compact_summary:$s}' | "$HOOK" post)
check "post: an empty waiting section is left out" '[[ $out != *"Waiting on you"* && $out == *"Go on."* ]]'

summary=$'## Waiting on you\n- Approve the merge.'
out=$(jq -n --arg s "$summary" '{session_id:"w3",compact_summary:$s}' | "$HOOK" post)
check "post: waiting without a kick-off still shows" '[[ $out == *"Approve the merge."* && $out != *"Suggested kick-off"* ]]'

out=$(echo '{"hook_event_name":"SessionStart","source":"compact"}' | "$HOOK" session-start)
check "session-start: says to re-read what is relevant from disk" '[[ $out == *"still relevant to the work in hand, re-read it from disk"* ]]'
check "session-start: is plain text" '[[ $out != "{"* ]]'
check "settings: the compact matcher runs session-start" '[ "$(jq -r '"'"'.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command'"'"' "$HERE/../settings.json")" = "\$HOME/dotfiles/claude/hooks/compact-handoff.sh session-start" ]'

# --- the state block (compact-state.sh) ---
STATE="$HERE/../hooks/compact-state.sh"
# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$TMP"
R=$(cd -P "$TMP" && pwd)
g() { git -C "$@" >/dev/null 2>&1; }

git init -q --bare "$R/remote.git"
git init -q "$R/repo"
g "$R/repo" commit -q --allow-empty -m one
g "$R/repo" remote add origin "$R/remote.git"
g "$R/repo" push -q -u origin main
g "$R/repo" worktree add -q -b feature "$R/repo-feature"
g "$R/repo-feature" push -q -u origin feature
g "$R/repo-feature" commit -q --allow-empty -m unpushed
g "$R/repo" worktree add -q -b local-only "$R/repo-local"
g "$R/repo-local" commit -q --allow-empty -m mine
g "$R/repo-local" commit -q --allow-empty -m mine-too
touch "$R/repo/untracked.txt"

g "$R/repo" worktree add -q -b untouched "$R/repo-untouched"
touch "$R/repo-untouched/dirty.txt"

# The transcript names worktrees as an absolute path inside one, under `~/`,
# and with a trailing slash; HOME is $R so all three count.
T="$R/t.jsonl"
jq -nc --arg a "$R/repo-feature/src/x.py" --arg c "$R/repo/" \
    '{type:"assistant",message:{content:[{type:"tool_use",name:"Read",input:{file_path:$a}},{type:"text",text:("see ~/repo-local. and " + $c)}]}}' >"$T"
state() { jq -n --arg cwd "$1" --arg t "${2:-}" '{session_id:"none",cwd:$cwd,transcript_path:$t}' | HOME=$R "$STATE"; }
out=$(state "$R/repo-feature" "$T")
check "state: counts the worktrees the transcript names" '[[ $out == *"Worktrees this session has worked in (3; read from the paths in its transcript):"* ]]'
check "state: the cwd's worktree comes first" '[ "$(sed -n 3p <<<"$out")" = "  ~/repo-feature  [feature]  ← cwd, 1 commit not on origin/feature" ]'
check "state: a dirty worktree says so" '[[ $out == *"  ~/repo  [main]  dirty: 1 file"$'"'"'\n'"'"'* ]]'
check "state: a ~/ path with a full stop finds its worktree" '[[ $out == *"  ~/repo-local  [local-only]  2 commits on no remote"* ]]'
check "state: leaves out a worktree the transcript never names" '[[ $out != *"repo-untouched"* ]]'
check "state: a clean, pushed worktree has no note" '[[ $out != *"[main]  "*"not on"* ]]'
out=$(state "$R/repo-untouched" "$T")
check "state: the cwd's worktree counts without a mention" 'grep -qxF "  ~/repo-untouched  [untouched]  ← cwd, dirty: 1 file" <<<"$out"'

: >"$R/many.jsonl"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    g "$R/repo" worktree add -q -b "wt$n" "$R/wt$n"
    echo "\"$R/wt$n\"" >>"$R/many.jsonl"
done
out=$(state "$R" "$R/many.jsonl")
check "state: lists every named worktree, with no cap" '[ "$(grep -c "^  ~/wt" <<<"$out")" -eq 12 ]'

g "$R/repo" worktree add -q -b broken "$R/broken"
g "$R/broken" push -q -u origin broken
echo "gitdir: $R/nowhere" >"$R/broken/.git"
echo "$R/broken" >"$R/broken.jsonl"
out=$(state "$R" "$R/broken.jsonl")
check "state: a worktree whose status fails says so" '[[ $out == *"  ~/broken  status failed: "* ]]'
rm -rf "$R/broken" && g "$R/repo" worktree prune

out=$(state "$R")
check "state: says when there is no worktree to show" '[[ $out == *"Worktrees: ~ is not in a git repository, and the transcript names no other."* ]]'
out=$(echo 'not json' | "$STATE"; echo "rc=$?")
check "state: bad input still exits 0" '[[ $out == *"rc=0" ]]'

mkdir -p "$R/bin"
printf '#!/bin/sh\necho "$$" > "%s/slow.pid"\nexec sleep 30\n' "$R" >"$R/bin/slow.sh"
printf '#!/bin/sh\necho partial\necho boom >&2\nexit 3\n' >"$R/bin/fail.sh"
printf '#!/bin/sh\necho "session $COMPACT_STATE_SESSION_ID in $COMPACT_STATE_CWD"\n' >"$R/bin/good.sh"
printf '#!/bin/sh\nseq 1 300\n' >"$R/bin/long.sh"
chmod +x "$R"/bin/*.sh
start=$SECONDS
out=$(COMPACT_STATE_TIMEOUT=1 COMPACT_STATE_COMMANDS="$R/bin/slow.sh:$R/bin/fail.sh:$R/bin/good.sh:$R/bin/missing.sh" state "$R/repo")
took=$((SECONDS - start))
check "commands: one still running at the failsafe is killed and named" '[[ $out == *"(~/bin/slow.sh killed: still running after 1s.)"* ]]'
check "commands: the failsafe holds the hook to its limit" '[ "$took" -le 3 ]'
sleep 0.2
check "commands: the slow one is killed" '! kill -0 "$(cat "$R/slow.pid")" 2>/dev/null'
check "commands: a failing one is named with its exit and stderr" '[[ $out == *$'"'"'partial\n'"'"'"(~/bin/fail.sh failed, exit 3: boom)"* ]]'
check "commands: get the hook input in the environment" '[[ $out == *"session none in $R/repo"* ]]'
check "commands: a missing one is named, not fatal" '[[ $out == *"(~/bin/missing.sh failed, exit 127"* ]]'
check "commands: run after the git block" '[[ ${out%%session none*} == *"Worktrees this session"* ]]'
out=$(COMPACT_STATE_COMMANDS="~/bin/good.sh" state "$R/repo")
check "commands: a leading ~/ expands" '[[ $out == *"session none in"* ]]'
out=$(COMPACT_STATE_COMMANDS="$R/bin/long.sh" state "$R/repo")
check "commands: output is kept in full" '[[ $out == *$'"'"'\n299\n300'"'"'* && $out != *"cut"* ]]'
check "settings: the hook timeout exceeds the failsafe" '[ "$(jq '"'"'.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].timeout'"'"' "$HERE/../settings.json")" -gt "$(sed -n '"'"'s/^TIMEOUT="\${COMPACT_STATE_TIMEOUT:-\([0-9]*\)}"$/\1/p'"'"' "$STATE")" ]'

# Background agents: an invented session in an invented config dir, with a
# process record naming this shell, which is an ancestor of the hook.
C="$R/config"
sid=sess-1
mkdir -p "$C/projects/p/$sid/subagents" "$C/sessions"
meta() { jq -n --arg tu "$2" --arg shape "$3" --arg d "$4" '{agentType:"general-purpose",description:$d,toolUseId:$tu,requestShape:$shape}' >"$C/projects/p/$sid/subagents/agent-$1.meta.json"; touch "$C/projects/p/$sid/subagents/agent-$1.jsonl"; }
meta adone tu-done background "finished one"
meta arun tu-run background "still running"
meta aresumed tu-resumed background "resumed one"
meta aold tu-old background "from an earlier process"
meta afg tu-fg none "foreground one"
jq -n --arg s "$sid" '{sessionId:"other"}' >"$C/sessions/999999.json"
launch() { jq -nc --arg tu "$1" --arg ts "$2" '{type:"assistant",timestamp:$ts,message:{content:[{type:"tool_use",name:"Agent",id:$tu,input:{}}]}}'; }
note() { jq -nc --arg id "$1" '{type:"queue-operation",operation:"enqueue",timestamp:"2026-01-01T10:00:00Z",content:("<task-notification>\n<task-id>" + $id + "</task-id>\n<status>completed</status>\n</task-notification>")}'; }
{
    launch tu-old 2026-01-01T08:00:00.000Z
    launch tu-done 2026-01-01T09:00:00.500Z
    launch tu-run 2026-01-01T09:00:01Z
    launch tu-resumed 2026-01-01T09:00:02Z
    launch tu-fg 2026-01-01T09:00:03Z
    note adone
    note aresumed
    # A queued message quoting a notification is not one.
    jq -nc '{type:"queue-operation",operation:"enqueue",content:"about <task-notification>\n<task-id>arun</task-id>"}'
    jq -nc '{type:"assistant",timestamp:"2026-01-01T09:30:00Z",message:{content:[{type:"tool_use",name:"SendMessage",id:"tu-send",input:{to:"aresumed",message:"more"}}]}}'
    printf '{"type":"assistant","truncat'
} >"$C/projects/p/$sid.jsonl"
started=$(( $(jq -n '"2026-01-01T08:30:00Z" | fromdateiso8601') * 1000 ))
jq -n --arg s "$sid" --argjson t "$started" '{sessionId:$s,startedAt:$t}' >"$C/sessions/$$.json"
agents() { jq -n --arg t "$C/projects/p/$sid.jsonl" --arg s "$sid" --arg cwd "$R" '{session_id:$s,transcript_path:$t,cwd:$cwd}' | "$STATE"; }
out=$(agents)
check "agents: lists one launched with no notice since" '[[ $out == *"  arun  still running, last wrote 0m ago"* ]]'
check "agents: lists one resumed after its notice" '[[ $out == *"  aresumed  resumed one"* ]]'
check "agents: leaves out one that reported back" '[[ $out != *"finished one"* ]]'
check "agents: leaves out one from an earlier process" '[[ $out != *"earlier process"* ]]'
check "agents: leaves out foreground agents" '[[ $out != *"foreground one"* ]]'
check "agents: counts what it lists" '[[ $out == *"have not reported back (2;"* ]]'
{ sed '$d' "$C/projects/p/$sid.jsonl"; echo; note arun; jq -nc '{type:"queue-operation",operation:"enqueue",content:"<task-notification>\n<task-id>aresumed</task-id>"}'; } >"$C/projects/p/$sid.jsonl.tmp" && mv "$C/projects/p/$sid.jsonl.tmp" "$C/projects/p/$sid.jsonl"
out=$(agents)
check "agents: says none are left once all reported" '[[ $out == *"Background agents started from this session: none still running."* ]]'
rm "$C/sessions/$$.json"
out=$(agents)
check "agents: says so when it cannot find the process" '[[ $out == *"Background agents: not read (no live Claude Code process record for this session)."* ]]'

out=$(jq -n --arg cwd "$R/repo" --arg t "$T" '{hook_event_name:"SessionStart",source:"compact",cwd:$cwd,transcript_path:$t}' | HOME=$R "$HOOK" session-start)
check "session-start: opens by saying the session was compacted" '[ "$(head -1 <<<"$out")" = "This session was just compacted: the conversation above is a summary of it, not the conversation itself. For a specific the summary lacks, the full pre-compaction conversation is in its transcript, $T; search it with rg or jq rather than guess, and do not read the whole file into context." ]'
check "session-start: appends the state block" '[[ $out == *"re-read it from disk"* && $out == *"Current state, read from disk at"* && $out == *"Worktrees this session has worked in"* ]]'
out=$(jq -n '{source:"compact"}' | HOME=$R "$HOOK" session-start)
check "session-start: without a transcript, names none" '[ "$(head -1 <<<"$out")" = "This session was just compacted: the conversation above is a summary of it, not the conversation itself." ]'

out=$(jq -n '{session_id:"s3",compact_summary:"## Summary\nno kick-off"}' | "$HOOK" post)
check "post: silent without a kick-off" '[ -z "$out" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
