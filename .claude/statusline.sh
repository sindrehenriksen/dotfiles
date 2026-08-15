#!/usr/bin/env bash
# Claude Code status line. Reads JSON on stdin and prints a single line:
#   [<vim>] t:<tokens> (<ctx%>) | [!mem:<rss>] 5h:<rem%> w:<rem%> | <model>[ th:<state>] | <dir>[ <branch>]
# th:<state> is the effort level when thinking is on, "on" when thinking is on but the
# model has no effort parameter, or "off" when thinking is disabled.
# !mem: appears only above MEM_WARN_KB — see below.
# Segments are omitted when their source fields are absent.

input=$(cat)

tot=$(jq -r '(.context_window.total_input_tokens + .context_window.total_output_tokens) // 0' <<<"$input")
if [ "$tot" -ge 1000 ]; then
    tok=$(awk -v n="$tot" 'BEGIN{printf "%.1fk", n/1000}')
else
    tok="$tot"
fi

used=$(jq -r '.context_window.used_percentage // empty' <<<"$input")
five_rem=$(jq -r 'if .rate_limits.five_hour.used_percentage != null then (100 - .rate_limits.five_hour.used_percentage | round | tostring) else empty end' <<<"$input")
week_rem=$(jq -r 'if .rate_limits.seven_day.used_percentage != null then (100 - .rate_limits.seven_day.used_percentage | round | tostring) else empty end' <<<"$input")

cwd=$(jq -r '.cwd // "."' <<<"$input")
branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
dir=${cwd/#$HOME/\~}

# Strip optional "Claude " prefix, lowercase family, keep family + version (e.g. "opus 4.7").
model=$(jq -r '.model.display_name // empty' <<<"$input" | sed -E 's/^Claude //' | awk 'NF>0 {n = tolower($1); if (NF >= 2) n = n " " $2; print n}')

effort=$(jq -r '.effort.level // empty' <<<"$input")
thinking=$(jq -r 'if has("thinking") then .thinking.enabled else empty end' <<<"$input")
# .vim is present only when vim mode is enabled. First letter of mode (N/I/V) — VISUAL and VISUAL LINE both collapse to V.
vim_mode=$(jq -r '.vim.mode // empty' <<<"$input")

left="t:${tok}"
[ -n "$used" ] && left="$left ($(printf '%.0f' "$used")%)"
[ -n "$vim_mode" ] && left="[${vim_mode:0:1}] $left"

# Resident memory of the Claude Code process this status line was spawned from.
# Long sessions (many agents, forks especially) have grown past 7 GB on a 13 GiB
# box and been OOM-killed mid-run; this is the cue to /clear or start fresh.
# Takes the largest RSS among our ancestors rather than matching a process name:
# the native binary's comm is its version string ("2.1.232"), which would silently
# stop matching on upgrade — and a warning that fails quietly is worse than none.
# Only shells and Claude itself are above us, so the max is unambiguous.
MEM_WARN_KB=3145728 # 3 GiB — well clear of normal use (<2 GB), well under the 6 GiB cgroup cap
mem=""
mem_pid=$$
mem_max=0
for _ in 1 2 3 4 5 6; do
    [ -r "/proc/$mem_pid/status" ] || break
    mem_rss=0
    mem_next=""
    while read -r mem_k mem_v _; do
        case "$mem_k" in
            VmRSS:) mem_rss=$mem_v ;;
            PPid:) mem_next=$mem_v ;;
        esac
    done <"/proc/$mem_pid/status"
    [ "$mem_rss" -gt "$mem_max" ] && mem_max=$mem_rss
    [ -n "$mem_next" ] && [ "$mem_next" != "0" ] && [ "$mem_next" != "1" ] || break
    mem_pid=$mem_next
done
[ "$mem_max" -ge "$MEM_WARN_KB" ] && mem=$(awk -v k="$mem_max" 'BEGIN{printf "!mem:%.1fG", k/1048576}')

middle=""
[ -n "$mem" ] && middle="$mem"
[ -n "$five_rem" ] && middle="${middle:+$middle }5h:${five_rem}%"
[ -n "$week_rem" ] && middle="${middle:+$middle }w:${week_rem}%"

right="$model"
case "$thinking" in
    true)  right="${right:+$right }th:${effort:-on}" ;;
    false) right="${right:+$right }th:off" ;;
esac

out="$left"
[ -n "$middle" ] && out="$out | $middle"
[ -n "$right" ] && out="$out | $right"
prompt="$dir"
[ -n "$branch" ] && prompt="$prompt $branch"
out="$out | $prompt"
echo "$out"
