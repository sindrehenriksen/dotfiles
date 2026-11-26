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
#         loaded, which of the skills it loaded and the instruction files
#         it read are gone from disk or have changed since (named only when
#         some are; see stale_context), then compact-state.sh's block of
#         current state
#         read from disk (git worktrees, background agents, and whatever
#         COMPACT_STATE_COMMANDS adds). Plain stdout is added as context for
#         SessionStart.
#
#   idle-prompt  (UserPromptSubmit) For a session that sat idle without
#         compacting and so keeps acting on old skill text: when the previous
#         turn ended more than COMPACT_HANDOFF_IDLE_HOURS ago (default 4; the
#         time of the last assistant record in the transcript's tail), adds
#         the same stale_context block as `session-start`, and nothing
#         else. Prints nothing when it is not idle, when nothing has changed,
#         or when the transcript shows no earlier turn. Reads files only.
#
# For a subagent compacting (the hook input carries a non-empty `agent_id`,
# from Claude Code 2.1.323) there is no user to hand off to and the main
# session's state is not its own: `pre` and `post` print nothing, and
# `session-start` prints a short note for a worker instead of the above, with no
# state block. Input without `agent_id` is treated as the main session's.
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

# True when the hook input ($1) comes from a subagent compacting.
is_worker() {
    [ -n "$(jq -r '.agent_id // ""' <<<"$1" 2>/dev/null)" ]
}

pre() {
    local input instructions guidance
    input=$(cat)
    is_worker "$input" && exit 0
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
\`$HEADING\`: a kick-off per Prompt 2, in plain text, for the user to edit and send. Nothing in it is acted on until they do. It points at the gos and waiting items rather than restating them.

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
    is_worker "$input" && exit 0
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

# What counts as an instruction file: one a session acts under, so an old
# copy of it in context misleads. Each alternative matches the end of a path:
# AGENTS.md, CLAUDE.md, SKILL.md and principles.md anywhere, any file in a
# skill's directory, under `.claude/rules/` or under `.agents/`, and
# `*.instructions.md`. Used on raw transcript lines as well as on paths, so a
# path segment is written `[^"]`, never `.`.
INSTRUCTION_FILES='/(AGENTS|CLAUDE|SKILL|principles)\.md|/skills/[^/"]+/[^"]+|/\.claude/rules/[^"]+|/\.agents/[^"]+|\.instructions\.md'

# What a transcript shows the session loaded or read, one per line:
#   S, name, load time, directory   a skill. The time is epoch seconds, 0 when
#       unknown; the directory is where it was loaded from, empty when the
#       transcript does not say. A load is a Skill tool call, a slash command,
#       or the text Claude Code adds for either, which opens by naming the
#       skill's directory; the latest load of a name gives its time. The list
#       of restored skills a compaction records fills in a directory and marks
#       bundled skills, and gives no time. Plugin (`a:b`) and bundled skills
#       are left out.
#   F, path, time   an instruction file ($files) and when the session last saw
#       its content: the latest result of a Read, Edit or Write on it. The
#       result's time, not the call's, since an Edit lands after its call.
read -r -d '' SEEN_JQ <<'JQ'
def basedir: if startswith("Base directory for this skill: ")
    then split("\n")[0] | ltrimstr("Base directory for this skill: ") else "" end;
def later($t): if $t > (.t // 0) then .t = $t else . end;
reduce (inputs | fromjson? | select(type == "object" and .timestamp != null) | . as $e
    | ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0)) as $t
    | if .type == "assistant" then
        .message.content[]? | select(.type == "tool_use" and .name == "Skill")
        | {k: "use", t: $t, name: (.input.skill // ""), id: (.id // "")}
      elif .type == "user" then
        ((.message.content | if type == "string" then . else (.[]? | select(.type == "text") | .text) end)
         | if startswith("Base directory for this skill: ") then {k: "dir", t: $t, dir: basedir, id: ($e.sourceToolUseID // "")}
           elif test("^\\s*<command-name>/[^<]+</command-name>") then {k: "use", t: $t, name: capture("<command-name>/(?<n>[^<]+)</command-name>").n, id: ""}
           else empty end),
        (.toolUseResult | select(type == "object") | (.filePath // .file.filePath?)
         | select(type == "string" and test("(" + $files + ")$")) | {k: "file", t: $t, path: .})
      elif .type == "attachment" and .attachment.type == "invoked_skills" then
        .attachment.skills[]? | {k: "restored", name: (.name // ""), dir: ((.content // "") | basedir), bundled: ((.path // "") | startswith("bundled:"))}
      else empty end) as $ev ({ids: {}, s: {}, f: {}};
    if $ev.k == "use" then
        (if $ev.id != "" then .ids[$ev.id] = $ev.name else . end) | .s[$ev.name] |= later($ev.t)
    elif $ev.k == "dir" then
        (.ids[$ev.id] // ($ev.dir | sub("/+$"; "") | split("/") | last)) as $n
        | .s[$n] |= (later($ev.t) | .dir = $ev.dir)
    elif $ev.k == "file" then
        .f[$ev.path] |= later($ev.t)
    else
        .s[$ev.name] |= ((if $ev.dir != "" and .dir == null then .dir = $ev.dir else . end)
            | if $ev.bundled then .bundled = true else . end)
    end)
| (.s | to_entries[]
   | select((.key | test("^[A-Za-z0-9._-]+$")) and (.key | test("^\\.+$") | not) and (.value.bundled | not)
       and ((.value.dir // "") | test("/bundled-skills/|/plugins/") | not))
   | ["S", .key, (.value.t // 0), (.value.dir // "")]),
  (.f | to_entries[] | ["F", .key, .value.t])
| @tsv
JQ

file_mtime() { stat -L -c %Y "$1" 2>/dev/null || stat -L -f %m "$1" 2>/dev/null; }
tilde() { local p=$1; [[ $p == "$HOME"/* ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }
# The path of an existing file with symlinks resolved, so one file reached by
# two paths compares equal.
real_path() {
    realpath "$1" 2>/dev/null || (cd -P "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$1")")
}
# Prints the paths on stdin indented, every one of them: a path alone in its
# directory in full, several in one directory on one line, as
# `<directory>/: <name>, <name>`.
by_directory() {
    awk '{
            d = $0; sub(/\/[^\/]*$/, "", d); f = substr($0, length(d) + 2)
            if (!(d in names)) { order[++n] = d; names[d] = f } else { names[d] = names[d] ", " f; many[d] = 1 }
        }
        END { for (i = 1; i <= n; i++) { d = order[i]; print "    " d (d in many ? "/: " : "/") names[d] } }'
}

# Names what the transcript ($1) shows the session loaded or read that the
# disk no longer matches: skills, and instruction files (INSTRUCTION_FILES),
# that are gone or were modified after the session last saw them. A skill is
# seen at its load or at a later Read of its SKILL.md, a file at its last
# Read, Edit or Write. A skill is looked for where it was loaded from, then
# where Claude Code loads skills from: the config dir's `skills/` and
# `.claude/skills/` in the cwd ($2) and its parents up to the repo root,
# symlinks followed. Only a skill the transcript shows loaded from a directory
# is called gone, so a built-in command or a skill with no file is never
# reported. Prints nothing when all are current.
stale_context() {
    local transcript=$1 cwd=$2 seen kind a b c d f root parent m dirs=()
    local gone="" gone_dirs="" gone_files="" entries="" changed="" changed_files=""
    [ -f "$transcript" ] && [ -r "$transcript" ] || return 0
    # Only the lines that can hold a load or a read reach jq. rg where there
    # is one: grep takes seconds over a transcript of a few hundred megabytes.
    local pattern='"name": ?"Skill"|Base directory for this skill: |<command-name>/|invoked_skills|"filePath": ?"[^"]*('"$INSTRUCTION_FILES"')"'
    seen=$(if command -v rg >/dev/null 2>&1; then rg --no-config -N -e "$pattern" "$transcript"; else grep -E "$pattern" "$transcript"; fi 2>/dev/null |
        jq -n -R -r --arg files "$INSTRUCTION_FILES" "$SEEN_JQ" 2>/dev/null)
    [ -n "$seen" ] || return 0

    dirs+=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills")
    if d=$(cd -P "$cwd" 2>/dev/null && pwd); then
        root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
        while :; do
            dirs+=("$d/.claude/skills")
            [ -n "$root" ] && [ "$d" != "$root" ] || break
            parent=$(dirname "$d")
            [ "$parent" != "$d" ] || break
            d=$parent
        done
    fi

    # One line per file still on disk, keyed by its resolved path: when it was
    # seen, and the skill's name or `-` for a plain file. Skills come first.
    while IFS=$'\t' read -r kind a b c; do
        if [ "$kind" = S ]; then
            f=""
            for d in ${c:+"$c"} "${dirs[@]/%//$a}"; do
                [ -f "$d/SKILL.md" ] && { f="$d/SKILL.md"; break; }
            done
            if [ -n "$f" ]; then
                entries+="$(real_path "$f")"$'\t'"$b"$'\t'"$a"$'\t'"$f"$'\n'
            elif [ -n "$c" ]; then
                gone+="${gone:+, }$a"
                gone_dirs+="${c%/}/"$'\n'
            fi
        elif [ -e "$a" ]; then
            entries+="$(real_path "$a")"$'\t'"$b"$'\t-\t'"$a"$'\n'
        else
            # A file of a skill already named as gone is not named again.
            while IFS= read -r d; do
                [ -n "$d" ] && [[ $a == "$d"* ]] && continue 2
            done <<<"$gone_dirs"
            gone_files+="$(tilde "$a")"$'\n'
        fi
    done <<<"$seen"

    # Per file the latest time it was seen under any path, as a skill if it
    # was loaded as one.
    while IFS=$'\t' read -r f b a c; do
        [ -n "$f" ] && [ "$b" -gt 0 ] && m=$(file_mtime "$f") && [ "${m:-0}" -gt "$b" ] || continue
        if [ "$a" = - ]; then changed_files+="$(tilde "$c")"$'\n'; else changed+="    $a  $(tilde "$c")"$'\n'; fi
    done < <(printf '%s' "$entries" | awk -F'\t' '
        !($1 in t) { order[++n] = $1; t[$1] = $2; name[$1] = $3; shown[$1] = $4; next }
        { if ($2 > t[$1]) t[$1] = $2; if (name[$1] == "-" && $3 != "-") { name[$1] = $3; shown[$1] = $4 } }
        END { for (i = 1; i <= n; i++) { k = order[i]; printf "%s\t%s\t%s\t%s\n", k, t[k], name[k], shown[k] } }')

    [ -n "$gone$gone_files$changed$changed_files" ] || return 0
    echo "Of the skills and instruction files this session loaded or read, checked against the disk now:"
    [ -n "$gone" ] && echo "  skill no longer exists, so ignore its restored text: $gone"
    [ -n "$gone_files" ] && { echo "  file no longer exists, so ignore its restored text:"; printf '%s' "$gone_files" | by_directory; }
    [ -n "$changed" ] && printf '  skill changed since loaded, so re-read before acting under it:\n%s' "$changed"
    [ -n "$changed_files" ] && { echo "  file changed since last read, so re-read before relying on it:"; printf '%s' "$changed_files" | by_directory; }
    echo
}

session_start() {
    local input transcript
    input=$(cat)
    if is_worker "$input"; then
        echo "Your context was just compacted: what is above is a summary, not the conversation itself. Your brief and any file text restored are copies from before; re-read from disk what the work in hand still rests on (the plan, the files you are changing), and check \`git status\` in your checkout before continuing. If the summary leaves you unsure what was asked or agreed, ask the agent that started you rather than guess."
        return
    fi
    transcript=$(jq -r '.transcript_path // ""' <<<"$input" 2>/dev/null)
    printf '%s' "This session was just compacted: the conversation above is a summary of it, not the conversation itself."
    [ -n "$transcript" ] && printf ' %s' "For a specific the summary lacks, the full pre-compaction conversation is in its transcript, $transcript; search it with rg or jq rather than guess, and do not read the whole file into context."
    echo
    echo
    echo "Skill and file text restored after this compaction are copies from when they were loaded, and some are truncated. Before acting under a skill or instruction file that is still relevant to the work in hand, re-read it from disk; there is no need to re-read the rest. One that no longer exists no longer applies."
    echo
    stale_context "$transcript" "$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)"
    "$(dirname "${BASH_SOURCE[0]}")/compact-state.sh" <<<"$input"
}

# The previous turn of a main session is over when its last assistant record
# was written; the prompt being submitted is not one. Only the transcript's
# tail is read, and a line cut by it fails to parse and is skipped.
idle_prompt() {
    local input transcript hours last now idle
    input=$(cat)
    is_worker "$input" && return 0
    transcript=$(jq -r '.transcript_path // ""' <<<"$input" 2>/dev/null)
    [ -f "$transcript" ] && [ -r "$transcript" ] || return 0
    hours=${COMPACT_HANDOFF_IDLE_HOURS:-4}
    case $hours in '' | *[!0-9]*) hours=4 ;; esac
    last=$(tail -c 4194304 "$transcript" | jq -R -r '
        fromjson? | select(type == "object" and .type == "assistant" and .timestamp != null)
        | .timestamp | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch empty' 2>/dev/null | tail -1)
    [ -n "$last" ] || return 0
    now=$(date +%s)
    idle=$((now - last))
    [ "$idle" -gt $((hours * 3600)) ] || return 0
    local block
    block=$(stale_context "$transcript" "$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)")
    [ -n "$block" ] || return 0
    echo "This session's previous turn ended about $((idle / 3600)) hours ago. What it loaded earlier may be out of date:"
    echo
    printf '%s\n' "$block"
}

case "${1:-}" in
    pre) pre ;;
    post) post ;;
    session-start) session_start ;;
    idle-prompt) idle_prompt ;;
    *) echo "usage: $0 pre|post|session-start|idle-prompt" >&2; exit 2 ;;
esac
