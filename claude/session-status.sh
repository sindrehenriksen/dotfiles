#!/usr/bin/env bash
# Reads Claude Code session state from the three places it's scattered across
# and joins them into one JSON line per session on stdout: the recorder's
# event log (claude/hooks/session-recorder.sh — liveness history, cwd), the
# pid files Claude Code itself writes for a live session
# ($CLAUDE_CONFIG_DIR/sessions/*.json), and its transcripts
# ($CLAUDE_CONFIG_DIR/projects/*/<id>.jsonl — names, last activity).
#
# Meant to be called often (a status line, an editor annotation), so every
# join is done in a handful of batched calls over all sessions at once rather
# than one call per session — a per-session shell loop calling jq/stat/ps a
# dozen times each is what actually costs the time here, not the file
# reading. The one thing that stays batched-per-file rather than fully
# batched is transcript content: each gets a cache entry (size, mtime, byte
# offset) in one consolidated cache file, and only a transcript whose size or
# mtime moved since the last read is scanned again — from its cached offset,
# not from the start.
#
# Fields per line: id, name, name_source ("user" — a custom title, or a
# live pid file's own user-set name — vs "ai_or_none": an ai-title fallback
# or no name at all), older_names, cwd, live, status, last_activity,
# last_human_message (epoch seconds: the latest transcript record that is text
# the user typed — not a tool_result, meta or compaction record, task
# notification or command/bash/system wrapper — falling back to the
# session's start; this, not last_activity, is the idle measure, since
# last_activity also moves on status updates, resumes and tool results),
# source (the recorder's own SessionStart "source" for the LAST start
# event only, null with no start event — display purposes),
# any_desk_run_start (true if ANY start event this session ever recorded
# had source "desk-run" — the capture step keys its own
# exclusion off THIS, never off `source` alone: a scheduled call's session
# the user later resumes themselves gets a real second start event, e.g. "resume",
# which would overwrite `source` and — checked against the last start
# alone — silently drop the exclusion right as the user starts actually using
# it), ended (true only when no process for the session is live and its
# latest run has an end event; see EVENTS_REDUCE for how ends are matched to
# processes), end_reason (that end's reason, null unless ended),
# close_failed, close_failed_at, transcript_path,
# has_start_event, pid, tty (the last two null unless live), duplicate_pids
# (true when more than one $CLAUDE_CONFIG_DIR/sessions/*.json pid file
# names this session id — the session open in two processes at once, a
# resumed session's stale leftover, or genuine corruption; the live one
# among them, if any, is still what pid/tty/
# status report, but a caller acting on liveness — the hotkey, `close` —
# must refuse outright rather than trust that choice). close_failed is
# true once a `close-failed` event (claude/hooks/session-recorder.sh) has
# been recorded after the session's own last start — a close step's own
# SIGTERM that the session survived, per its own "end" event (still whatever
# `close`/a real SessionEnd wrote — this never touches that one).
#
# Two modes:
#   session-status.sh            one JSON line per session, as above.
#   session-status.sh resolve <token>
#       Exact match against a session's *user-set* name (a custom
#       title, or a live session whose pid file says nameSource "user") —
#       never an ai-title fallback, which isn't a name the user chose. When no
#       name matches, the token may instead be a session id or a unique
#       prefix of one (8+ characters): the short id an unnamed capture
#       carries. An id match is never ranked; several are reported as
#       ambiguous. For a name: zero or
#       one match after narrowing prints that one entry and exits 0.
#       Several: narrow to the live ones (if any are live), then to
#       whichever of those has the latest last_activity; a genuine tie (or
#       no match at all) exits non-zero and prints the candidates it could
#       not narrow further (a JSON array, [] for no match).
set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STORE_DIR="${CLAUDE_SESSION_STORE:-$HOME/.local/state/claude/session-events}"
# The default cache is per config dir: two accounts (~/.claude and
# ~/.claude-work, say) hold different transcripts, and one shared file would be
# rewritten by whichever ran last.
CACHE_DIR="${CLAUDE_SESSION_READER_CACHE:-$HOME/.local/state/claude/session-reader-cache/$(printf '%s' "$CONFIG_DIR" | tr '/' '_')}"
PIDFILE_DIR="$CONFIG_DIR/sessions"
PROJECTS_DIR="$CONFIG_DIR/projects"
CONSOLIDATED_CACHE="$CACHE_DIR/transcripts.json"
# How many seconds apart a pid file's recorded start time and the OS's own
# idea of it may be and still count as the same process (rounding between
# the two representations, not a real tolerance for drift).
LIVENESS_TOLERANCE_SECS="${CLAUDE_SESSION_LIVENESS_TOLERANCE:-3}"
# Above this many changed/new transcripts, scan them all in one rg pass
# instead of one tail+rg per file — the shape of a first-ever run, or of the
# cache having been cleared, not of ordinary incremental use.
BATCH_RESCAN_THRESHOLD=5
# Bumped whenever what a cache entry holds, or how it is scanned, changes:
# an entry from an older version is rescanned from the start instead of
# being trusted as unchanged.
CACHE_VERSION=3

mkdir -p "$CACHE_DIR" 2>/dev/null

# The cache and the per-session title tables run to hundreds of kilobytes on
# a machine with a long history — past what a command-line argument can
# carry (one argument tops out at 128 KB on Linux, the whole line at 1 MB on
# macOS) — so the big tables reach jq as files (--slurpfile), never --argjson.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

is_linux() { [ -r /proc/stat ]; }

# procStart in a pid file is UTC (verified on this machine: parsing it with
# `date -u -j -f` lands on the same epoch `ps` itself reports for the
# process). This is the one date-parse liveness can't avoid.
parse_utc_ctime() {
    local raw; raw=$(printf '%s' "${1:-}" | tr -s ' ')
    [ -n "$raw" ] || return 1
    if is_linux; then date -u -d "$raw" +%s 2>/dev/null
    else date -u -j -f "%a %b %d %T %Y" "$raw" +%s 2>/dev/null
    fi
}

# `ps -o etime=` ("[[dd-]hh:]mm:ss") turned into seconds, in pure bash — the
# OS's other notion of a process's start time, `lstart`, needs a `date` fork
# to parse and (being local time) more careful handling besides; `etime` is
# arithmetic on a single ps column already free of both.
parse_etime_secs() {
    local e=${1:-}
    local dd=0 hh=0 mm='' ss='' rest=$e a b c
    case "$e" in
        *-*) dd=${e%%-*}; rest=${e#*-} ;;
    esac
    IFS=: read -r a b c <<< "$rest"
    if [ -n "${c:-}" ]; then hh=$a; mm=$b; ss=$c
    else mm=$a; ss=$b
    fi
    [ -n "${mm:-}" ] && [ -n "${ss:-}" ] || return 1
    printf '%d' $(( 10#$dd * 86400 + 10#$hh * 3600 + 10#$mm * 60 + 10#$ss ))
}

# --------------------------------------------------------------------------
# 1. Event log: one record per session id under $STORE_DIR. Batched into one
#    jq call across every file (jq tags each record with input_filename); a
#    record in a format from before this recorder existed can't even
#    tokenize, which fails the whole batch, so that failure falls back to
#    reading one file at a time — slower, but a single bad record can no
#    longer sink every other one.
# --------------------------------------------------------------------------
# Each start event opens a run for the process that wrote it; an end event
# closes only its own process's run. One session id can have more than one
# process at a time (opened in a second window while the first still runs),
# so "an end after the last start" would let one process's exit end another
# that is still running. An end carrying a pid closes the latest open run
# with that pid, else the latest open run with no pid (a start recorded
# before events carried one); an end without a pid (the `close` verb, a
# desk-run call's own end, an older record) closes the latest open run. An
# end that finds no open run is ignored, which is what makes the first end
# of a run win: `close` followed by the process's own SessionEnd, or a
# stray second SessionEnd. The events alone say the session ended when its
# latest run is closed; the join below still overrules that with liveness.
EVENTS_REDUCE='
    (map(select(.event=="start")) | last) as $s
    | (any(.[]; .event=="start" and .source=="desk-run")) as $any_desk_run
    | (to_entries | map(select(.value.event=="start")) | last | .key) as $lsi
    | (reduce .[] as $x ({runs: [], end: null};
        if $x.event == "start" then .runs += [{pid: ($x.pid // null), closed: false}] | .end = null
        elif $x.event == "end" then
          (.runs | to_entries | map(select(.value.closed | not))) as $open
          | (if ($x.pid // null) != null
             then (($open | map(select(.value.pid == $x.pid)) | last)
                   // ($open | map(select(.value.pid == null)) | last))
             else ($open | last) end) as $hit
          | if $hit == null then . else .runs[$hit.key].closed = true | .end = $x end
        else . end)) as $r
    | (if ($r.runs | length) > 0 and ($r.runs | last | .closed) then $r.end else null end) as $e
    | (if $lsi == null then null
       else (to_entries | map(select(.key > $lsi and .value.event=="close-failed")) | last | .value)
       end) as $cf
    | {
        has_start_event: ($s != null),
        cwd: ($s.cwd // ""),
        transcript_path: ($s.transcript_path // ""),
        start_time: ($s.time // null),
        source: ($s.source // null),
        any_desk_run_start: $any_desk_run,
        ended: ($e != null),
        end_reason: ($e.reason // null),
        close_failed: ($cf != null),
        close_failed_at: ($cf.time // null)
      }
'
EMPTY_EVENTS='{"has_start_event":false,"cwd":"","transcript_path":"","source":null,"any_desk_run_start":false,"ended":false,"end_reason":null,"start_time":null,"close_failed":false,"close_failed_at":null}'

events_by_id_fallback() {
    local f sid out result='{}'
    for f in "$STORE_DIR"/*.jsonl; do
        [ -f "$f" ] || continue
        sid=$(basename "$f" .jsonl)
        out=$(jq -cs "$EVENTS_REDUCE" "$f" 2>/dev/null)
        [ -n "$out" ] || out="$EMPTY_EVENTS"
        result=$(jq -c --arg id "$sid" --argjson ev "$out" '. + {($id): $ev}' <<< "$result" 2>/dev/null)
        [ -n "$result" ] || result='{}'
    done
    printf '%s' "$result"
}

events_by_id='{}'
if [ -d "$STORE_DIR" ]; then
    shopt -s nullglob
    store_files=("$STORE_DIR"/*.jsonl)
    shopt -u nullglob
    if [ "${#store_files[@]}" -gt 0 ]; then
        events_by_id=$(jq -n "
            [inputs | {file: input_filename, ev: .}]
            | group_by(.file)
            | map({
                key: (.[0].file | split(\"/\") | last | rtrimstr(\".jsonl\")),
                value: (map(.ev) | $EVENTS_REDUCE)
              })
            | from_entries
        " "${store_files[@]}" 2>/dev/null)
        if [ -z "$events_by_id" ]; then
            events_by_id=$(events_by_id_fallback)
        fi
    fi
fi
[ -n "$events_by_id" ] || events_by_id='{}'

# --------------------------------------------------------------------------
# 2. Pid files: always Claude Code's own valid JSON, so one batched read is
#    safe outright. Grouped by sessionId rather than collapsed 1:1 — a
#    resumed session, or a stale pid file Claude Code never cleaned up,
#    can leave more than one pid file naming the same sessionId, and a
#    plain `from_entries` used to just let the last one silently win with
#    no trace anything was wrong. Every group's own liveness is checked
#    entry by entry (two pid files for the same session can name two
#    different pids); the live one (if any — never more than one really
#    should be) is what "the" pid file means downstream, and
#    duplicate_pids records that more than one existed at all, so a
#    caller (the hotkey, `close`) can refuse rather than guess which one
#    is real.
# --------------------------------------------------------------------------
pidfiles_grouped='{}'
if [ -d "$PIDFILE_DIR" ]; then
    shopt -s nullglob
    pidfiles=("$PIDFILE_DIR"/*.json)
    shopt -u nullglob
    if [ "${#pidfiles[@]}" -gt 0 ]; then
        pidfiles_grouped=$(jq -s '
            map(select(.sessionId != null and .pid != null))
            | group_by(.sessionId)
            | map({key: .[0].sessionId, value: .})
            | from_entries
        ' "${pidfiles[@]}" 2>/dev/null)
    fi
fi
[ -n "$pidfiles_grouped" ] || pidfiles_grouped='{}'

# Liveness itself needs the OS (kill -0, ps), which is inherently per-pid —
# every candidate pid file in every group gets its own check (never just
# the group's first entry), keyed by (session id, its own index within
# that group) since two entries sharing an id can still name two
# different pids.
live_pairs=()    # sid, idx, live
pid_tty_pairs=() # sid, idx, pid, tty — only pushed for entries that turn out live
now_epoch=$(date +%s)
if [ "$pidfiles_grouped" != '{}' ]; then
    while IFS=$'\t' read -r sid idx pid procstart; do
        [ -n "$sid" ] || continue
        live="false"
        tty=""
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # etime, tty and comm in the one ps call, in that order: none of
            # the three ever contains a space, so splitting the combined
            # output on whitespace is safe — but ps truncates every column
            # except the last one to a fixed width, so comm (which can be a
            # long path) has to go last, not etime or tty.
            read -r etime tty comm < <(ps -o etime=,tty=,comm= -p "$pid" 2>/dev/null)
            case "$comm" in
                claude|*/claude)
                    p_epoch=$(parse_utc_ctime "$procstart") || p_epoch=""
                    etime_secs=$(parse_etime_secs "$etime") || etime_secs=""
                    if [ -n "$p_epoch" ] && [ -n "$etime_secs" ]; then
                        os_epoch=$(( now_epoch - etime_secs ))
                        diff=$(( p_epoch > os_epoch ? p_epoch - os_epoch : os_epoch - p_epoch ))
                        [ "$diff" -le "$LIVENESS_TOLERANCE_SECS" ] && live="true"
                    fi
                    ;;
            esac
        fi
        live_pairs+=("$sid" "$idx" "$live")
        if [ "$live" = "true" ]; then
            pid_tty_pairs+=("$sid" "$idx" "$pid" "$tty")
        fi
    done < <(jq -r '
        to_entries[] | .key as $sid | .value | to_entries[]
        | [$sid, (.key | tostring), (.value.pid | tostring), (.value.procStart // "")] | @tsv
    ' <<< "$pidfiles_grouped")
fi

live_lines=()
if [ "${#live_pairs[@]}" -gt 0 ]; then
    n=${#live_pairs[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        live_lines+=("$(printf '%s\t%s\t%s' "${live_pairs[$i]}" "${live_pairs[$((i + 1))]}" "${live_pairs[$((i + 2))]}")")
        i=$((i + 3))
    done
fi
live_by_id_idx='{}'
if [ "${#live_lines[@]}" -gt 0 ]; then
    live_by_id_idx=$(printf '%s\n' "${live_lines[@]}" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({sid: .[0], idx: .[1], live: (.[2] == "true")})
        | group_by(.sid)
        | map({key: .[0].sid, value: (map({(.idx): .live}) | add)})
        | from_entries
    ' 2>/dev/null)
fi
[ -n "$live_by_id_idx" ] || live_by_id_idx='{}'

pt_lines=()
if [ "${#pid_tty_pairs[@]}" -gt 0 ]; then
    n=${#pid_tty_pairs[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        pt_lines+=("$(printf '%s\t%s\t%s\t%s' \
            "${pid_tty_pairs[$i]}" "${pid_tty_pairs[$((i + 1))]}" "${pid_tty_pairs[$((i + 2))]}" "${pid_tty_pairs[$((i + 3))]}")")
        i=$((i + 4))
    done
fi
pid_tty_by_id_idx='{}'
if [ "${#pt_lines[@]}" -gt 0 ]; then
    pid_tty_by_id_idx=$(printf '%s\n' "${pt_lines[@]}" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({sid: .[0], idx: .[1], pid: (.[2] | tonumber), tty: .[3]})
        | group_by(.sid)
        | map({key: .[0].sid, value: (map({(.idx): {pid, tty}}) | add)})
        | from_entries
    ' 2>/dev/null)
fi
[ -n "$pid_tty_by_id_idx" ] || pid_tty_by_id_idx='{}'

# Per session id, the one pid-file entry everything downstream treats as
# "the" pid file: the live one in its group if any (a resumed session's
# stale leftover pid file never wins over the one that's actually live),
# else the group's first entry (not live either way, so which one is
# picked only affects informational fallback fields, never a liveness
# decision) — plus duplicate_pids, true whenever the group held more than
# one entry at all, live or not.
chosen_json=$(jq -cn --argjson groups "$pidfiles_grouped" --argjson live_idx "$live_by_id_idx" --argjson pt_idx "$pid_tty_by_id_idx" '
    $groups | to_entries | map(
        .key as $sid
        | .value as $entries
        | ($live_idx[$sid] // {}) as $lv
        | ([$entries | keys[] | tostring | select($lv[.] == true)] | .[0]) as $live_key
        | (if $live_key != null then $live_key else "0" end) as $chosen_idx
        | $entries[$chosen_idx | tonumber] as $pf
        | ($lv[$chosen_idx] // false) as $is_live
        | (($pt_idx[$sid] // {})[$chosen_idx] // null) as $pt
        | { key: $sid, value: {
              pf: $pf,
              live: $is_live,
              pid: (if $is_live then ($pt.pid // null) else null end),
              tty: (if $is_live then ($pt.tty // null) else null end),
              duplicate_pids: (($entries | length) > 1)
          } }
    ) | from_entries
' 2>/dev/null)
[ -n "$chosen_json" ] || chosen_json='{}'

pidfiles_by_id=$(jq -c 'with_entries(.value = .value.pf)' <<< "$chosen_json" 2>/dev/null)
live_by_id=$(jq -c 'with_entries(.value = .value.live)' <<< "$chosen_json" 2>/dev/null)
# id -> pid / id -> tty, live sessions only (the hotkey focuses a live
# session's Ghostty tab by tty rather than resuming it, so both need to
# reach the join below).
pid_by_id=$(jq -c '[to_entries[] | select(.value.pid != null) | {key, value: .value.pid}] | from_entries' <<< "$chosen_json" 2>/dev/null)
tty_by_id=$(jq -c '[to_entries[] | select(.value.tty != null) | {key, value: .value.tty}] | from_entries' <<< "$chosen_json" 2>/dev/null)
duplicate_pids_by_id=$(jq -c 'with_entries(.value = .value.duplicate_pids)' <<< "$chosen_json" 2>/dev/null)
[ -n "$pidfiles_by_id" ] || pidfiles_by_id='{}'
[ -n "$live_by_id" ] || live_by_id='{}'
[ -n "$pid_by_id" ] || pid_by_id='{}'
[ -n "$tty_by_id" ] || tty_by_id='{}'
[ -n "$duplicate_pids_by_id" ] || duplicate_pids_by_id='{}'

# --------------------------------------------------------------------------
# 3. Transcripts: names live in their custom-title/ai-title records. Scanned
#    through a single consolidated cache (path -> {size, mtime, offset,
#    custom_titles, ai_title}) so a transcript that hasn't grown since the
#    last read costs nothing beyond a stat.
# --------------------------------------------------------------------------
transcript_of_json='{}'
declare -A t_size t_mtime
transcript_paths=()
if [ -d "$PROJECTS_DIR" ]; then
    shopt -s nullglob
    # One level under a cwd directory only — a subagent transcript lives a
    # level deeper in its own subagents/ directory, so this glob can't reach it.
    for f in "$PROJECTS_DIR"/*/*.jsonl; do
        transcript_paths+=("$f")
    done
    shopt -u nullglob
fi

if [ "${#transcript_paths[@]}" -gt 0 ]; then
    transcript_of_json=$(printf '%s\n' "${transcript_paths[@]}" | jq -R -s -c '
        split("\n") | map(select(length>0))
        | map({key: (split("/") | last | rtrimstr(".jsonl")), value: .})
        | from_entries
    ')
    if is_linux; then
        stat_out=$(stat -c $'%n\t%s\t%Y' "${transcript_paths[@]}" 2>/dev/null)
    else
        stat_out=$(stat -f $'%N\t%z\t%m' "${transcript_paths[@]}" 2>/dev/null)
    fi
    while IFS=$'\t' read -r p s m; do
        [ -n "$p" ] || continue
        t_size["$p"]="$s"
        t_mtime["$p"]="$m"
    done <<< "$stat_out"
fi
[ -n "$transcript_of_json" ] || transcript_of_json='{}'

# path -> {size, mtime}, for the change-detection and metadata-attach steps
# below — built once, in one call, rather than looked up per path.
sizes_mtimes_json='{}'
if [ -n "${stat_out:-}" ]; then
    sizes_mtimes_json=$(printf '%s\n' "$stat_out" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({key: .[0], value: {size: (.[1]|tonumber), mtime: (.[2]|tonumber)}})
        | from_entries
    ' 2>/dev/null)
    [ -n "$sizes_mtimes_json" ] || sizes_mtimes_json='{}'
fi

cache_json='{}'
if [ -f "$CONSOLIDATED_CACHE" ]; then
    cache_json=$(cat "$CONSOLIDATED_CACHE" 2>/dev/null)
    [ -n "$cache_json" ] || cache_json='{}'
fi

# One call for every path at once — not one comparison per path — since this
# runs over every transcript on the machine, not just the changed ones.
changed_paths=()
if [ "${#transcript_paths[@]}" -gt 0 ]; then
    printf '%s' "$cache_json" > "$WORK_DIR/cache.json"
    printf '%s' "$sizes_mtimes_json" > "$WORK_DIR/cur.json"
    while IFS= read -r p; do
        [ -n "$p" ] && changed_paths+=("$p")
    done < <(jq -r --argjson ver "$CACHE_VERSION" --slurpfile cachef "$WORK_DIR/cache.json" --slurpfile curf "$WORK_DIR/cur.json" '
        $cachef[0] as $cache | $curf[0] as $cur
        | $cur | to_entries[]
        | select(($cache[.key].size // -1) != .value.size or ($cache[.key].mtime // -1) != .value.mtime
                 or ($cache[.key].v // 0) != $ver)
        | .key
    ' <<< 'null' 2>/dev/null)
fi

new_entries_json='{}'
if [ "${#changed_paths[@]}" -gt 0 ]; then
    if [ "${#changed_paths[@]}" -gt "$BATCH_RESCAN_THRESHOLD" ]; then
        # First-ever run, or the cache was cleared: one rg pass over every
        # changed file rather than one per file.
        # rg's matches (one "path:{...json...}" per line — megabytes on a
        # real machine, far past what an argument can carry) come in over
        # stdin; the path list and the stat table go in as files for the
        # same reason.
        batch_tmp=$(mktemp -d)
        printf '%s\n' "${changed_paths[@]}" > "$batch_tmp/paths"
        printf '%s' "$sizes_mtimes_json" > "$batch_tmp/sizes.json"
        new_entries_json=$(rg -N --with-filename '"type":"(custom-title|ai-title)"' "${changed_paths[@]}" 2>/dev/null \
            | jq -R -s -c --rawfile pathlist "$batch_tmp/paths" --slurpfile sz "$batch_tmp/sizes.json" \
            --argjson ver "$CACHE_VERSION" '
            $sz[0] as $sizes
            | ($pathlist | split("\n") | map(select(length>0))) as $paths
            | (. | split("\n") | map(select(length>0))) as $lines
            | ($lines | map(
                  . as $line | ($line | index(":")) as $i
                  | select($i != null)
                  | {file: $line[0:$i], rec: ($line[($i+1):] | try fromjson catch null)}
                  | select(.rec != null)
              )) as $parsed
            | ($paths | map({key: ., value: {custom_titles: [], ai_title: ""}}) | from_entries) as $base
            | (reduce $parsed[] as $p ($base;
                  if (.[$p.file] // null) == null then .
                  elif $p.rec.type == "custom-title" then .[$p.file].custom_titles += [$p.rec.customTitle]
                  elif $p.rec.type == "ai-title" then .[$p.file].ai_title = $p.rec.aiTitle
                  else . end
              )) as $titled
            # A full scan just read every one of these to EOF, so the byte
            # offset to cache is simply its current size.
            | $titled | with_entries(.value += {
                  size: ($sizes[.key].size // 0),
                  mtime: ($sizes[.key].mtime // 0),
                  offset: ($sizes[.key].size // 0),
                  v: $ver
              })
        ' 2>/dev/null)
        rm -rf "$batch_tmp"
    else
        # A handful of files actually changed: read only the bytes appended
        # since each one's cached offset.
        for p in "${changed_paths[@]}"; do
            # An entry from an older cache version starts over from byte 0.
            offset=$(jq -r --argjson ver "$CACHE_VERSION" --arg p "$p" 'if (.[$p].v // 0) == $ver then (.[$p].offset // 0) else 0 end' <<< "$cache_json" 2>/dev/null)
            ct=$(jq -c --argjson ver "$CACHE_VERSION" --arg p "$p" 'if (.[$p].v // 0) == $ver then (.[$p].custom_titles // []) else [] end' <<< "$cache_json" 2>/dev/null)
            ai=$(jq -r --argjson ver "$CACHE_VERSION" --arg p "$p" 'if (.[$p].v // 0) == $ver then (.[$p].ai_title // "") else "" end' <<< "$cache_json" 2>/dev/null)
            size="${t_size[$p]:-0}"
            [ "$size" -ge "${offset:-0}" ] 2>/dev/null || offset=0
            # The trailing "x" survives $(...)'s newline stripping, so a
            # complete final line (the usual place a rename lands) is still
            # seen as complete rather than mistaken for a partial write.
            raw_tail=$(tail -c "+$((offset + 1))" "$p" 2>/dev/null; printf x)
            raw_tail=${raw_tail%x}
            new_offset=$offset
            result=""
            if [ -n "$raw_tail" ]; then
                case "$raw_tail" in
                    *$'\n') consumed=$raw_tail ;;
                    *$'\n'*) consumed="${raw_tail%$'\n'*}"$'\n' ;;
                    *) consumed='' ;;
                esac
                case "$consumed" in $'\n'|'') consumed='' ;; esac
                if [ -n "$consumed" ]; then
                    bytes_consumed=$(printf '%s' "$consumed" | wc -c | tr -d ' ')
                    new_offset=$((offset + bytes_consumed))
                    matches=$(printf '%s' "$consumed" | rg -N '"type":"(custom-title|ai-title)"' 2>/dev/null || true)
                    if [ -n "$matches" ]; then
                        result=$(printf '%s\n' "$matches" | jq -c -s --argjson ct "$ct" --arg ai "$ai" '
                            reduce .[] as $l ({custom_titles:$ct, ai_title:$ai};
                                if $l.type == "custom-title" then .custom_titles += [$l.customTitle]
                                elif $l.type == "ai-title" then .ai_title = $l.aiTitle
                                else . end)
                        ' 2>/dev/null)
                    fi
                fi
            fi
            [ -n "$result" ] || result=$(jq -cn --argjson ct "$ct" --arg ai "$ai" '{custom_titles:$ct, ai_title:$ai}')
            new_entries_json=$(jq -c --arg p "$p" --argjson size "${t_size[$p]:-0}" --argjson mtime "${t_mtime[$p]:-0}" \
                --argjson offset "$new_offset" --argjson ver "$CACHE_VERSION" --argjson body "$result" '
                .[$p] = ($body + {size:$size, mtime:$mtime, offset:$offset, v:$ver})
            ' <<< "$new_entries_json" 2>/dev/null)
        done
    fi
fi
[ -n "$new_entries_json" ] || new_entries_json='{}'

# The latest human message per changed transcript: a type-user record whose
# content is text typed by the user, not a tool_result, a meta/compaction record,
# a task notification or a slash-command/bash/system wrapper. Scanned from
# the cached human_offset like the titles, but on its own offset since only
# whole lines are ever consumed. The rg prefilter drops tool_result records
# (most of a transcript's bytes) before jq parses anything.
HUMAN_RG='"role":"user","content":("|\[\{"type":"(text|image)")'
HUMAN_JQ='
    fromjson? | select(.type == "user" and (.isMeta | not) and (.isCompactSummary | not)
        and ((.origin.kind // "human") == "human"))
    | (.message.content
        | if type == "string" then .
          elif type == "array" then (map(select(.type == "text") | .text) | join("\n"))
          else "" end) as $t
    | select($t != "" and ($t | test("^\\s*(<(command-|local-command-|bash-|task-|system-reminder|user-prompt-submit-hook)|\\[Request interrupted)") | not))
    | (.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601? // empty)
'
if [ "${#changed_paths[@]}" -gt "$BATCH_RESCAN_THRESHOLD" ]; then
    # Many files at once (a cold or cleared cache): one rg pass over all of
    # them, whole files from byte 0.
    batch_tmp=$(mktemp -d)
    printf '%s' "$sizes_mtimes_json" > "$batch_tmp/sizes.json"
    rg -N --with-filename "$HUMAN_RG" "${changed_paths[@]}" 2>/dev/null \
        | jq -R -c "index(\":\") as \$i | {f: .[0:\$i], r: (.[(\$i+1):] | $HUMAN_JQ)} | select(.r != null)" 2>/dev/null \
        | jq -s -c 'group_by(.f) | map({key: .[0].f, value: (map(.r) | max)}) | from_entries' > "$batch_tmp/human.json" 2>/dev/null
    [ -s "$batch_tmp/human.json" ] || echo '{}' > "$batch_tmp/human.json"
    new_entries_json=$(jq -c --slurpfile h "$batch_tmp/human.json" --slurpfile sizes "$batch_tmp/sizes.json" '
        with_entries(.value += {last_human: ($h[0][.key] // null), human_offset: ($sizes[0][.key].size // 0)})
    ' <<< "$new_entries_json" 2>/dev/null)
    rm -rf "$batch_tmp"
else
    for p in "${changed_paths[@]}"; do
        hoff=$(jq -r --argjson ver "$CACHE_VERSION" --arg p "$p" 'if (.[$p].v // 0) == $ver then (.[$p].human_offset // 0) else 0 end' <<< "$cache_json" 2>/dev/null)
        hprev=$(jq -r --argjson ver "$CACHE_VERSION" --arg p "$p" 'if (.[$p].v // 0) == $ver then (.[$p].last_human // 0) else 0 end' <<< "$cache_json" 2>/dev/null)
        hsize="${t_size[$p]:-0}"
        [ "$hsize" -ge "${hoff:-0}" ] 2>/dev/null || { hoff=0; hprev=0; }
        # Streamed rather than held in a shell variable (transcripts reach
        # tens of megabytes), bounded to the size stat saw; a final line
        # without its newline is a write in progress and is left for later.
        hnew=$hsize
        if [ "$hsize" -gt 0 ] && [ "$(head -c "$hsize" "$p" | tail -c 1 | od -An -c | tr -d ' ')" != '\n' ]; then
            hnew=$((hsize - $(head -c "$hsize" "$p" | tail -n 1 | wc -c | tr -d ' ')))
        fi
        hbest=$hprev
        if [ "$hnew" -gt "$hoff" ]; then
            hlatest=$(tail -c "+$((hoff + 1))" "$p" 2>/dev/null | head -c "$((hnew - hoff))" \
                | rg -N "$HUMAN_RG" 2>/dev/null | jq -R -r "$HUMAN_JQ" 2>/dev/null | sort -n | tail -n 1)
            [ -n "$hlatest" ] && [ "$hlatest" -gt "${hbest:-0}" ] 2>/dev/null && hbest=$hlatest
        else
            hnew=$hoff
        fi
        new_entries_json=$(jq -c --arg p "$p" --argjson lh "${hbest:-0}" --argjson ho "$hnew" '
            .[$p] += {last_human: (if $lh > 0 then $lh else null end), human_offset: $ho}
        ' <<< "$new_entries_json" 2>/dev/null)
    done
fi
[ -n "$new_entries_json" ] || new_entries_json='{}'

# Merge: kept-old entries (still-existing paths only, so a deleted
# transcript's cache entry doesn't linger forever) overlaid with the fresh
# ones just computed.
kept_paths_json=$(printf '%s\n' "${transcript_paths[@]}" | jq -R -s -c 'split("\n") | map(select(length>0))')
printf '%s' "$new_entries_json" > "$WORK_DIR/new.json"
cache_json=$(jq -c --argjson keep "$kept_paths_json" --slurpfile newf "$WORK_DIR/new.json" '
    (to_entries | map(select(.key as $k | $keep | index($k) != null)) | from_entries) as $kept
    | $kept + $newf[0]
' <<< "$cache_json" 2>/dev/null)
[ -n "$cache_json" ] || cache_json='{}'
printf '%s' "$cache_json" > "$CONSOLIDATED_CACHE" 2>/dev/null

# id -> {custom_titles, ai_title} keyed by session id rather than by path.
printf '%s' "$cache_json" > "$WORK_DIR/cache.json"
titles_by_id=$(jq -c --slurpfile cachef "$WORK_DIR/cache.json" '
    $cachef[0] as $cache
    | map_values(. as $path | ($cache[$path] // {custom_titles: [], ai_title: ""})
        | {custom_titles, ai_title, last_human: (.last_human // null)})
' <<< "$transcript_of_json" 2>/dev/null)
[ -n "$titles_by_id" ] || titles_by_id='{}'

# path -> mtime, for last_activity's transcript-mtime term.
transcript_mtime_json='{}'
if [ -n "${stat_out:-}" ]; then
    transcript_mtime_json=$(printf '%s\n' "$stat_out" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({key: .[0], value: (.[2] | tonumber)})
        | from_entries
    ' 2>/dev/null)
fi
[ -n "$transcript_mtime_json" ] || transcript_mtime_json='{}'

# --------------------------------------------------------------------------
# 4. Join everything in one pass and emit one JSON line per session id. Built
#    into a variable rather than streamed straight to stdout, since `resolve`
#    mode below needs to filter and rank this same set rather than re-derive
#    it. `_name_source` is dropped before anything is actually printed (both
#    modes) — it exists only so resolve can tell a name the user chose from an
#    ai-title fallback without a second join.
# --------------------------------------------------------------------------
printf '%s' "$titles_by_id" > "$WORK_DIR/titles.json"
entries_ndjson=$(jq -n -c \
    --argjson events "$events_by_id" \
    --argjson pidfiles "$pidfiles_by_id" \
    --argjson live "$live_by_id" \
    --argjson pids "$pid_by_id" \
    --argjson ttys "$tty_by_id" \
    --argjson dup_pids "$duplicate_pids_by_id" \
    --slurpfile titlesf "$WORK_DIR/titles.json" \
    --argjson transcripts "$transcript_of_json" \
    --argjson mtimes "$transcript_mtime_json" '
    $titlesf[0] as $titles |
    def norm_ms: if . != null and (type == "number") then (. / 1000 | floor) else null end;
    ( ($events | keys) + ($pidfiles | keys) + ($transcripts | keys) | unique ) as $ids
    | $ids[]
    | . as $id
    | ($events[$id] // {has_start_event:false, cwd:"", transcript_path:"", source:null, any_desk_run_start:false, ended:false, end_reason:null, start_time:null}) as $ev
    | ($pidfiles[$id] // null) as $pf
    | ($live[$id] // false) as $is_live
    | ($titles[$id] // {custom_titles: [], ai_title: ""}) as $ti
    | ($transcripts[$id] // null) as $tp_path
    | ($pf.updatedAt | norm_ms) as $pf_updated
    | ($pf.startedAt | norm_ms) as $pf_started
    # A live process outranks any end event: a session is ended only once
    # none of its processes is still running.
    | ($ev.ended and ($is_live | not)) as $ended
    | ($ti.custom_titles | length) as $name_count
    | (
        if $name_count > 0 then $ti.custom_titles[-1]
        elif ($is_live and $pf != null and $pf.nameSource == "user" and (($pf.name // "") != "")) then $pf.name
        else ($ti.ai_title // "")
        end
      ) as $name
    | (if $name_count > 1 then $ti.custom_titles[0:-1] else [] end) as $older_names
    | (
        if $is_live then ($pf.status // "live")
        elif $ended then "ended"
        elif $ev.has_start_event then "orphaned"
        else "unknown"
        end
      ) as $status
    | (if ($ev.transcript_path // "") != "" then $ev.transcript_path
       elif $tp_path != null then $tp_path
       else "" end) as $transcript_path
    | (if ($ev.cwd // "") != "" then $ev.cwd
       elif $pf != null then ($pf.cwd // "")
       else "" end) as $cwd
    | (if $tp_path != null then ($mtimes[$tp_path] // null) else null end) as $tp_mtime
    | ([$pf_updated, $tp_mtime] | map(select(. != null))) as $activity_candidates
    | (if ($activity_candidates | length) > 0 then ($activity_candidates | max)
       else ($pf_started // $ev.start_time // null)
       end) as $last_activity
    | ($ti.last_human // $pf_started // $ev.start_time // null) as $last_human_message
    | (if $name_count > 0 or ($is_live and $pf != null and $pf.nameSource == "user" and (($pf.name // "") != ""))
       then "user" else "ai_or_none" end) as $name_source
    | {
        id: $id,
        name: $name,
        older_names: $older_names,
        cwd: $cwd,
        live: $is_live,
        status: $status,
        last_activity: $last_activity,
        last_human_message: $last_human_message,
        source: $ev.source,
        any_desk_run_start: ($ev.any_desk_run_start // false),
        ended: $ended,
        end_reason: (if $ended then $ev.end_reason else null end),
        close_failed: $ev.close_failed,
        close_failed_at: $ev.close_failed_at,
        transcript_path: $transcript_path,
        has_start_event: $ev.has_start_event,
        pid: (if $is_live then ($pids[$id] // null) else null end),
        tty: (if $is_live then ($ttys[$id] // null) else null end),
        duplicate_pids: ($dup_pids[$id] // false),
        _name_source: $name_source
      }
')

# --------------------------------------------------------------------------
# 5. Mode dispatch: the default (no args) prints every entry; `resolve
#    <token>` narrows to one, per the file header's spec.
# --------------------------------------------------------------------------
case "${1:-}" in
    resolve)
        token=${2:-}
        matches=$(printf '%s\n' "$entries_ndjson" | jq -s -c --arg token "$token" '
            map(select(._name_source == "user" and .name == $token) | del(._name_source))
        ')
        if [ "$(printf '%s' "$matches" | jq 'length')" = "0" ] && [ -n "$token" ]; then
            # Not a name the user set: an unnamed capture is labelled by its short
            # session id, so a full id or a unique 8+-character id prefix
            # resolves too. Never a guess: several matches are reported as
            # candidates, not ranked.
            by_id=$(printf '%s\n' "$entries_ndjson" | jq -s -c --arg token "$token" '
                ( map(select(.id == $token)) ) as $exact
                | if ($exact | length) > 0 then $exact
                  elif ($token | length) >= 8 then map(select(.id | startswith($token)))
                  else [] end
                | map(del(._name_source))
            ')
            if [ "$(printf '%s' "$by_id" | jq 'length')" = "1" ]; then
                printf '%s\n' "$by_id" | jq -c '.[0]'
                exit 0
            fi
            printf '%s\n' "$by_id"
            exit 1
        fi
        if [ "$(printf '%s' "$matches" | jq 'length')" = "1" ]; then
            printf '%s\n' "$matches" | jq -c '.[0]'
            exit 0
        fi
        # Prefer live over not-live; among whichever set that leaves, the
        # single most recent last_activity wins outright. A genuine tie
        # (including "all missing last_activity", which sorts as 0) can't
        # be narrowed further and is reported as ambiguous.
        narrowed=$(printf '%s' "$matches" | jq -c '
            (map(select(.live == true))) as $live
            | if ($live | length) > 0 then $live else . end
        ')
        top=$(printf '%s' "$narrowed" | jq '[.[] | (.last_activity // 0)] | (max // 0)')
        tied=$(printf '%s' "$narrowed" | jq -c --argjson top "$top" '
            [.[] | select((.last_activity // 0) == $top)]
        ')
        if [ "$(printf '%s' "$tied" | jq 'length')" = "1" ]; then
            printf '%s\n' "$tied" | jq -c '.[0]'
            exit 0
        fi
        printf '%s\n' "$narrowed"
        exit 1
        ;;
    "")
        # name_source ("user" vs "ai_or_none") tells apart a session the user
        # actually named from one only ever known by its auto title — the
        # 16:30 capture's own "unnamed" needs exactly this,
        # not just an empty .name (an ai-title fallback is never empty when
        # Claude Code has assigned one).
        printf '%s\n' "$entries_ndjson" | jq -c '.name_source = ._name_source | del(._name_source)'
        ;;
    *)
        printf 'session-status.sh: unknown mode: %s\n' "$1" >&2
        exit 2
        ;;
esac
