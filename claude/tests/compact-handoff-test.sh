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
check "session-start: says to re-read from disk" '[[ $out == *"re-read it from disk"* && $out == *"no longer exists no longer applies"* ]]'
check "session-start: limits re-reading to what is relevant" '[[ $out == *"still relevant to the work in hand"* ]]'
check "session-start: is plain text" '[[ $out != "{"* ]]'
check "settings: the compact matcher runs session-start" '[ "$(jq -r '"'"'.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[0].command'"'"' "$HERE/../settings.json")" = "\$HOME/dotfiles/claude/hooks/compact-handoff.sh session-start" ]'

out=$(jq -n '{session_id:"s3",compact_summary:"## Summary\nno kick-off"}' | "$HOOK" post)
check "post: silent without a kick-off" '[ -z "$out" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
