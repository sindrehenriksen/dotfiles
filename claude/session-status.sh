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
# source (the recorder's own SessionStart "source" for the LAST start
# event only, null with no start event — display purposes),
# any_desk_run_start (true if ANY start event this session ever recorded
# had source "desk-run" — design.md §3's 16:30 capture keys its own
# exclusion off THIS, never off `source` alone: a scheduled call's session
# he later resumes himself gets a real second start event, e.g. "resume",
# which would overwrite `source` and — checked against the last start
# alone — silently drop the exclusion right as he starts actually using
# it), ended, end_reason, close_failed, close_failed_at, transcript_path,
# has_start_event, pid, tty (the last two null unless live). close_failed is
# true once a `close-failed` event (claude/hooks/session-recorder.sh) has
# been recorded after the session's own last start — a close step's own
# SIGTERM that the session survived, per its own "end" event (still whatever
# `close`/a real SessionEnd wrote — this never touches that one).
#
# Two modes:
#   session-status.sh            one JSON line per session, as above.
#   session-status.sh resolve <token>
#       Exact match against a session's *user-set* name only (a custom
#       title, or a live session whose pid file says nameSource "user") —
#       never an ai-title fallback, which isn't a name he chose. Zero or
#       one match after narrowing prints that one entry and exits 0.
#       Several: narrow to the live ones (if any are live), then to
#       whichever of those has the latest last_activity; a genuine tie (or
#       no match at all) exits non-zero and prints the candidates it could
#       not narrow further (a JSON array, [] for no match).
set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STORE_DIR="${CLAUDE_SESSION_STORE:-$HOME/.local/state/claude/session-events}"
CACHE_DIR="${CLAUDE_SESSION_READER_CACHE:-$HOME/.local/state/claude/session-reader-cache}"
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

mkdir -p "$CACHE_DIR" 2>/dev/null

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
EVENTS_REDUCE='
    (map(select(.event=="start")) | last) as $s
    | (any(.[]; .event=="start" and .source=="desk-run")) as $any_desk_run
    | (to_entries | map(select(.value.event=="start")) | last | .key) as $lsi
    | (if $lsi == null then null
       else (to_entries | map(select(.key > $lsi and .value.event=="end")) | last | .value)
       end) as $e
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
#    safe outright.
# --------------------------------------------------------------------------
pidfiles_by_id='{}'
if [ -d "$PIDFILE_DIR" ]; then
    shopt -s nullglob
    pidfiles=("$PIDFILE_DIR"/*.json)
    shopt -u nullglob
    if [ "${#pidfiles[@]}" -gt 0 ]; then
        pidfiles_by_id=$(jq -s '
            map(select(.sessionId != null and .pid != null))
            | map({key: .sessionId, value: .})
            | from_entries
        ' "${pidfiles[@]}" 2>/dev/null)
    fi
fi
[ -n "$pidfiles_by_id" ] || pidfiles_by_id='{}'

# Liveness itself needs the OS (kill -0, ps), which is inherently per-pid —
# but only for however many sessions actually have a pid file, i.e. however
# many are plausibly live right now, not every session ever recorded.
live_pairs=()
pid_tty_pairs=() # sid, pid, tty — only pushed for sessions that turn out live
now_epoch=$(date +%s)
if [ "$pidfiles_by_id" != '{}' ]; then
    while IFS=$'\t' read -r sid pid procstart; do
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
        live_pairs+=("$sid" "$live")
        if [ "$live" = "true" ]; then
            pid_tty_pairs+=("$sid" "$pid" "$tty")
        fi
    done < <(jq -r 'to_entries[] | [.key, (.value.pid|tostring), (.value.procStart // "")] | @tsv' <<< "$pidfiles_by_id")
fi
live_by_id='{}'
if [ "${#live_pairs[@]}" -gt 0 ]; then
    live_tsv=""
    n=${#live_pairs[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        live_tsv="${live_tsv}${live_pairs[$i]}	${live_pairs[$((i + 1))]}
"
        i=$((i + 2))
    done
    live_by_id=$(printf '%s' "$live_tsv" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({key: .[0], value: (.[1] == "true")})
        | from_entries
    ' 2>/dev/null)
fi
[ -n "$live_by_id" ] || live_by_id='{}'

# id -> pid / id -> tty, live sessions only (D7: the hotkey focuses a live
# session's Ghostty tab by tty rather than resuming it, so both need to
# reach the join below).
pid_by_id='{}'
tty_by_id='{}'
if [ "${#pid_tty_pairs[@]}" -gt 0 ]; then
    pt_tsv=""
    n=${#pid_tty_pairs[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        pt_tsv="${pt_tsv}${pid_tty_pairs[$i]}	${pid_tty_pairs[$((i + 1))]}	${pid_tty_pairs[$((i + 2))]}
"
        i=$((i + 3))
    done
    pid_by_id=$(printf '%s' "$pt_tsv" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({key: .[0], value: (.[1] | tonumber)})
        | from_entries
    ' 2>/dev/null)
    tty_by_id=$(printf '%s' "$pt_tsv" | jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t"))
        | map({key: .[0], value: .[2]})
        | from_entries
    ' 2>/dev/null)
fi
[ -n "$pid_by_id" ] || pid_by_id='{}'
[ -n "$tty_by_id" ] || tty_by_id='{}'

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
    while IFS= read -r p; do
        [ -n "$p" ] && changed_paths+=("$p")
    done < <(jq -r --argjson cache "$cache_json" --argjson cur "$sizes_mtimes_json" '
        $cur | to_entries[]
        | select(($cache[.key].size // -1) != .value.size or ($cache[.key].mtime // -1) != .value.mtime)
        | .key
    ' <<< 'null' 2>/dev/null)
fi

new_entries_json='{}'
if [ "${#changed_paths[@]}" -gt 0 ]; then
    if [ "${#changed_paths[@]}" -gt "$BATCH_RESCAN_THRESHOLD" ]; then
        # First-ever run, or the cache was cleared: one rg pass over every
        # changed file rather than one per file.
        titles_raw=$(rg -N --with-filename '"type":"(custom-title|ai-title)"' "${changed_paths[@]}" 2>/dev/null || true)
        # The path list comes in over stdin (-s slurps it); rg's matches, one
        # "path:{...json...}" per line, come in as a single --arg since jq
        # only slurps one stream.
        new_entries_json=$(printf '%s\n' "${changed_paths[@]}" | jq -R -s -c --arg raw "$titles_raw" \
            --argjson sizes "$sizes_mtimes_json" '
            (split("\n") | map(select(length>0))) as $paths
            | ($raw | split("\n") | map(select(length>0))) as $lines
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
                  offset: ($sizes[.key].size // 0)
              })
        ' 2>/dev/null)
    else
        # A handful of files actually changed: read only the bytes appended
        # since each one's cached offset.
        for p in "${changed_paths[@]}"; do
            offset=$(jq -r --arg p "$p" '.[$p].offset // 0' <<< "$cache_json" 2>/dev/null)
            ct=$(jq -c --arg p "$p" '.[$p].custom_titles // []' <<< "$cache_json" 2>/dev/null)
            ai=$(jq -r --arg p "$p" '.[$p].ai_title // ""' <<< "$cache_json" 2>/dev/null)
            size="${t_size[$p]:-0}"
            [ "$size" -ge "${offset:-0}" ] 2>/dev/null || offset=0
            raw_tail=$(tail -c "+$((offset + 1))" "$p" 2>/dev/null)
            new_offset=$offset
            result=""
            if [ -n "$raw_tail" ]; then
                case "$raw_tail" in
                    *$'\n') consumed=$raw_tail ;;
                    *) consumed="${raw_tail%$'\n'*}"$'\n' ;;
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
                --argjson offset "$new_offset" --argjson body "$result" '
                .[$p] = ($body + {size:$size, mtime:$mtime, offset:$offset})
            ' <<< "$new_entries_json" 2>/dev/null)
        done
    fi
fi
[ -n "$new_entries_json" ] || new_entries_json='{}'

# Merge: kept-old entries (still-existing paths only, so a deleted
# transcript's cache entry doesn't linger forever) overlaid with the fresh
# ones just computed.
kept_paths_json=$(printf '%s\n' "${transcript_paths[@]}" | jq -R -s -c 'split("\n") | map(select(length>0))')
cache_json=$(jq -c --argjson keep "$kept_paths_json" --argjson new "$new_entries_json" '
    (to_entries | map(select(.key as $k | $keep | index($k) != null)) | from_entries) as $kept
    | $kept + $new
' <<< "$cache_json" 2>/dev/null)
[ -n "$cache_json" ] || cache_json='{}'
printf '%s' "$cache_json" > "$CONSOLIDATED_CACHE" 2>/dev/null

# id -> {custom_titles, ai_title} keyed by session id rather than by path.
titles_by_id=$(jq -c --argjson cache "$cache_json" '
    map_values(. as $path | ($cache[$path] // {custom_titles: [], ai_title: ""})
        | {custom_titles, ai_title})
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
#    modes) — it exists only so resolve can tell a name he chose from an
#    ai-title fallback without a second join.
# --------------------------------------------------------------------------
entries_ndjson=$(jq -n -c \
    --argjson events "$events_by_id" \
    --argjson pidfiles "$pidfiles_by_id" \
    --argjson live "$live_by_id" \
    --argjson pids "$pid_by_id" \
    --argjson ttys "$tty_by_id" \
    --argjson titles "$titles_by_id" \
    --argjson transcripts "$transcript_of_json" \
    --argjson mtimes "$transcript_mtime_json" '
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
        elif $ev.ended then "ended"
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
        source: $ev.source,
        any_desk_run_start: ($ev.any_desk_run_start // false),
        ended: $ev.ended,
        end_reason: $ev.end_reason,
        close_failed: $ev.close_failed,
        close_failed_at: $ev.close_failed_at,
        transcript_path: $transcript_path,
        has_start_event: $ev.has_start_event,
        pid: (if $is_live then ($pids[$id] // null) else null end),
        tty: (if $is_live then ($ttys[$id] // null) else null end),
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
        # name_source ("user" vs "ai_or_none") tells apart a session he
        # actually named from one only ever known by its auto title — the
        # 16:30 capture's own "unnamed" (design.md §3) needs exactly this,
        # not just an empty .name (an ai-title fallback is never empty when
        # Claude Code has assigned one).
        printf '%s\n' "$entries_ndjson" | jq -c '.name_source = ._name_source | del(._name_source)'
        ;;
    *)
        printf 'session-status.sh: unknown mode: %s\n' "$1" >&2
        exit 2
        ;;
esac
