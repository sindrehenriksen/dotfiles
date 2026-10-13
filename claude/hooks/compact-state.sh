#!/usr/bin/env bash
# Prints a short "current state, read from disk just now" block for a session
# restored from a compaction, so it works from what is true now rather than
# from the summary's account of it. Called by compact-handoff.sh session-start
# with the SessionStart hook input on stdin; runs by hand the same way.
#
#   git     The repo at the input's `cwd`, if it is one: every worktree with
#           its branch, which are dirty, and how many commits each has that
#           are not on its upstream (or, without one, on no remote at all).
#           The cwd's worktree comes first, then the dirty and unpushed ones,
#           then the rest, up to COMPACT_STATE_MAX_WORKTREES (default 10);
#           the line after says how many were left out and what they hold.
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
#           COMPACT_STATE_CWD set from the hook input; its stdout is appended,
#           cut at COMPACT_STATE_MAX_LINES (default 20) lines. All of them run
#           at once, each limited to COMPACT_STATE_TIMEOUT seconds (default
#           2); one that runs over is killed and named, one that fails is
#           named with its exit code and first line of stderr.
#
# The whole block stays well inside the hook's 5 s timeout: the git reads and
# the commands run in parallel under the same limit. Nothing here makes the
# hook fail; a read that fails says so in the block.
set -u

TIMEOUT="${COMPACT_STATE_TIMEOUT:-2}"
MAX_WT="${COMPACT_STATE_MAX_WORKTREES:-10}"
MAX_LINES="${COMPACT_STATE_MAX_LINES:-20}"
MAX_AGENTS=8
# Worktrees past this many are listed but not checked, so a repo with very
# many cannot spend the time budget on status calls.
MAX_CHECKED=40

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

# Prints at most MAX_LINES lines of a file, and a line saying how many it cut.
capped() {
    local n
    n=$(wc -l <"$1" | tr -d ' ')
    head -n "$MAX_LINES" "$1"
    [ "$n" -gt "$MAX_LINES" ] && echo "  ($((n - MAX_LINES)) more lines cut)"
}

# Prints a worktree's count of uncommitted files, then its count of commits on
# no remote: needed only for a branch with no upstream to count against,
# which the for-each-ref in git_block covers in one call.
wt_check() {
    local wt=$1 ref=$2 status
    status=$(git -C "$wt" status --porcelain --untracked-files=normal) || return 1
    if [ -n "$status" ]; then wc -l <<<"$status" | tr -d ' '; else echo 0; fi
    if [ -n "$ref" ]; then git -C "$wt" rev-list --count "$ref" --not --remotes || return 1; else echo; fi
}

git_block() {
    local cwd=$1 top
    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || {
        echo "Git: $(tilde "$cwd") is not in a git repository."
        return
    }

    local list
    if ! list=$(git -C "$cwd" worktree list --porcelain 2>&1); then
        echo "Git: could not list worktrees of $(tilde "$top"): ${list%%$'\n'*}"
        return
    fi

    # path<TAB>branch<TAB>flag, one per worktree; branch is `(detached)` or
    # `(bare)` when there is none.
    local rows
    rows=$(awk '
        /^worktree / { if (p != "") print p "\t" b "\t" f; p = substr($0, 10); b = ""; f = "" }
        /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
        /^detached/  { b = "(detached)" }
        /^bare/      { b = "(bare)" }
        /^prunable/  { f = "prunable" }
        END          { if (p != "") print p "\t" b "\t" f }' <<<"$list")

    # branch<TAB>upstream<TAB>track for every local branch, in one call.
    local tracks
    tracks=$(git -C "$cwd" for-each-ref --format='%(refname:short)%09%(upstream:short)%09%(upstream:track,nobracket)' refs/heads 2>/dev/null)

    local i=0 path branch flag up track names=()
    while IFS=$'\t' read -r path branch flag; do
        i=$((i + 1))
        [ "$i" -gt "$MAX_CHECKED" ] && break
        [ "$flag" = prunable ] || [ "$branch" = "(bare)" ] && continue
        up=$(awk -F'\t' -v b="$branch" '$1 == b { print $2 }' <<<"$tracks")
        local ref=""
        if [ -z "$up" ] || [ "$(awk -F'\t' -v b="$branch" '$1 == b { print $3 }' <<<"$tracks")" = gone ]; then
            case $branch in
                "(bare)") ref="" ;;
                "(detached)") ref=HEAD ;;
                *) ref="refs/heads/$branch" ;;
            esac
        fi
        spawn "wt$i" wt_check "$path" "$ref"
        names+=("wt$i")
    done <<<"$rows"
    [ "${#names[@]}" -gt 0 ] && reap "$DEADLINE" "${names[@]}"

    # One line per worktree, with a sort key: 0 the cwd's, 1 dirty, unpushed
    # or unknown, 2 clean and pushed.
    local lines="" key note dirty local_only total=0
    i=0
    while IFS=$'\t' read -r path branch flag; do
        i=$((i + 1))
        total=$((total + 1))
        note=()
        key=2
        if [ "$i" -gt "$MAX_CHECKED" ]; then
            note+=("not checked")
            key=3
        elif [ "$flag" = prunable ]; then
            note+=("missing on disk")
            key=1
        elif [ "$branch" = "(bare)" ]; then
            :
        elif [ ! -e "$JOBS/wt$i.rc" ]; then
            note+=("not read in ${TIMEOUT}s")
            key=1
        elif [ "$(cat "$JOBS/wt$i.rc")" != 0 ]; then
            note+=("status failed: $(head -1 "$JOBS/wt$i.err")")
            key=1
        else
            dirty=$(sed -n 1p "$JOBS/wt$i.out")
            local_only=$(sed -n 2p "$JOBS/wt$i.out")
            [ "${dirty:-0}" -gt 0 ] && { note+=("dirty: $(plural "$dirty" file)"); key=1; }
            up=$(awk -F'\t' -v b="$branch" '$1 == b { print $2 }' <<<"$tracks")
            track=$(awk -F'\t' -v b="$branch" '$1 == b { print $3 }' <<<"$tracks")
            if [ -n "$up" ] && [ "$track" != gone ]; then
                if [[ $track =~ ahead\ ([0-9]+) ]]; then
                    note+=("$(plural "${BASH_REMATCH[1]}" commit) not on $up")
                    key=1
                fi
            elif [ -n "$local_only" ] && [ "$local_only" -gt 0 ]; then
                note+=("$(plural "$local_only" commit) on no remote${up:+ (upstream $up gone)}")
                key=1
            elif [ "$track" = gone ]; then
                note+=("upstream $up gone")
            fi
        fi
        [ "$path" = "$top" ] && { key=0; note=("← cwd" ${note[@]+"${note[@]}"}); }
        local desc=""
        [ "${#note[@]}" -gt 0 ] && desc=$(join "${note[@]}")
        lines+="$key"$'\t'"  $(tilde "$path")  [$branch]${desc:+  $desc}"$'\n'
    done <<<"$rows"

    # The first worktree listed is the main one, which names the repo.
    echo "Git worktrees of $(tilde "${rows%%$'\t'*}") ($total):"
    local sorted shown cut_busy=0 cut_clean=0 cut_unchecked=0 n=0
    sorted=$(printf '%s' "$lines" | sort -s -t$'\t' -k1,1)
    while IFS=$'\t' read -r key shown; do
        [ -z "$key" ] && continue
        n=$((n + 1))
        if [ "$n" -le "$MAX_WT" ]; then
            echo "$shown"
        else
            case $key in
                0|1) cut_busy=$((cut_busy + 1)) ;;
                2) cut_clean=$((cut_clean + 1)) ;;
                3) cut_unchecked=$((cut_unchecked + 1)) ;;
            esac
        fi
    done <<<"$sorted"
    local cut=()
    [ "$cut_busy" -gt 0 ] && cut+=("$cut_busy dirty, unpushed or unread")
    [ "$cut_clean" -gt 0 ] && cut+=("$cut_clean clean with nothing unpushed")
    [ "$cut_unchecked" -gt 0 ] && cut+=("$cut_unchecked not checked")
    [ "${#cut[@]}" -gt 0 ] && echo "  ($(( cut_busy + cut_clean + cut_unchecked )) more not listed: $(join "${cut[@]}"); git worktree list shows them)"
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
    done < <(jq -r --argjson max "$MAX_AGENTS" '.[:$max][] | [.id, .d] | @tsv' <<<"$running")
    [ "$count" -gt "$MAX_AGENTS" ] && echo "  ($((count - MAX_AGENTS)) more not listed)"
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
    git_block "$cwd"

    reap "$DEADLINE" agents ${names[@]+"${names[@]}"}
    if [ -e "$JOBS/agents.rc" ]; then
        cat "$JOBS/agents.out"
    else
        echo "Background agents: not read in ${TIMEOUT}s."
    fi
    local rc err
    for i in ${names[@]+"${!names[@]}"}; do
        cmd=${labels[$i]}
        [ -s "$JOBS/${names[$i]}.out" ] && capped "$JOBS/${names[$i]}.out"
        if [ ! -e "$JOBS/${names[$i]}.rc" ]; then
            echo "($(tilde "$cmd") skipped: no answer within ${TIMEOUT}s.)"
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
