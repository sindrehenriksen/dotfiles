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
#         user (decisions, pending gos, things to try or review), one line
#         each. Compaction clears the earlier conversation from the screen, so
#         this is where they see it again.
#   post  (PostCompact) Takes both sections out of `compact_summary` and prints
#         them as plain text, the kick-off to copy, edit and send. Prints
#         nothing for a section the summary lacks or leaves empty.
#   session-start  (SessionStart, matcher `compact`) Adds context saying the
#         skill and file text restored after a compaction are copies from when
#         they were loaded. Plain stdout is added as context for SessionStart.
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
Write this summary per Prompt 1 below. End it with a section headed exactly \`$HEADING\`:
a kick-off per Prompt 2, in plain text, for the user to edit and send. Nothing in it is acted on until they do.
Before it, a section headed exactly \`$WAITING\`: what is waiting on the user (open decisions, pending gos, things for them to try or review), one line each, or empty if nothing is. The earlier conversation is cleared from their screen, so this is where they see it again.

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

post() {
    local input summary kickoff waiting out=""
    input=$(cat)
    summary=$(jq -r '.compact_summary // ""' <<<"$input" 2>/dev/null)
    # The compactor closes its summary with `</summary>`. Cut at the last one,
    # since the kick-off itself may mention the tag.
    summary=${summary%</summary>*}
    kickoff=$(section "$HEADING" <<<"$summary")
    waiting=$(section "$WAITING" <<<"$summary")
    [ -n "${waiting//[[:space:]]/}" ] && out+=$'──── Waiting on you ────\n\n'"$waiting"$'\n\n'
    [ -n "${kickoff//[[:space:]]/}" ] && out+=$'──── Suggested kick-off ────\n\n'"$kickoff"$'\n'
    [ -z "$out" ] && exit 0

    # Claude Code trims the output and puts its first line on the hook's own
    # status line. A zero-width space survives the trim, so it takes that
    # place and the first rule opens a line of its own.
    printf '\xe2\x80\x8b\n%s' "$out"
}

session_start() {
    cat >/dev/null
    echo "Skill and file text restored after this compaction are copies from when they were loaded, and some are truncated. Before acting under a skill or instruction file, re-read it from disk. One that no longer exists no longer applies."
}

case "${1:-}" in
    pre) pre ;;
    post) post ;;
    session-start) session_start ;;
    *) echo "usage: $0 pre|post|session-start" >&2; exit 2 ;;
esac
