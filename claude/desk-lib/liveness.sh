#!/usr/bin/env bash
# Whether a pid file's process is the one it names: alive, a `claude`
# process, and started when the pid file says (procStart), so a pid the OS
# has since given to another process never passes for the session. Shared by
# claude/session-status.sh and claude/session-stale.sh. Sourced; the caller
# may set $now_epoch (default: now) and $LIVENESS_TOLERANCE_SECS (default
# $CLAUDE_SESSION_LIVENESS_TOLERANCE, else 3).
set -u
LIVENESS_TOLERANCE_SECS="${LIVENESS_TOLERANCE_SECS:-${CLAUDE_SESSION_LIVENESS_TOLERANCE:-3}}"

is_linux() { [ -r /proc/stat ]; }

# procStart in a pid file has two shapes. On macOS it is a UTC ctime string
# (parsing it with `date -u -j -f` lands on the same epoch `ps` itself
# reports for the process): the one date-parse liveness can't avoid. On
# Linux it is the process's start in clock ticks since boot, exactly field
# 22 of /proc/<pid>/stat, so it is compared with that as it stands. Turning
# it into an epoch (btime + ticks / CLK_TCK) would be wrong wherever the
# wall clock moved since boot: btime is derived from the current clock, so
# it shifts with every correction.
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

# Field 22 of /proc/<pid>/stat (starttime, in clock ticks since boot). The
# command name in field 2 may hold spaces and parentheses, so the fields
# are counted from after its last ")", where field 3 begins.
proc_start_ticks() {
    local stat
    read -r stat < "/proc/$1/stat" 2>/dev/null || return 1
    # shellcheck disable=SC2086 # split into fields on purpose
    set -- ${stat##*) }
    [ -n "${20:-}" ] && printf '%s' "${20}"
}

# check_live <pid> <procStart>: sets $live (true/false) and $tty for one
# pid file entry — alive, a claude process, and started when it says.
check_live() {
    local pid=$1 procstart=$2 etime comm p_epoch etime_secs os_epoch diff
    local now="${now_epoch:-$(date +%s)}"
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
                case "$procstart" in
                    '' | *[!0-9]*) ;;
                    *)
                        [ "$(proc_start_ticks "$pid")" = "$procstart" ] && live="true"
                        return
                        ;;
                esac
                p_epoch=$(parse_utc_ctime "$procstart") || p_epoch=""
                etime_secs=$(parse_etime_secs "$etime") || etime_secs=""
                if [ -n "$p_epoch" ] && [ -n "$etime_secs" ]; then
                    os_epoch=$(( now - etime_secs ))
                    diff=$(( p_epoch > os_epoch ? p_epoch - os_epoch : os_epoch - p_epoch ))
                    [ "$diff" -le "$LIVENESS_TOLERANCE_SECS" ] && live="true"
                fi
                ;;
        esac
    fi
}
