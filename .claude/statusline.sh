#!/usr/bin/env bash
# Claude Code status line. Reads JSON on stdin and prints a single line:
#   [<vim>] t:<tokens> (<ctx%>) | 5h:<rem%> w:<rem%> | <branch> | <model>[ th:<state>]
# th:<state> is the effort level when thinking is on, "on" when thinking is on but the
# model has no effort parameter, or "off" when thinking is disabled.
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

# Strip optional "Claude " prefix, lowercase family, keep family + version (e.g. "opus 4.7").
model=$(jq -r '.model.display_name // empty' <<<"$input" | sed -E 's/^Claude //' | awk 'NF>0 {n = tolower($1); if (NF >= 2) n = n " " $2; print n}')

effort=$(jq -r '.effort.level // empty' <<<"$input")
thinking=$(jq -r 'if has("thinking") then .thinking.enabled else empty end' <<<"$input")
# .vim is present only when vim mode is enabled. First letter of mode (N/I/V) — VISUAL and VISUAL LINE both collapse to V.
vim_mode=$(jq -r '.vim.mode // empty' <<<"$input")

left="t:${tok}"
[ -n "$used" ] && left="$left ($(printf '%.0f' "$used")%)"
[ -n "$vim_mode" ] && left="[${vim_mode:0:1}] $left"

middle=""
[ -n "$five_rem" ] && middle="5h:${five_rem}%"
[ -n "$week_rem" ] && middle="${middle:+$middle }w:${week_rem}%"

right="$model"
case "$thinking" in
    true)  right="${right:+$right }th:${effort:-on}" ;;
    false) right="${right:+$right }th:off" ;;
esac

out="$left"
[ -n "$middle" ] && out="$out | $middle"
[ -n "$branch" ] && out="$out | $branch"
[ -n "$right" ] && out="$out | $right"
echo "$out"
