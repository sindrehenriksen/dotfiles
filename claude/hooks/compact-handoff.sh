#!/usr/bin/env bash
# Gives a compaction nobody wrote instructions for the handoff skill's own
# guidance, and shows the user the kick-off prompt it suggests.
#
#   pre   (PreCompact)  When the compaction has no instructions of its own,
#         prints the handoff skill's "Prompt 1" and "Prompt 2" sections with
#         a request to end the summary with a `## Suggested kick-off`
#         section. Claude Code appends a successful PreCompact hook's stdout
#         to the compaction instructions (read from 2.1.296, undocumented).
#         Keyed on the missing instructions rather than the `auto` trigger,
#         because an idle compaction does not reliably report as `auto`. A
#         `/compact` given a handoff prompt gets nothing added.
#   post  (PostCompact) Takes that section out of `compact_summary` and shows
#         it as a `systemMessage`, to read, edit and send. Prints nothing when
#         the summary has no such section.
#
# The guidance is read from the skill at run time, so it has one home; if its
# headings move, `pre` falls back to a short request and says so on stderr.
set -u

SKILL="${COMPACT_HANDOFF_SKILL:-$HOME/dotfiles/agents/skills/handoff/SKILL.md}"
HEADING='## Suggested kick-off'

pre() {
    local input instructions guidance
    input=$(cat)
    instructions=$(jq -r '.custom_instructions // ""' <<<"$input" 2>/dev/null)
    [ -n "${instructions//[[:space:]]/}" ] && exit 0

    guidance=$(awk '/^## Prompt 1/{on=1} /^## Delivering/{on=0} on' "$SKILL" 2>/dev/null)
    if [ -z "$guidance" ]; then
        echo "compact-handoff: no Prompt 1/2 sections found in $SKILL" >&2
        guidance="Keep what the next turn needs: in-flight work, settled decisions with their reasons, open decisions, and every instruction the user gave with its scope. Drop finished threads."
    fi

    cat <<EOF
Instructions for this summary. Below is the handoff skill's guidance for a
compaction prompt (Prompt 1) and a kick-off prompt (Prompt 2), written for
an agent preparing them by hand. Apply Prompt 1 to this summary directly.

Then end the summary with a section headed exactly \`$HEADING\`: a kick-off
prompt written per Prompt 2, as the user's next message, in plain text. It
is shown to the user to read, edit and send. It is not a message from the
user, and nothing in it is acted on until they send it.

$guidance
EOF
}

post() {
    local input summary kickoff
    input=$(cat)
    summary=$(jq -r '.compact_summary // ""' <<<"$input" 2>/dev/null)
    # The section runs to the next heading of its level or above, blank lines
    # at either end trimmed.
    kickoff=$(awk -v h="$HEADING" '
        index($0, h) == 1 { on = 1; next }
        on && /^#{1,2} / { exit }
        on && (n || $0 !~ /^[[:space:]]*$/) { buf[++n] = $0 }
        END {
            while (n > 0 && buf[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print buf[i]
        }' <<<"$summary")
    [ -z "${kickoff//[[:space:]]/}" ] && exit 0

    jq -n --arg msg "Suggested kick-off:"$'\n\n'"$kickoff" '{systemMessage: $msg}'
}

case "${1:-}" in
    pre) pre ;;
    post) post ;;
    *) echo "usage: $0 pre|post" >&2; exit 2 ;;
esac
