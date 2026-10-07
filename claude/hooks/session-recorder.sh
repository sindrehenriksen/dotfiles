#!/usr/bin/env bash
# Records Claude Code session lifecycle as an append-only JSONL event log, one
# file per session id, under $CLAUDE_SESSION_STORE (default
# ~/.local/state/claude/session-events/, one `<session_id>.jsonl` per
# session). A session that never got to exit
# cleanly — a crash, a force-quit, a reboot — simply has no end event, and its
# record just sits there; nothing here ever deletes a record on its own.
#
# Wired in from settings.json as `session-recorder.sh start` on SessionStart
# and `session-recorder.sh end` on SessionEnd, hook JSON on stdin. The `close`
# verb is for anything else that ends a session on the user's behalf and
# needs the record to say so before the process actually terminates: it takes
# a session id as an argument instead, since there is no hook JSON to read.
# `close-failed` is the close step's own follow-up when a `close`-recorded
# session survives its SIGTERM (claude/desk-lib/steps.sh's desk_step_close):
# the "end" event `close` already wrote stays exactly as it was, and this
# adds a plain marker event instead — session-status.sh surfaces it as
# `close_failed`/`close_failed_at` so a survivor is visible as one, not just
# quietly retried on the next pass.
#
# Start and end events written from a hook carry the pid of the Claude Code
# process that fired it, since one session id can be open in two processes
# at once; session-status.sh matches each end to its own process's start.
# Events written any other way (`close`, a desk-run call's own start/end)
# carry none. A start with a pid also records that process's terminal
# (`tty`, as `ps` names it) when it has one, so the session's tab can be told
# apart later (claude/close-session.sh).
#
# Must never fail the session it's hooked into: every path exits 0, and
# whatever goes wrong is logged instead of surfaced.
set -u

STORE_DIR="${CLAUDE_SESSION_STORE:-$HOME/.local/state/claude/session-events}"
LOG_FILE="${CLAUDE_SESSION_RECORDER_LOG:-$HOME/.local/state/claude/session-recorder.log}"
BOOT_MARKER="$STORE_DIR/.last-pruned-boot"

log_error() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ 2>/dev/null)" "${1:-recorder}" "${2:-}" \
        >> "$LOG_FILE" 2>/dev/null
}

# A boot id, so a resume within the same boot and a resume across a reboot
# are both just another start event — nothing here needs to tell them apart.
boot_id() {
    if [ -r /proc/stat ]; then
        awk '/^btime/ {print $2}' /proc/stat
    else
        sysctl -n kern.boottime 2>/dev/null \
            | sed -n 's/.*{[[:space:]]*sec[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p'
    fi
}

# Deletes a session's record once its transcript is gone — Claude Code's own
# retention already decided the record isn't worth keeping. Gated on a boot
# marker so the full scan runs at most once per boot, never on every session
# start. A recorded path can name a transcript that never existed (a session
# resumed from another directory is given that directory's project folder),
# so the transcript counts as present if any start's path exists, or the
# session's transcript sits in a sibling project folder of one.
maybe_prune() {
    local boot=$1 last_boot="" f tp sid g keep
    [ -f "$BOOT_MARKER" ] && last_boot=$(cat "$BOOT_MARKER" 2>/dev/null)
    [ "$last_boot" = "$boot" ] && return 0
    for f in "$STORE_DIR"/*.jsonl; do
        [ -f "$f" ] || continue
        sid=$(basename "$f" .jsonl)
        keep=""
        while IFS= read -r tp; do
            [ -e "$tp" ] && { keep=1; break; }
            for g in "$(dirname "$(dirname "$tp")")"/*/"$sid.jsonl"; do
                [ -e "$g" ] && { keep=1; break 2; }
            done
        done < <(jq -r 'select(.event=="start") | .transcript_path // empty | select(. != "")' "$f" 2>/dev/null)
        [ -n "$keep" ] || rm -f "$f"
    done
    printf '%s' "$boot" > "$BOOT_MARKER" 2>/dev/null
}

# The Claude Code process a hook was fired by: the parent, or the
# grandparent when the hook command went through `sh -c`. Only asked for
# input that came from a real hook (it names hook_event_name), so a direct
# call from a script run inside a Claude Code session never records that
# session's pid as its own.
claude_pid() {
    local pid=$PPID ppid comm _
    for _ in 1 2; do
        read -r ppid comm < <(ps -o ppid=,comm= -p "$pid" 2>/dev/null) || return 1
        case "$comm" in
            claude|*/claude) printf '%s' "$pid"; return 0 ;;
            sh|*/sh|bash|*/bash|zsh|*/zsh|dash|*/dash) pid=$ppid ;;
            *) return 1 ;;
        esac
    done
    return 1
}

hook_pid() { # hook JSON
    [ -n "$(printf '%s' "$1" | jq -r '.hook_event_name // empty' 2>/dev/null)" ] || return 1
    claude_pid
}

# Appends an end event to $1 with reason $2 and pid $3 (empty when unknown).
# Every end is appended; which run it ends, and whether it is a duplicate
# (a `close` and then the process's own SessionEnd), is the reader's call.
append_end() {
    local file=$1 reason=$2 pid=${3:-}
    jq -cn --arg reason "$reason" --argjson time "$(date +%s)" --arg pid "$pid" \
        '{event:"end", time:$time, reason:$reason} + (if $pid != "" then {pid: ($pid | tonumber)} else {} end)' \
        >> "$file" 2>>"$LOG_FILE"
}

# Prints a SessionStart `systemMessage` (shown to the user) when another
# live Claude Code process already holds session $1; $2 is this hook's own
# process. Claude Code names each pid file after its pid and a new process
# overwrites a reused pid's file, so a live `claude` behind a pid file that
# names this session is that session's process; no start-time check needed.
warn_if_open_elsewhere() { # sid own_pid
    local sid=$1 own=$2 dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions" other tty comm where=""
    local files=()
    [ -d "$dir" ] && files=("$dir"/*.json)
    [ -e "${files[0]:-}" ] || return 0
    while IFS= read -r other; do
        [ -n "$other" ] && [ "$other" != "$own" ] || continue
        read -r tty comm < <(ps -o tty=,comm= -p "$other" 2>/dev/null) || continue
        case "$comm" in claude|*/claude) ;; *) continue ;; esac
        case "$tty" in ''|'?'|'??') tty="no tty" ;; esac
        where="${where:+$where, }$tty, pid $other"
    done < <(jq -r --arg sid "$sid" 'select(.sessionId == $sid) | .pid' "${files[@]}" 2>/dev/null)
    [ -n "$where" ] || return 0
    jq -cn --arg where "$where" '{systemMessage: ("This session is already open in another Claude Code process (\($where)). Both write the same transcript; close one of them.")}'
}

start_event() {
    local input sid file
    input=$(cat)
    sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>>"$LOG_FILE")
    if [ -z "$sid" ]; then
        log_error start "missing session_id"
        return
    fi
    case "$sid" in */*|.*) log_error start "unsafe session_id: $sid"; return ;; esac
    mkdir -p "$STORE_DIR" 2>/dev/null
    # Prune before writing this call's own record, never after: a transcript
    # file may not exist on disk yet at the instant its own SessionStart
    # fires, and pruning afterwards would delete the record this same call
    # just wrote.
    maybe_prune "$(boot_id)"
    file="$STORE_DIR/$sid.jsonl"
    # A desk-run call that isn't
    # --restricted still loads this hook via the user's real settings (merged in
    # alongside the call's own deny-hook settings file), so it would record
    # a real SessionStart on its own — the runner never also calls this
    # script itself for that same call (that would double-record). Instead
    # the runner sets DESK_HEADLESS=1 in the call's own environment, and
    # this hook tags the event `source: desk-run` itself rather than
    # whatever Claude Code's own hook JSON reports (normally "startup"),
    # so session-status.sh's reader and the 16:30 capture step both see
    # exactly the same source a manually-recorded (--restricted) call gets.
    local source_override="" pid
    [ -n "${DESK_HEADLESS:-}" ] && source_override="desk-run"
    pid=$(hook_pid "$input") || pid=""
    local tty=""
    if [ -n "$pid" ]; then
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        case "$tty" in '?'|'??') tty="" ;; esac
    fi
    printf '%s' "$input" | jq -c --arg boot "$(boot_id)" --argjson time "$(date +%s)" --arg override "$source_override" --arg pid "$pid" --arg tty "$tty" '
        {event:"start", time:$time,
         source:(if $override != "" then $override else (.source // "unknown") end),
         cwd:(.cwd // ""), transcript_path:(.transcript_path // ""), boot:$boot}
        + (if $pid != "" then {pid: ($pid | tonumber)} else {} end)
        + (if $tty != "" then {tty: $tty} else {} end)
    ' >> "$file" 2>>"$LOG_FILE"
    [ -z "$pid" ] || warn_if_open_elsewhere "$sid" "$pid" 2>>"$LOG_FILE"
}

end_event() {
    local input sid file reason
    input=$(cat)
    sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>>"$LOG_FILE")
    if [ -z "$sid" ]; then
        log_error end "missing session_id"
        return
    fi
    case "$sid" in */*|.*) log_error end "unsafe session_id: $sid"; return ;; esac
    reason=$(printf '%s' "$input" | jq -r '.reason // "other"' 2>>"$LOG_FILE")
    file="$STORE_DIR/$sid.jsonl"
    append_end "$file" "$reason" "$(hook_pid "$input")"
}

close_verb() {
    local sid=$1 file
    if [ -z "$sid" ]; then
        log_error close "missing session_id argument"
        return
    fi
    case "$sid" in */*|.*) log_error close "unsafe session_id: $sid"; return ;; esac
    mkdir -p "$STORE_DIR" 2>/dev/null
    file="$STORE_DIR/$sid.jsonl"
    append_end "$file" "closed-by-pass"
}

# Appends a plain `close-failed` event to $1's own file. It is only ever
# written once, right after the close step's own SIGTERM+recheck confirms
# the session is still alive (steps.sh's desk_step_close).
close_failed_verb() {
    local sid=$1 file
    if [ -z "$sid" ]; then
        log_error close-failed "missing session_id argument"
        return
    fi
    case "$sid" in */*|.*) log_error close-failed "unsafe session_id: $sid"; return ;; esac
    mkdir -p "$STORE_DIR" 2>/dev/null
    file="$STORE_DIR/$sid.jsonl"
    jq -cn --argjson time "$(date +%s)" '{event:"close-failed", time:$time}' >> "$file" 2>>"$LOG_FILE"
}

case "${1:-}" in
    start) start_event ;;
    end) end_event ;;
    close) close_verb "${2:-}" ;;
    close-failed) close_failed_verb "${2:-}" ;;
    *) log_error main "unknown verb: ${1:-}" ;;
esac
exit 0
