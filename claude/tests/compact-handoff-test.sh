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

out=$(echo '{"trigger":"manual","custom_instructions":"handoff prompt"}' | "$HOOK" pre)
check "pre: adds nothing to given instructions" '[ -z "$out" ]'

out=$(echo '{"trigger":"manual","custom_instructions":""}' | "$HOOK" pre)
check "pre: a bare /compact gets the guidance" '[[ $out == *"keep-list guidance"* ]]'

out=$(echo '{"custom_instructions":null}' | COMPACT_HANDOFF_SKILL="$TMP/missing.md" "$HOOK" pre 2>/dev/null)
check "pre: falls back when the skill is missing" '[[ $out == *"with its scope"* ]]'

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

out=$(jq -n '{session_id:"s3",compact_summary:"## Summary\nno kick-off"}' | "$HOOK" post)
check "post: silent without a kick-off" '[ -z "$out" ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
