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
# the "end" event `close` already wrote stays exactly as it was (append_end's
# own first-end-wins rule is for a genuine end, not for this), and this adds
# a plain marker event instead — session-status.sh surfaces it as
# `close_failed`/`close_failed_at` so a survivor is visible as one, not just
# quietly retried on the next pass.
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
# start.
maybe_prune() {
    local boot=$1 last_boot="" f tp
    [ -f "$BOOT_MARKER" ] && last_boot=$(cat "$BOOT_MARKER" 2>/dev/null)
    [ "$last_boot" = "$boot" ] && return 0
    for f in "$STORE_DIR"/*.jsonl; do
        [ -f "$f" ] || continue
        tp=$(jq -r 'select(.event=="start") | .transcript_path' "$f" 2>/dev/null | tail -1)
        if [ -z "$tp" ] || [ ! -e "$tp" ]; then
            rm -f "$f"
        fi
    done
    printf '%s' "$boot" > "$BOOT_MARKER" 2>/dev/null
}

# Appends an end event to $1 with reason $2 — unless the run that started
# most recently in this file already has one. First end in a run wins, so a
# `close` landing just before the real SessionEnd fires isn't overwritten by
# it, and a stray double SessionEnd doesn't overwrite itself either.
append_end() {
    local file=$1 reason=$2 already
    if [ -f "$file" ]; then
        already=$(jq -s '
            ([.[] | .event] | to_entries | map(select(.value=="start")) | last | .key) as $last_start
            | if $last_start == null then false
              else ([.[] | .event] | to_entries | any(.key > $last_start and .value=="end"))
              end
        ' "$file" 2>/dev/null)
        [ "$already" = "true" ] && return 0
    fi
    jq -cn --arg reason "$reason" --argjson time "$(date +%s)" \
        '{event:"end", time:$time, reason:$reason}' >> "$file" 2>>"$LOG_FILE"
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
    local source_override=""
    [ -n "${DESK_HEADLESS:-}" ] && source_override="desk-run"
    printf '%s' "$input" | jq -c --arg boot "$(boot_id)" --argjson time "$(date +%s)" --arg override "$source_override" '
        {event:"start", time:$time,
         source:(if $override != "" then $override else (.source // "unknown") end),
         cwd:(.cwd // ""), transcript_path:(.transcript_path // ""), boot:$boot}
    ' >> "$file" 2>>"$LOG_FILE"
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
    append_end "$file" "$reason"
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

# Appends a plain `close-failed` event to $1's own file — never gated on
# "first wins" like append_end's own end event, since this is only ever
# written once, right after the close step's own SIGTERM+recheck confirms
# the session is still alive (steps.sh's desk_step_close), not raced
# against a real SessionEnd the way `close`/`end` are.
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
