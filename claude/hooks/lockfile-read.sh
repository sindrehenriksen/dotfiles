#!/usr/bin/env bash
# PreToolUse hook (matcher `Read|Bash`): keeps lockfiles out of the context.
# Paging through a pnpm-lock.yaml cost two agents about 400k tokens; a
# lockfile is queried (`rg -n`, the package manager), not read.
#
# Read: denied for a lockfile unless it is a window of at most MAX_LINES
# (`limit`), so an agent can look at the spot `rg -n` pointed to.
# Bash: denied only for a plain dump of one whole lockfile: cat/less/more/bat
# on it, or head/tail/sed -n asking for more than MAX_LINES, as the last
# stage of a pipeline (output piped on, or redirected, never reaches the
# context). Anything else that merely names a lockfile is allowed: when in
# doubt, allow.
#
# Fast path: exits before jq unless the raw input names a lockfile. Never
# fails the session: every other path exits 0 silently.
set -u

MAX_LINES=200
input="$(cat)"

case "$input" in
*pnpm-lock.yaml* | *package-lock.json* | *yarn.lock* | *bun.lock* | *uv.lock* | *poetry.lock* | \
    *Cargo.lock* | *Gemfile.lock* | *composer.lock* | *go.sum* | *flake.lock* | *npm-shrinkwrap.json* | \
    *actions.lock*) ;;
*) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

is_lockfile() {
    case "${1##*/}" in
    pnpm-lock.yaml | package-lock.json | yarn.lock | bun.lock | bun.lockb | uv.lock | poetry.lock | \
        Cargo.lock | Gemfile.lock | composer.lock | go.sum | flake.lock | npm-shrinkwrap.json | \
        actions.lock) return 0 ;;
    esac
    return 1
}

deny() {
    jq -nc --arg r "$1 A lockfile is queried, not read: use \`rg -n <pkg> <lockfile>\`, the package manager (\`pnpm why <pkg>\`, \`npm ls <pkg>\`, \`uv tree --package <pkg>\`, \`cargo tree -i <pkg>\`), \`git diff --stat\` for a change, or Read with offset and a limit of at most $MAX_LINES lines." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

{ IFS= read -r tool; IFS= read -r path; IFS= read -r limit; } < <(printf '%s' "$input" | jq -r '
    (.tool_name // ""),
    (if .tool_name == "Read" then (.tool_input.file_path // "") else (.tool_input.command // "" | gsub("\n"; "\u0001")) end),
    (.tool_input.limit // "" | tostring)' 2>/dev/null) || exit 0

if [ "$tool" = Read ]; then
    is_lockfile "$path" || exit 0
    if [[ $limit =~ ^[0-9]+$ ]] && [ "$limit" -le "$MAX_LINES" ] && [ "$limit" -gt 0 ]; then exit 0; fi
    deny "Reading $path whole (or in a large window) loads the lockfile into context."
fi
[ "$tool" = Bash ] || exit 0

# Splits on newline, ;, && and || only; a pipeline keeps its last stage.
cmd="${path//$'\001'/$'\n'}"
cmd="${cmd//&&/$'\n'}"
cmd="${cmd//||/$'\n'}"
cmd="${cmd//;/$'\n'}"
while IFS= read -r seg; do
    [[ $seg == *'>'* ]] && continue
    seg="${seg##*|}"
    seg="${seg//[\"\']/}"
    read -ra w <<<"$seg"
    [ "${#w[@]}" -gt 0 ] || continue
    i=0
    while [ "$i" -lt "${#w[@]}" ] && { [ "${w[$i]}" = sudo ] || [[ ${w[$i]} == *=* ]]; }; do i=$((i + 1)); done
    prog="${w[$i]:-}"
    prog="${prog##*/}"
    args=("${w[@]:$((i + 1))}")
    lock=""
    for a in "${args[@]}"; do is_lockfile "$a" && lock="$a"; done
    [ -n "$lock" ] || continue
    case "$prog" in
    cat | less | more | bat | batcat) deny "\`$prog $lock\` dumps the whole lockfile into context." ;;
    head | tail)
        n=10
        for ((k = 0; k < ${#args[@]}; k++)); do
            a="${args[$k]}"
            case "$a" in
            -n) n="${args[$((k + 1))]:-10}" ;;
            -n*) n="${a#-n}" ;;
            --lines=*) n="${a#--lines=}" ;;
            -[0-9]*) n="${a#-}" ;;
            esac
        done
        if [[ $n == +* ]]; then n=999999; fi
        [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt "$MAX_LINES" ] && deny "\`$prog\` of $n lines of $lock loads most of the lockfile into context."
        ;;
    sed)
        [[ " ${args[*]} " == *" -n "* ]] || continue
        for a in "${args[@]}"; do
            if [[ $a =~ ^([0-9]+),([0-9]+)p$ ]]; then
                [ $((BASH_REMATCH[2] - BASH_REMATCH[1] + 1)) -gt "$MAX_LINES" ] && deny "\`sed -n $a\` on $lock loads a large part of the lockfile into context."
            elif [ "$a" = p ] || [ "$a" = '1,$p' ]; then
                deny "\`sed -n $a\` on $lock dumps the whole lockfile into context."
            fi
        done
        ;;
    esac
done <<<"$cmd"
exit 0
