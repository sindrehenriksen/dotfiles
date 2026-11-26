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
check "pre: asks for the gos-in-force section" '[[ $out == *"## Gos in force"* && $out == *"in their own words"* && $out == *"re-checks before acting"* ]]'
check "pre: puts the gos before what waits on the user" '[[ ${out%%"## Waiting on you"*} == *"## Gos in force"* && ${out%%"## Suggested kick-off"*} == *"## Waiting on you"* ]]'
check "pre: has the kick-off point at them" '[[ $out == *"rather than restating them"* ]]'

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

summary=$'## Gos in force\n\n- "merge once green": covers the PR; condition not met yet.\n\n## Waiting on you\n\n- Decide X.\n\n## Suggested kick-off\n\nGo on.\n'
out=$(jq -n --arg s "$summary" '{session_id:"g1",compact_summary:$s}' | "$HOOK" post)
check "post: shows the gos in force, ahead of what waits" '[[ $out == *$'"'"'──── Gos in force ────\n\n- "merge once green": covers the PR; condition not met yet.\n\n──── Waiting on you ────\n\n- Decide X.'"'"'* ]]'

summary=$'## Gos in force\n\n## Suggested kick-off\nGo on.'
out=$(jq -n --arg s "$summary" '{session_id:"g2",compact_summary:$s}' | "$HOOK" post)
check "post: an empty gos section is left out" '[[ $out != *"Gos in force"* && $out == *"Go on."* ]]'

summary=$'## Waiting on you\n- Decide X.\n\n## Suggested kick-off\nGo on.'
out=$(jq -n --arg s "$summary" '{session_id:"g3",compact_summary:$s}' | "$HOOK" post)
check "post: an absent gos section is left out" '[[ $out != *"Gos in force"* && $out == *"Decide X."* ]]'

summary=$'## Gos in force\n- Only a go.'
out=$(jq -n --arg s "$summary" '{session_id:"g4",compact_summary:$s}' | "$HOOK" post)
check "post: gos without a kick-off still show" '[[ $out == *"Only a go."* && $out != *"Suggested kick-off"* ]]'

summary=$'## Gos in force\n None.\n\n## Waiting on you\n-\n\n## Suggested kick-off\nN/A'
out=$(jq -n --arg s "$summary" '{session_id:"n1",compact_summary:$s}' | "$HOOK" post)
check "post: a bare none, dash or n/a counts as empty" '[ -z "$out" ]'

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

g "$R/repo" worktree add -q -b clean "$R/repo-clean"
g "$R/repo-clean" push -q -u origin clean

T="$R/t.jsonl"
: >"$T"
state() { jq -n --arg cwd "$1" '{session_id:"none",cwd:$cwd}' | HOME=$R "$STATE"; }
out=$(state "$R/repo-feature")
check "state: counts the repo's worktrees" '[[ $out == *"Worktrees (4: the cwd'"'"'s repo'"'"'s, other sessions'"'"' included, and any other this session changed):"* ]]'
check "state: the cwd's worktree comes first" '[ "$(sed -n 3p <<<"$out")" = "  ~/repo-feature  [feature]  ← cwd, 1 commit not on origin/feature" ]'
check "state: a dirty worktree says so" 'grep -qxF "  ~/repo  [main]  dirty: 1 file" <<<"$out"'
check "state: commits on no remote are counted" 'grep -qxF "  ~/repo-local  [local-only]  2 commits on no remote" <<<"$out"'
check "state: a clean, pushed worktree has no note" 'grep -qxF "  ~/repo-clean  [clean]" <<<"$out"'
out=$(state "$R/repo/../repo-clean")
check "state: the cwd is marked however it is spelled" 'grep -qxF "  ~/repo-clean  [clean]  ← cwd" <<<"$out"'

g "$R/repo" worktree add -q -b broken "$R/broken"
echo "gitdir: $R/nowhere" >"$R/broken/.git"
out=$(state "$R/repo")
check "state: a worktree whose status fails says so" '[[ $out == *"  ~/broken  status failed: "* ]]'
rm -rf "$R/broken" && g "$R/repo" worktree prune
out=$(state "$R/repo")
check "state: a removed worktree is left out" '[[ $out != *"broken"* ]]'

out=$(state "$R")
check "state: says when the cwd is in no repo" '[[ $out == *"Worktrees: none (~ is not in a git repository, and the transcript shows none changed)."* ]]'
# A worktree of another repo that this session changed, through a
# subagent's Write and a `git -C` commit from the main transcript; a removed
# worktree inside that repo, and a read-only git -C, do not count.
git init -q "$R/other"
g "$R/other" commit -q --allow-empty -m other
g "$R/other" worktree add -q -b side "$R/other-side"
mkdir -p "$R/ct/subagents"
tool() { jq -nc --arg cwd "$1" --arg name "$2" --argjson input "$3" '{type:"assistant",cwd:$cwd,message:{content:[{type:"tool_use",name:$name,input:$input}]}}'; }
{
    tool "$R/repo" Bash '{"command":"git -C ~/other-side commit -q -m x"}'
    tool "$R/repo" Bash '{"command":"git -C ~/other log -1"}'
    tool "$R" Edit "$(jq -nc --arg p "$R/other/gone/f.txt" '{file_path:$p}')"
} >"$R/ct.jsonl"
tool "$R" Write "$(jq -nc --arg p "$R/other-side/new.txt" '{file_path:$p}')" >"$R/ct/subagents/agent-x.jsonl"
out=$(jq -n --arg cwd "$R/repo" --arg t "$R/ct.jsonl" '{session_id:"none",cwd:$cwd,transcript_path:$t}' | HOME=$R "$STATE")
check "state: a worktree this session changed in another repo is listed and marked" 'grep -qxF "  ~/other-side  [side]  changed by this session, 1 commit on no remote" <<<"$out" && [[ $out != *"~/other  ["* ]]'

out=$(echo 'not json' | "$STATE")
check "state: bad input still prints the block" '[[ $out == *"Current state, read from disk"* ]]'

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
check "commands: run after the git block" '[[ ${out%%session none*} == *"Worktrees ("* ]]'
out=$(COMPACT_STATE_COMMANDS="~/bin/good.sh" state "$R/repo")
check "commands: a leading ~/ expands" '[[ $out == *"session none in"* ]]'
out=$(COMPACT_STATE_COMMANDS="$R/bin/long.sh" state "$R/repo")
check "commands: output is kept in full" '[[ $out == *$'"'"'\n299\n300'"'"'* && $out != *"cut"* ]]'
check "settings: the hook timeout exceeds the failsafe" '[ "$(jq '"'"'.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].timeout'"'"' "$HERE/../settings.json")" -gt "$(sed -n '"'"'s/^TIMEOUT="\${COMPACT_STATE_TIMEOUT:-\([0-9]*\)}"$/\1/p'"'"' "$STATE")" ]'

# Background agents: an invented session whose process record names this
# shell, an ancestor of the hook. One launched and still out, one that
# reported back, and one launched before this process started.
C="$R/config"
sid=sess-1
mkdir -p "$C/projects/p/$sid/subagents" "$C/sessions"
for a in run:tu-run done:tu-done old:tu-old; do
    jq -n --arg tu "${a#*:}" --arg d "agent ${a%%:*}" '{description:$d,toolUseId:$tu,requestShape:"background"}' >"$C/projects/p/$sid/subagents/agent-${a%%:*}.meta.json"
done
launch() { jq -nc --arg tu "$1" --arg ts "$2" '{type:"assistant",timestamp:$ts,message:{content:[{type:"tool_use",name:"Agent",id:$tu,input:{}}]}}'; }
{
    launch tu-old 2026-01-01T08:00:00Z
    launch tu-run 2026-01-01T09:00:00Z
    launch tu-done 2026-01-01T09:00:01Z
    jq -nc '{type:"queue-operation",operation:"enqueue",content:"<task-notification>\n<task-id>done</task-id>\n</task-notification>"}'
} >"$C/projects/p/$sid.jsonl"
jq -n --arg s "$sid" --argjson t "$(( $(jq -n '"2026-01-01T08:30:00Z" | fromdateiso8601') * 1000 ))" '{sessionId:$s,startedAt:$t}' >"$C/sessions/$$.json"
out=$(jq -n --arg t "$C/projects/p/$sid.jsonl" --arg s "$sid" --arg cwd "$R" '{session_id:$s,transcript_path:$t,cwd:$cwd}' | "$STATE")
check "agents: lists only the one still out from this process" '[[ $out == *"have not reported back (1;"* && $out == *"  run  agent run"* && $out != *"agent done"* && $out != *"agent old"* ]]'
rm "$C/sessions/$$.json"

out=$(jq -n --arg cwd "$R/repo" --arg t "$T" '{hook_event_name:"SessionStart",source:"compact",cwd:$cwd,transcript_path:$t}' | HOME=$R "$HOOK" session-start)
check "session-start: opens by saying the session was compacted" '[ "$(head -1 <<<"$out")" = "This session was just compacted: the conversation above is a summary of it, not the conversation itself. For a specific the summary lacks, the full pre-compaction conversation is in its transcript, $T; search it with rg or jq rather than guess, and do not read the whole file into context." ]'
check "session-start: appends the state block" '[[ $out == *"re-read it from disk"* && $out == *"Current state, read from disk at"* && $out == *"Worktrees ("* ]]'
out=$(jq -n '{source:"compact"}' | HOME=$R "$HOOK" session-start)
check "session-start: without a transcript, names none" '[ "$(head -1 <<<"$out")" = "This session was just compacted: the conversation above is a summary of it, not the conversation itself." ]'

# Skills the transcript shows loaded and instruction files it shows read,
# checked against the disk. Files dated January are older than the February
# loads and reads; the rest are as new as this run.
S="$R/sk"
skill() { mkdir -p "$1" && echo "# skill" >"$1/SKILL.md"; }
old() { touch -t 202601010000 "$1/SKILL.md"; }
git init -q "$S/repo"
mkdir -p "$S/repo/sub" "$S/cfg/skills" "$S/elsewhere"
skill "$S/cfg/skills/kept" && old "$S/cfg/skills/kept"
skill "$S/cfg/skills/edited"
skill "$S/cfg/skills/reloaded"
skill "$S/cfg/skills/moved"
skill "$S/elsewhere/linked" && ln -s "$S/elsewhere/linked" "$S/cfg/skills/linked"
skill "$S/repo/.claude/skills/slashed"
skill "$S/repo/.claude/skills/proj" && old "$S/repo/.claude/skills/proj"
skill "$S/plugins/cache/p/skills/b"
skill "$S/elsewhere/reread" && ln -s "$S/elsewhere/reread" "$S/cfg/skills/reread"
mkdir -p "$S/repo/.claude/rules" "$S/repo/docs"
for f in AGENTS.md CLAUDE.md notes.md .claude/rules/r.md x.instructions.md; do echo text >"$S/repo/$f"; done
touch -t 202601010000 "$S/repo/CLAUDE.md"
echo text >"$S/cfg/skills/edited/ref.md"
use() { jq -nc --arg ts "$1" --arg n "$2" '{type:"assistant",timestamp:$ts,message:{content:[{type:"tool_use",name:"Skill",id:("tu-" + $n + $ts),input:{skill:$n}}]}}'; }
loaded() { jq -nc --arg ts "$1" --arg n "$2" --arg d "$3" '{type:"user",isMeta:true,timestamp:$ts,sourceToolUseID:("tu-" + $n + $ts),message:{content:[{type:"text",text:("Base directory for this skill: " + $d + "\n\n# skill")}]}}'; }
load() { use "$1" "$2"; loaded "$1" "$2" "$3"; }
slash() { jq -nc --arg ts "$1" --arg n "$2" '{type:"user",timestamp:$ts,message:{content:("<command-name>/" + $n + "</command-name>\n<command-args></command-args>")}}'; }
readres() { jq -nc --arg ts "$1" --arg p "$2" '{type:"user",timestamp:$ts,toolUseResult:{type:"text",file:{filePath:$p,content:"text"}},message:{content:[{type:"tool_result",content:"text"}]}}'; }
editres() { jq -nc --arg ts "$1" --arg p "$2" '{type:"user",timestamp:$ts,toolUseResult:{filePath:$p,oldString:"a",newString:"b"},message:{content:[{type:"tool_result",content:"done"}]}}'; }
feb=2026-02-01T10:00:00.123Z
{
    load $feb reread "$S/cfg/skills/reread"
    readres 2099-01-01T00:00:00.000Z "$S/elsewhere/reread/SKILL.md"
    readres $feb "$S/cfg/skills/edited/SKILL.md"
    readres $feb "$S/cfg/skills/edited/ref.md"
    readres $feb "$S/cfg/skills/gone/extra.md"
    readres $feb "$S/repo/AGENTS.md"
    readres $feb "$S/repo/CLAUDE.md"
    readres $feb "$S/repo/notes.md"
    readres $feb "$S/repo/docs/principles.md"
    readres $feb "$S/repo/.claude/rules/r.md"
    editres 2099-01-01T00:00:00.000Z "$S/repo/.claude/rules/r.md"
    editres $feb "$S/repo/x.instructions.md"
    load $feb kept "$S/cfg/skills/kept"
    load $feb edited "$S/cfg/skills/edited"
    load $feb gone "$S/cfg/skills/gone"
    load $feb moved "$S/old-home/moved"
    load $feb linked "$S/cfg/skills/linked"
    load $feb proj "$S/repo/.claude/skills/proj"
    load $feb reloaded "$S/cfg/skills/reloaded"
    load 2099-01-01T00:00:00.000Z reloaded "$S/cfg/skills/reloaded"
    load $feb p:b "$S/plugins/cache/p/skills/b"
    load $feb bundled-one "$S/bundled-skills/1.0/bundled-one"
    use $feb typo
    slash $feb slashed
    slash $feb login
    jq -nc --arg d "$S/cfg/skills/dropped" '{type:"attachment",timestamp:"2026-02-02T10:00:00.000Z",attachment:{type:"invoked_skills",skills:[
        {name:"dropped",path:"userSettings:dropped",content:("Base directory for this skill: " + $d + "\n\n# skill")},
        {name:"inbuilt",path:"bundled:inbuilt",content:"Base directory for this skill: /nowhere/inbuilt\n\n# skill"}]}}'
    jq -nc '{type:"user",timestamp:"2026-02-03T10:00:00.000Z",message:{content:[{type:"tool_result",content:"Base directory for this skill: /nowhere/quoted"}]}}'
    echo 'not json, but names Base directory for this skill: /nowhere/broken'
} >"$S/t.jsonl"
skills() { jq -n --arg cwd "$1" --arg t "$2" '{source:"compact",cwd:$cwd,transcript_path:$t}' | HOME=$R CLAUDE_CONFIG_DIR="$S/cfg" "$HOOK" session-start; }
out=$(skills "$S/repo/sub" "$S/t.jsonl")
check "skills: names the ones gone from disk, restored-only ones included" 'grep -qxF "  skill no longer exists, so ignore its restored text: gone, dropped" <<<"$out"'
changed=$(sed -n '/skill changed since loaded/,/file changed since/p' <<<"$out")
check "skills: one edited since its load is named with its path" 'grep -qxF "    edited  ~/sk/cfg/skills/edited/SKILL.md" <<<"$changed"'
check "skills: a symlinked skill is read through the link" 'grep -qxF "    linked  ~/sk/cfg/skills/linked/SKILL.md" <<<"$changed"'
check "skills: one gone from where it loaded is found where it loads from now" 'grep -qxF "    moved  ~/sk/cfg/skills/moved/SKILL.md" <<<"$changed"'
check "skills: a slash-command load resolves in a parent of the cwd" 'grep -qxF "    slashed  ~/sk/repo/.claude/skills/slashed/SKILL.md" <<<"$changed"'
check "skills: only those four have changed, one read under another path since among the rest" '[ "$(grep -c "SKILL.md" <<<"$changed")" -eq 4 ] && [[ $out != *reread* ]]'
check "skills: unchanged, reloaded, plugin, bundled, built-in and unresolved names are left out" '[[ $out != *kept* && $out != *proj* && $out != *reloaded* && $out != *p:b* && $out != *bundled-one* && $out != *inbuilt* && $out != *typo* && $out != *login* && $out != *quoted* && $out != *broken* ]]'
check "skills: the list sits between the note and the state block" '[[ ${out%%Of the skills*} == *"re-read it from disk"* && ${out##*Of the skills} == *"Current state, read from disk"* ]]'
files=$(sed -n '/file changed since last read, so re-read before relying on it:/,/^$/p' <<<"$out")
check "files: instruction files changed since their last read are named" '[ "$(sed 1d <<<"$files")" = "    ~/sk/cfg/skills/edited/ref.md
    ~/sk/repo/: AGENTS.md, x.instructions.md" ]'
check "files: a skill's SKILL.md read as a file is named once, as the skill" '[ "$(grep -c "edited/SKILL.md" <<<"$out")" -eq 1 ]'
check "files: unchanged, edited since, and other kinds of file are left out" '[[ $out != *CLAUDE.md* && $out != *rules/r.md* && $out != *notes.md* ]]'
check "files: one gone from disk is named, one in a gone skill is not" '[[ $out == *$'"'"'  file no longer exists, so ignore its restored text:\n    ~/sk/repo/docs/principles.md\n'"'"'* && $out != *extra.md* ]]'
mkdir -p "$S/repo/.agents"
for i in $(seq 1 17); do echo text >"$S/repo/.agents/n$i.md"; readres $feb "$S/repo/.agents/n$i.md"; done >"$S/many.jsonl"
out=$(skills "$S/repo" "$S/many.jsonl")
many=$(grep -F "/.agents/: " <<<"$out")
check "files: a long list names every file, those of one directory on one line" '[ "$(grep -c . <<<"$many")" -eq 1 ] && [ "$(grep -o "n[0-9]*\.md" <<<"$many" | sort -u | grep -c .)" -eq 17 ] && [[ $out != *" more"* ]]'
{ load $feb kept "$S/cfg/skills/kept"; slash $feb login; readres $feb "$S/repo/CLAUDE.md"; } >"$S/current.jsonl"
out=$(skills "$S/repo" "$S/current.jsonl")
check "skills: nothing is added when all are current" '[[ $out != *"Of the skills"* && $out == *"re-read it from disk"* ]]'

# idle-prompt: the same check on a prompt after a long idle. The fixtures
# above were last active in February, so they are idle; the same transcript
# with an assistant record from an hour ago is not.
idle() { jq -n --arg cwd "$1" --arg t "$2" '{hook_event_name:"UserPromptSubmit",prompt:"go on",cwd:$cwd,transcript_path:$t}' | HOME=$R CLAUDE_CONFIG_DIR="$S/cfg" "$HOOK" idle-prompt; }
ago() { jq -nr --argjson s "$1" '(now - $s) | todate'; }
assistant() { jq -nc --arg ts "$1" '{type:"assistant",timestamp:$ts,message:{content:[{type:"text",text:"done"}]}}'; }
{ cat "$S/t.jsonl"; assistant "$(ago 3600)"; } >"$S/recent.jsonl"
out=$(idle "$S/repo/sub" "$S/recent.jsonl")
check "idle-prompt: below the threshold, silent even with changes" '[ -z "$out" ]'
{ cat "$S/t.jsonl"; assistant "$(ago $((5 * 3600)))"; } >"$S/five.jsonl"
out=$(idle "$S/repo/sub" "$S/five.jsonl")
check "idle-prompt: above the threshold, a changed skill is named" 'grep -qxF "    edited  ~/sk/cfg/skills/edited/SKILL.md" <<<"$out" && [[ $out == *"skill changed since loaded, so re-read before acting under it:"* ]]'
check "idle-prompt: says how long it was idle, and not that it was compacted" '[[ $out == "This session'"'"'s previous turn ended about 5 hours ago"* && $out != *"compacted"* && $out != *"Current state"* ]]'
check "idle-prompt: a deleted skill is to be ignored" 'grep -qxF "  skill no longer exists, so ignore its restored text: gone, dropped" <<<"$out"'
out=$(COMPACT_HANDOFF_IDLE_HOURS=6 idle "$S/repo/sub" "$S/five.jsonl")
check "idle-prompt: the threshold is COMPACT_HANDOFF_IDLE_HOURS" '[ -z "$out" ]'
out=$(idle "$S/repo" "$S/current.jsonl")
check "idle-prompt: above the threshold with nothing changed, silent" '[ -z "$out" ]'
out=$(idle "$S/repo" "$S/missing.jsonl")
check "idle-prompt: no transcript, silent" '[ -z "$out" ]'
echo "not json" >"$S/junk.jsonl"
out=$(idle "$S/repo" "$S/junk.jsonl")
check "idle-prompt: no earlier turn in the transcript, silent" '[ -z "$out" ]'
out=$(jq -n --arg t "$S/five.jsonl" '{transcript_path:$t,agent_id:"a1"}' | HOME=$R CLAUDE_CONFIG_DIR="$S/cfg" "$HOOK" idle-prompt)
check "idle-prompt: a subagent gets nothing" '[ -z "$out" ]'

out=$(jq -n '{session_id:"s3",compact_summary:"## Summary\nno kick-off"}' | "$HOOK" post)
check "post: silent when the summary has none of the sections" '[ -z "$out" ]'

W='"agent_id":"a1","agent_type":"general-purpose"'
out=$(echo "{\"trigger\":\"auto\",\"custom_instructions\":null,$W}" | "$HOOK" pre)
check "subagent: pre prints nothing" '[ -z "$out" ]'
out=$(jq -n '{compact_summary:"## Suggested kick-off\nGo on.",agent_id:"a1"}' | "$HOOK" post)
check "subagent: post prints nothing" '[ -z "$out" ]'
out=$(echo "{\"source\":\"compact\",\"transcript_path\":\"/x\",$W}" | "$HOOK" session-start)
check "subagent: session-start prints only the worker note" '[[ $out == "Your context was just compacted"* && $out == *"ask the agent that started you"* && $out != *"Current state"* && $out != *"transcript"* ]]'
out=$(echo '{"trigger":"auto","custom_instructions":null,"agent_id":""}' | "$HOOK" pre)
check "subagent: an empty agent_id is the main session" '[[ $out == *"keep-list guidance"* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
