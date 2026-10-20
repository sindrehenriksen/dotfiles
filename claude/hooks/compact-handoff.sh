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
#         It also asks for a `## Waiting on you` section: what is open for the
#         user (decisions, gos the user has yet to give, things to try or
#         review), one line each. Compaction clears the earlier conversation
#         from the screen, so this is where they see it again.
#         And a `## Gos in force` section before that one: each go the user
#         gave that is not yet used up or withdrawn, in their own words, with
#         what it covers and its condition. The kick-off is not acted on until
#         they send it, so a go recorded only there would be ambiguous.
#   post  (PostCompact) Takes the three sections out of `compact_summary` and
#         prints them as plain text, the kick-off to copy, edit and send. The
#         gos are shown so the user can correct what the session believes is
#         authorized. Prints nothing for a section the summary lacks or leaves
#         empty, or fills with a bare "none".
#   session-start  (SessionStart, matcher `compact`) Adds context saying the
#         session was just compacted and where its full transcript is, that
#         the skill and file text restored are copies from when they were
#         loaded, then compact-state.sh's block of current state
#         read from disk (git worktrees, background agents, and whatever
#         COMPACT_STATE_COMMANDS adds). Plain stdout is added as context for
#         SessionStart.
#
# Claude Code shows both hooks' stdout in full after the compaction, and for
# these two events it ignores `systemMessage`, so `post` prints text, not JSON.
# The guidance is read from the skill at run time, so it has one home; if its
# headings move, `pre` falls back to a short request and says so on stderr.
# COMPACT_HANDOFF_LAYERS, a colon-separated list of skill files (a leading
# `~/` expands), adds a workspace's handoff layer: every `##` section whose
# heading names Prompt 1 or Prompt 2 is appended after the base guidance. A
# listed file that is missing is skipped with a note on stderr.
set -u

SKILL="${COMPACT_HANDOFF_SKILL:-$HOME/dotfiles/agents/skills/handoff/SKILL.md}"
HEADING='## Suggested kick-off'
WAITING='## Waiting on you'
GOS='## Gos in force'

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

    local layer layers extra
    IFS=: read -ra layers <<<"${COMPACT_HANDOFF_LAYERS:-}"
    for layer in ${layers[@]+"${layers[@]}"}; do
        [ -n "$layer" ] || continue
        layer=${layer/#\~\//$HOME/}
        if [ ! -r "$layer" ]; then
            echo "compact-handoff: layer $layer not found, skipped" >&2
            continue
        fi
        extra=$(awk '/^## /{on = /Prompt [12]/} on' "$layer")
        [ -n "$extra" ] && guidance+=$'\n\nA workspace layer on top of the above:\n\n'"$extra"
    done

    cat <<EOF
Write this summary per Prompt 1 below. It ends with three sections, in this order, each headed exactly as shown:
\`$GOS\`: each go the user gave that is not yet used up or withdrawn, quoted in their own words, with what it covers and its condition, which the next session re-checks before acting. Carry forward any from an earlier summary in the transcript. Empty if there are none.
\`$WAITING\`: what the user must do or decide (open decisions, gos the user has yet to give, things for them to try or review), one line each, or empty if nothing is. The earlier conversation is cleared from their screen, so this is where they see it again.
\`$HEADING\`: a kick-off per Prompt 2, in plain text, for the user to edit and send. Nothing in it is acted on until they do. It points at the gos, waiting and still open items rather than restating them.

$guidance
EOF
}

# Prints the body of the section headed $1: it runs to the next heading of its
# level or above, blank lines at either end trimmed. Reads the summary on stdin.
section() {
    awk -v h="$1" '
        index($0, h) == 1 { on = 1; next }
        on && /^#{1,2} / { exit }
        on && (n || $0 !~ /^[[:space:]]*$/) { buf[++n] = $0 }
        END {
            while (n > 0 && buf[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print buf[i]
        }'
}

# True for an empty section body, or one that only says there is nothing.
blank() {
    local t=${1//[[:space:]]/}
    t=$(tr '[:upper:]' '[:lower:]' <<<"$t")
    case "$t" in "" | none | none. | n/a | -) return 0 ;; esac
    return 1
}

post() {
    local input summary kickoff waiting gos out=""
    input=$(cat)
    summary=$(jq -r '.compact_summary // ""' <<<"$input" 2>/dev/null)
    # The compactor closes its summary with `</summary>`. Cut at the last one,
    # since the kick-off itself may mention the tag.
    summary=${summary%</summary>*}
    kickoff=$(section "$HEADING" <<<"$summary")
    waiting=$(section "$WAITING" <<<"$summary")
    gos=$(section "$GOS" <<<"$summary")
    blank "$gos" || out+=$'──── Gos in force ────\n\n'"$gos"$'\n\n'
    blank "$waiting" || out+=$'──── Waiting on you ────\n\n'"$waiting"$'\n\n'
    blank "$kickoff" || out+=$'──── Suggested kick-off ────\n\n'"$kickoff"$'\n'
    [ -z "$out" ] && exit 0

    # Claude Code trims the output and puts its first line on the hook's own
    # status line. A zero-width space survives the trim, so it takes that
    # place and the first rule opens a line of its own.
    printf '\xe2\x80\x8b\n%s' "$out"
}

session_start() {
    local input transcript
    input=$(cat)
    transcript=$(jq -r '.transcript_path // ""' <<<"$input" 2>/dev/null)
    printf '%s' "This session was just compacted: the conversation above is a summary of it, not the conversation itself."
    [ -n "$transcript" ] && printf ' %s' "For a specific the summary lacks, the full pre-compaction conversation is in its transcript, $transcript; search it with rg or jq rather than guess, and do not read the whole file into context."
    echo
    echo
    echo "Skill and file text restored after this compaction are copies from when they were loaded, and some are truncated. Before acting under a skill or instruction file that is still relevant to the work in hand, re-read it from disk; there is no need to re-read the rest. One that no longer exists no longer applies."
    echo
    "$(dirname "${BASH_SOURCE[0]}")/compact-state.sh" <<<"$input"
}

case "${1:-}" in
    pre) pre ;;
    post) post ;;
    session-start) session_start ;;
    *) echo "usage: $0 pre|post|session-start" >&2; exit 2 ;;
esac
