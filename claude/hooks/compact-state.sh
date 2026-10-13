#!/usr/bin/env bash
# Prints a short "current state, read from disk just now" block for a session
# restored from a compaction, so it works from what is true now rather than
# from the summary's account of it. Called by compact-handoff.sh session-start
# with the SessionStart hook input on stdin; runs by hand the same way.
#
#   git     The worktrees this session has worked in: every directory with
#           a `.git` that holds a path the transcript mentions (absolute, or
#           under `~/`), plus the cwd's. For each, its branch, how many files
#           are uncommitted, and how many commits are not on its upstream (or,
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
#           Agents started by other agents, and a foreground agent moved to
#           the background mid-run, are not seen.
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
    ( "$@" </dev/null >"$JOBS/$name.out" 2>"$JOBS/$name.err"; echo $? >"$JOBS/$name.rc" ) &
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

# The worktree roots this session has touched: the nearest ancestor holding a
# `.git` of each home-directory path the transcript mentions, and the cwd's.
# A trailing slash or full stop is dropped, so `dir/` and a sentence ending in
# a path count as the path.
touched_worktrees() {
    local cwd=$1 transcript=$2 p
    git -C "$cwd" rev-parse --show-toplevel 2>/dev/null
    [ -r "$transcript" ] || return 0
    grep -oE "(~|$HOME)/[A-Za-z0-9._/-]+" "$transcript" 2>/dev/null | sed -e "s|^~/|$HOME/|" -e 's|[./]*$||' | sort -u |
        while IFS= read -r p; do
            while [ "${#p}" -gt "${#HOME}" ]; do
                if [ -e "$p/.git" ]; then echo "$p"; break; fi
                p=${p%/*}
            done
        done
}

# One worktree's line, from a single `status --porcelain=v2 --branch`: its
# branch, uncommitted files, and commits not on its upstream (or, with no
# upstream or a gone one, on no remote).
wt_check() {
    local wt=$1 status head up ab dirty notes=() n
    status=$(git -C "$wt" status --porcelain=v2 --branch --untracked-files=normal) || return 1
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

git_block() {
    local cwd=$1 transcript=$2 here roots root i=0 names=()
    here=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    roots=$(touched_worktrees "$cwd" "$transcript" | awk '!seen[$0]++')
    if [ -z "$roots" ]; then
        echo "Worktrees: $(tilde "$cwd") is not in a git repository, and the transcript names no other."
        return
    fi
    while IFS= read -r root; do
        i=$((i + 1))
        spawn "wt$i" wt_check "$root"
        names+=("wt$i")
    done <<<"$roots"
    reap "$DEADLINE" "${names[@]}"

    echo "Worktrees this session has worked in ($i; read from the paths in its transcript):"
    local branch notes desc
    i=0
    while IFS= read -r root; do
        i=$((i + 1))
        if [ ! -e "$JOBS/wt$i.rc" ]; then
            desc="  $(tilde "$root")  not read in ${TIMEOUT}s"
        elif [ "$(cat "$JOBS/wt$i.rc")" != 0 ]; then
            desc="  $(tilde "$root")  status failed: $(head -1 "$JOBS/wt$i.err")"
        else
            IFS=$'\t' read -r branch notes <"$JOBS/wt$i.out"
            [ "$root" = "$here" ] && notes="← cwd${notes:+, $notes}"
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
    [ -n "$session" ] && [ -r "$transcript" ] || return
    local dir=${transcript%.jsonl} config
    config=$(cd "$(dirname "$transcript")/../.." 2>/dev/null && pwd) || return

    local metas files
    files=$(compgen -G "$dir/subagents/agent-*.meta.json") || return
    # xargs, because a long-lived session can hold more of them than one
    # command line takes.
    metas=$(tr '\n' '\0' <<<"$files" | xargs -0 jq -c 'select(.requestShape == "background" and .parentAgentId == null)
            | {id: (input_filename | capture("agent-(?<i>[^/]+)\\.meta\\.json$").i), d: (.description // ""), tu: (.toolUseId // "")}' 2>/dev/null | jq -sc '.')
    [ "$metas" = "[]" ] || [ -z "$metas" ] && return

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
          else empty end' "$transcript") || {
        echo "Background agents: could not read the transcript."
        return
    }
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
