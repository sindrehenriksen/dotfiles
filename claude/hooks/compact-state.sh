#!/usr/bin/env bash
# Prints a short "current state, read from disk just now" block for a session
# restored from a compaction, so it works from what is true now rather than
# from the summary's account of it. Called by compact-handoff.sh session-start
# with the SessionStart hook input on stdin; runs by hand the same way.
#
#   git     Every worktree of the cwd's repo, other sessions' included, plus
#           any worktree in any repo that this session or its subagents
#           changed: one holding a file an Edit or Write named, or a path a
#           Bash command ran a changing git subcommand in (by `git -C` or
#           from its cwd) or created with `worktree add`. Read from the
#           transcript and those under <session>/subagents/; a path it cannot
#           resolve is skipped. For each, its branch, how many files are
#           uncommitted, and how many commits are not on its upstream (or,
#           without one, on no remote at all). The cwd's comes first.
#   agents  Background agents this session started that have not reported
#           back. Read from Claude Code's own files, which are undocumented:
#           <session>/subagents/agent-<id>.meta.json marks an agent started in
#           the background (`requestShape`), the transcript records its launch
#           (the meta's `toolUseId`), every `SendMessage` that resumes it, and
#           a `queue-operation` enqueue of a `<task-notification>` each time it
#           stops. An agent is listed when its last launch or resume has no
#           notification after it and happened in the current process (a
#           process that exits takes its agents with it and records nothing).
#   COMPACT_STATE_COMMANDS
#           A colon-separated list of executables (a leading `~/` expands),
#           a workspace's own additions, mirroring COMPACT_HANDOFF_LAYERS.
#           Each runs with no arguments, stdin from /dev/null, and
#           COMPACT_STATE_SESSION_ID, COMPACT_STATE_TRANSCRIPT and
#           COMPACT_STATE_CWD set from the hook input; its stdout is
#           appended in full, since a command whose output is too long needs
#           fixing rather than cropping. One that fails is named with its exit
#           code and first line of stderr.
#
# Nothing is bounded but time: the reads and the commands run in parallel
# under one failsafe, COMPACT_STATE_TIMEOUT seconds (default 20, inside the
# hook's own 30 in settings.json), and whatever is still running then is
# killed and named. Nothing here makes the hook fail; a read that fails says
# so in the block.
set -u

TIMEOUT="${COMPACT_STATE_TIMEOUT:-20}"

JOBS=$(mktemp -d) || exit 0
trap 'rm -rf "$JOBS"' EXIT

# join <items...>: the items separated by ", ".
join() { local IFS=$'\x1f' s; s="$*"; printf '%s' "${s//$'\x1f'/, }"; }

plural() { [ "$1" -eq 1 ] && printf '%s %s' "$1" "$2" || printf '%s %ss' "$1" "$2"; }

tilde() { local p=$1; [[ $p == "$HOME"/* || $p == "$HOME" ]] && p="~${p#"$HOME"}"; printf '%s' "$p"; }

# spawn <name> <cmd> [args...]: runs the command in the background, in its own
# process group (set -m) so a timeout can kill everything it started, with its
# output in $JOBS/<name>.{out,err,rc}. Nothing spawned inherits this script's
# stdout, which Claude Code reads to EOF.
spawn() {
    local name=$1
    shift
    set -m
    ( "$@" </dev/null >"$JOBS/$name.out" 2>"$JOBS/$name.err"; echo $? >"$JOBS/$name.rc" ) </dev/null >/dev/null 2>&1 &
    echo $! >"$JOBS/$name.pid"
    set +m
}

# Tenths of a second on a monotonic-enough clock: EPOCHREALTIME where bash
# has it (5.0 on), whole seconds otherwise.
now_tenths() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local t=${EPOCHREALTIME/[.,]/}
        echo $((10#$t / 100000))
    else
        echo $((SECONDS * 10))
    fi
}

# reap <deadline> <name>...: waits until every named job has finished or the
# deadline (from now_tenths) has passed, then kills the process group of any
# still running; such a job has no .rc file afterwards.
reap() {
    local deadline=$1 name pid alive
    shift
    while :; do
        alive=0
        for name in "$@"; do
            [ -e "$JOBS/$name.rc" ] || alive=1
        done
        [ "$alive" -eq 0 ] && break
        [ "$(now_tenths)" -ge "$deadline" ] && break
        sleep 0.1
    done
    [ "$alive" -eq 0 ] || {
        for name in "$@"; do
            [ -e "$JOBS/$name.rc" ] && continue
            kill -TERM -- "-$(cat "$JOBS/$name.pid")" 2>/dev/null
        done
        # Give a killed job a moment to go, then make sure.
        sleep 0.2
        for name in "$@"; do
            [ -e "$JOBS/$name.rc" ] && continue
            kill -KILL -- "-$(cat "$JOBS/$name.pid")" 2>/dev/null
        done
    }
    # Only the named jobs: a bare `wait` would also wait for every other
    # job still running, which is what the deadline is there to avoid.
    for name in "$@"; do
        pid=$(cat "$JOBS/$name.pid" 2>/dev/null) && wait "$pid" 2>/dev/null
    done
}

# One worktree's line, from a single `status --porcelain=v2 --branch`: its
# branch, uncommitted files, and commits not on its upstream (or, with no
# upstream or a gone one, on no remote).
wt_check() {
    local wt=$1 status head up ab dirty notes=() n
    # --no-optional-locks: never take index.lock in a worktree another
    # session may be committing in, least of all one this could then kill.
    status=$(git --no-optional-locks -C "$wt" status --porcelain=v2 --branch --untracked-files=normal) || return 1
    head=$(sed -n 's/^# branch.head //p' <<<"$status")
    up=$(sed -n 's/^# branch.upstream //p' <<<"$status")
    ab=$(sed -n 's/^# branch.ab +\([0-9]*\) .*/\1/p' <<<"$status")
    dirty=$(grep -vc '^#' <<<"$status")
    [ "$dirty" -gt 0 ] && notes+=("dirty: $(plural "$dirty" file)")
    if [ -n "$ab" ]; then
        [ "$ab" -gt 0 ] && notes+=("$(plural "$ab" commit) not on $up")
    else
        n=$(git -C "$wt" rev-list --count HEAD --not --remotes) || return 1
        [ "$n" -gt 0 ] && notes+=("$(plural "$n" commit) on no remote${up:+ (upstream $up gone)}")
        [ "$n" -eq 0 ] && [ -n "$up" ] && notes+=("upstream $up gone")
    fi
    printf '%s\t%s\n' "$head" "$(join ${notes[@]+"${notes[@]}"})"
}

# The paths a session changed something in, one per line, from transcript
# lines on stdin.
read -r -d '' CHANGED_JQ <<'JQ'
def mut: "(add|am|apply|checkout|cherry-pick|clean|commit|merge|mv|pull|push|rebase|reset|restore|revert|rm|stash|switch|tag)\\b";
def abs($cwd):
    (if test("^\"[^\"]*\"$") or test("^'[^']*'$") then .[1:-1] else . end)
    | (if . == "~" then $home elif startswith("~/") then $home + .[1:] else . end)
    | gsub("\\$HOME(?![A-Za-z0-9_])|\\$\\{HOME\\}"; $home)
    | select(test("[$`*?]") | not)
    | if startswith("/") then . elif $cwd != "" then $cwd + "/" + . else empty end;
select(contains("\"tool_use\"")) | fromjson? | select(type == "object")
| (.cwd // "") as $cwd
| .message.content[]? | select(type == "object" and .type == "tool_use")
| if .name == "Edit" or .name == "Write" or .name == "MultiEdit" then .input.file_path | strings | sub("/[^/]*$"; "")
  elif .name == "NotebookEdit" then .input.notebook_path | strings | sub("/[^/]*$"; "")
  elif .name == "Bash" then
      (.input.command // "") as $c
      | ($c | scan("git\\s+-C\\s+(\"[^\"]*\"|'[^']*'|[^\\s;&|)]+)\\s+" + mut)[0] | abs($cwd)),
        ($c | scan("worktree\\s+add\\s+(?:-[bB]\\s+\\S+\\s+|-\\S+\\s+)*(\"[^\"]*\"|'[^']*'|[^\\s;&|)]+)")[0] | abs($cwd)),
        (if $c | test("(^|[;&|(]\\s*)git\\s+" + mut) then $cwd | select(. != "") else empty end)
  else empty end
| strings
JQ

# The worktree roots for the paths a session changed: for each, the nearest
# ancestor holding a `.git`, as long as the directory leading from that root
# towards the path still exists, so a removed worktree does not land on the
# repo around it. A newline after each transcript, since the last line of one
# still being written has none.
changed_worktrees() {
    local transcript=$1 p child
    {
        cat "$transcript"
        echo
        compgen -G "${transcript%.jsonl}/subagents/agent-*.jsonl" | while IFS= read -r p; do cat "$p"; echo; done
    } | jq -R -r --arg home "$HOME" "$CHANGED_JQ" 2>/dev/null |
        sed -e 's|/\./|/|g' -e 's|\(/\.\)*/*$||' | sort -u |
        while IFS= read -r p; do
            child=""
            while [ -n "$p" ] && [ "$p" != / ]; do
                if [ -e "$p/.git" ]; then
                    { [ -z "$child" ] || [ -e "$p/$child" ]; } && (cd -P "$p" 2>/dev/null && pwd)
                    break
                fi
                child=${p##*/}
                p=${p%/*}
            done
        done | sort -u
}

# The cwd's repo's worktrees, canonical and cwd's first; bare entries and
# ones whose directory is gone are left out.
worktrees() {
    local here=$1 root
    { echo "$here"; git -C "$here" worktree list --porcelain 2>/dev/null |
        awk '/^worktree /{p=substr($0,10)} /^bare$/{p=""} /^$/{if(p!="")print p; p=""} END{if(p!="")print p}'; } |
        while IFS= read -r root; do (cd -P "$root" 2>/dev/null && pwd); done | awk '!seen[$0]++'
}

git_block() {
    local cwd=$1 transcript=$2 here="" changed="" roots root i=0 names=()
    here=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) && here=$(cd -P "$here" && pwd)
    [ -n "$transcript" ] && [ -r "$transcript" ] && changed=$(changed_worktrees "$transcript")
    roots=$( { [ -n "$here" ] && echo "$here"; [ -n "$changed" ] && echo "$changed"; [ -n "$here" ] && worktrees "$here"; } | awk 'NF && !seen[$0]++')
    if [ -z "$roots" ]; then
        echo "Worktrees: none ($(tilde "$cwd") is not in a git repository, and the transcript shows none changed)."
        return
    fi
    while IFS= read -r root; do
        i=$((i + 1))
        spawn "wt$i" wt_check "$root"
        names+=("wt$i")
    done <<<"$roots"
    reap "$DEADLINE" "${names[@]}"

    echo "Worktrees ($i: the cwd's repo's, other sessions' included, and any other this session changed):"
    local branch notes desc mark
    i=0
    while IFS= read -r root; do
        i=$((i + 1))
        mark=""
        [ "$root" = "$here" ] && mark="← cwd"
        grep -qxF "$root" <<<"$changed" && mark="${mark:+$mark, }changed by this session"
        if [ ! -e "$JOBS/wt$i.rc" ]; then
            desc="  $(tilde "$root")  not read in ${TIMEOUT}s"
        elif [ "$(cat "$JOBS/wt$i.rc")" != 0 ]; then
            desc="  $(tilde "$root")  status failed: $(head -1 "$JOBS/wt$i.err")"
        else
            IFS=$'\t' read -r branch notes <"$JOBS/wt$i.out"
            notes="$mark${mark:+${notes:+, }}$notes"
            desc="  $(tilde "$root")  [$branch]${notes:+  $notes}"
        fi
        echo "$desc"
    done <<<"$roots"
}

# The pid file of the Claude Code process running this hook: the nearest
# ancestor with one naming this session.
process_started_at() {
    local config=$1 session=$2 p=$PPID depth=0 f
    while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$depth" -lt 8 ]; do
        f="$config/sessions/$p.json"
        if [ -r "$f" ] && [ "$(jq -r '.sessionId // ""' "$f" 2>/dev/null)" = "$session" ]; then
            jq -r '.startedAt // empty' "$f" 2>/dev/null
            return
        fi
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        depth=$((depth + 1))
    done
}

agents_block() {
    local session=$1 transcript=$2
    if [ -z "$session" ]; then
        echo "Background agents: not read (the hook input names no session)."
        return
    elif [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
        echo "Background agents: not read (the hook input names no readable transcript)."
        return
    fi
    local dir=${transcript%.jsonl} config
    config=$(cd "$(dirname "$transcript")/../.." 2>/dev/null && pwd) || {
        echo "Background agents: not read (no Claude Code config dir above the transcript)."
        return
    }

    local files all metas
    files=$(compgen -G "$dir/subagents/agent-*.meta.json") || {
        echo "Background agents started from this session: none."
        return
    }
    # Each file as one line led by its name, then `fromjson?`, so one caught
    # mid-write costs only itself: jq alone would read the files as one
    # stream, and they end without a newline. xargs, because a long-lived
    # session holds more of them than one command line takes.
    all=$(tr '\n' '\0' <<<"$files" | xargs -0 awk 'FNR == 1 { if (NR > 1) print ""; printf "%s\t", FILENAME } { printf "%s", $0 } END { print "" }' | jq -R -c '
            index("\t") as $i | .[:$i] as $f | .[$i + 1:] | fromjson? | select(type == "object")
            | {id: ($f | capture("agent-(?<i>[^/]+)\\.meta\\.json$").i), d: (.description // ""),
               tu: (.toolUseId // ""), shape: (.requestShape // "foreground"), top: (.parentAgentId == null)}' 2>/dev/null | jq -sc '.')
    # The format check, so that Claude Code storing these differently reads
    # as that rather than as no agents. A record with no requestShape is a
    # foreground agent's, which is how Claude Code writes those.
    if [ "$(jq '[.[] | select(.tu != "")] | length' <<<"${all:-[]}")" -eq 0 ]; then
        echo "Background agents: not read ($(wc -l <<<"$files" | tr -d ' ') agent records, none in a recognised format; Claude Code may have changed how it stores them)."
        return
    fi
    metas=$(jq -c '[.[] | select(.shape == "background" and .top and .tu != "") | {id, d, tu}]' <<<"$all")
    if [ "$metas" = "[]" ]; then
        echo "Background agents started from this session: none."
        return
    fi

    local started
    started=$(process_started_at "$config" "$session")
    if [ -z "$started" ]; then
        echo "Background agents: not read (no live Claude Code process record for this session)."
        return
    fi

    # One pass over the transcript, in order: each line that could be a
    # launch, a resume or a stop becomes an event numbered by its line. Raw
    # lines and `fromjson?`, because the last one may be half written.
    local byTu events running
    byTu=$(jq -c 'map({key: .tu, value: .id}) | from_entries' <<<"$metas")
    events=$(jq -R -c --argjson byTu "$byTu" '
        select(contains("\"operation\":\"enqueue\"") or contains("\"type\":\"tool_use\""))
        | input_line_number as $n | fromjson? | select(type == "object")
        | if .type == "queue-operation" and .operation == "enqueue" and (.content | type) == "string"
             and (.content | startswith("<task-notification>")) then
            {k: "note", id: (.content | capture("<task-id>(?<i>[^<]+)</task-id>").i // ""), n: $n}
          elif .type == "assistant" then
            (.timestamp // "") as $ts
            | .message.content[]? | select(type == "object" and .type == "tool_use")
            | if .name == "SendMessage" then {k: "act", id: (.input.to // ""), n: $n, ts: $ts}
              elif $byTu[.id] then {k: "act", id: $byTu[.id], n: $n, ts: $ts}
              else empty end
          else empty end' "$transcript" 2>"$JOBS/events.err")
    # stderr rather than the exit code, which jq takes from the last input.
    if [ -s "$JOBS/events.err" ]; then
        echo "Background agents: could not read the transcript ($(head -1 "$JOBS/events.err" | cut -c1-200))."
        return
    fi
    running=$(jq -s -c --argjson metas "$metas" --argjson started "$started" '
        def secs: capture("^(?<b>[^.Z]+)(\\.(?<f>[0-9]+))?Z$") | (.b + "Z" | fromdateiso8601) + ((.f // "0") | "0." + . | tonumber);
        . as $ev
        | [$metas[] | . as $m
           | ([$ev[] | select(.k == "act" and .id == $m.id)] | max_by(.n)) as $act
           | ([$ev[] | select(.k == "note" and .id == $m.id) | .n] | max) as $note
           | select($act != null and ($note == null or $note < $act.n))
           | select(($act.ts | try secs catch 0) * 1000 >= $started)
           | $m]' <<<"$events") || {
        echo "Background agents: could not read the transcript."
        return
    }

    local count
    count=$(jq 'length' <<<"$running")
    if [ "$count" -eq 0 ]; then
        echo "Background agents started from this session: none still running."
        return
    fi
    echo "Background agents started from this session that have not reported back ($count; each reports here when it stops, and SendMessage takes the id):"
    local now id desc age
    now=$(date +%s)
    while IFS=$'\t' read -r id desc; do
        age=""
        if [ -e "$dir/subagents/agent-$id.jsonl" ]; then
            age=$(( (now - $(date -r "$dir/subagents/agent-$id.jsonl" +%s)) / 60 ))
            age=", last wrote ${age}m ago"
        fi
        echo "  $id  $desc$age"
    done < <(jq -r '.[] | [.id, .d] | @tsv' <<<"$running")
}

main() {
    local input cwd session transcript
    input=$(cat)
    cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null)
    [ -n "$cwd" ] || cwd=$PWD
    session=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)
    transcript=$(jq -r '.transcript_path // ""' <<<"$input" 2>/dev/null)

    # Everything shares one deadline. The workspace commands and the agents
    # read start first, so they run alongside the git reads.
    DEADLINE=$(( $(now_tenths) + TIMEOUT * 10 ))
    local cmd cmds names=() labels=() i=0
    IFS=: read -ra cmds <<<"${COMPACT_STATE_COMMANDS:-}"
    for cmd in ${cmds[@]+"${cmds[@]}"}; do
        [ -n "$cmd" ] || continue
        cmd=${cmd/#\~\//$HOME/}
        i=$((i + 1))
        labels+=("$cmd")
        names+=("cmd$i")
        COMPACT_STATE_SESSION_ID=$session COMPACT_STATE_TRANSCRIPT=$transcript COMPACT_STATE_CWD=$cwd \
            spawn "cmd$i" "$cmd"
    done

    spawn agents agents_block "$session" "$transcript"

    echo "Current state, read from disk at $(date +%H:%M) just now. Where the summary says otherwise, this is the one that is true:"
    git_block "$cwd" "$transcript"

    reap "$DEADLINE" agents ${names[@]+"${names[@]}"}
    if [ -e "$JOBS/agents.rc" ]; then
        cat "$JOBS/agents.out"
    else
        echo "Background agents: not read in ${TIMEOUT}s."
    fi
    local rc err
    for i in ${names[@]+"${!names[@]}"}; do
        cmd=${labels[$i]}
        cat "$JOBS/${names[$i]}.out"
        if [ ! -e "$JOBS/${names[$i]}.rc" ]; then
            echo "($(tilde "$cmd") killed: still running after ${TIMEOUT}s.)"
        else
            rc=$(cat "$JOBS/${names[$i]}.rc")
            if [ "$rc" != 0 ]; then
                err=$(head -1 "$JOBS/${names[$i]}.err" | cut -c1-200)
                echo "($(tilde "$cmd") failed, exit $rc${err:+: $err})"
            fi
        fi
    done
}

main 2>/dev/null
exit 0
