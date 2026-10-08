#!/usr/bin/env bash
# Rings the terminal bell when Claude Code needs the user: a permission
# prompt, a question, a plan awaiting approval, or a finished turn that
# ends waiting on him. A plain finish stays quiet (Claude Code's own tab
# title shows it); an idle turn rings only when its last assistant text
# starts with `[needs-you]` or its last line is a direct question outside
# code blocks and quotes. The text comes from the transcript tail (they
# reach tens of MB), the turn found by matching `prompt_id`; a turn that
# cannot be found stays quiet. Ghostty's default `bell-features` includes `title`, so the bell
# prepends a marker to that tab's title until it is focused; Claude's own
# title is never touched.
#
# Mid-turn: on every `PreToolUse` the hook scans the
# transcript bytes appended since its last call for an assistant text with
# a line starting `[needs-you]` (outside code fences) and rings at once,
# so a session that flags a block and carries on does not make him wait
# for the turn to end. Per session it keeps a state file under
# `${XDG_STATE_HOME:-~/.local/state}/claude/input-bell-<session id>`: the
# byte offset scanned so far (first call: the last 4 MB, since a session's
# first tool call can follow its marker by hundreds of KB of attachment
# records; an offset past
# EOF restarts there) and the uuids of the assistant records already
# rung. An unchanged transcript costs one `jq` call and a `wc`.
# Dedup: the idle check stays quiet when any assistant record of its turn
# was rung mid-turn, so a final reply repeating the same ask is the same
# ask and does not ring again; a new turn with a new marker rings.
# The assistant text is already in the transcript when `PreToolUse` fires
# (checked on 2.1.292), so no later event is needed.
#
# Wired from settings.json on `Notification` (matcher limited to the
# needs-you types below) and on `PreToolUse` for every tool
# (AskUserQuestion and ExitPlanMode ring directly). Hook JSON on stdin.
# The bell goes out through the hook JSON
# field `terminalSequence`, which Claude Code writes itself: a hook has no
# controlling terminal, so writing BEL to stdout or /dev/tty would not
# reach one. The field is ignored in `-p` print mode, so headless runs
# never ring.
#
# Never fails the session: every path exits 0, silently, when in doubt.
set -u

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

# One jq call yields everything: kind, session id, transcript path, prompt id.
fields="$(printf '%s' "$input" | jq -r '
    (if .hook_event_name == "Notification" then
        (.notification_type // "" ) as $t
        | if ($t | IN("permission_prompt", "elicitation_dialog",
                      "elicitation_url_dialog", "agent_needs_input"))
          then "ring"
          elif $t == "idle_prompt" then "idle"
          else "quiet" end
    elif .hook_event_name == "PreToolUse" then
        if (.tool_name // "" | IN("AskUserQuestion", "ExitPlanMode"))
        then "ring" else "midturn" end
    else "quiet" end),
    (.session_id // ""), (.transcript_path // ""), (.prompt_id // "")
    | gsub("[\\t\\n]"; " ")' 2>/dev/null)" || exit 0
{ IFS= read -r kind; IFS= read -r sid; IFS= read -r tpath; IFS= read -r pid; } <<<"$fields"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude"
sid_safe="${sid//[^A-Za-z0-9_-]/}"
state_file=""
[ -n "$sid_safe" ] && state_file="$STATE_DIR/input-bell-$sid_safe"

# Offset and rung uuids live in the state file: line 1 is the byte offset
# already scanned, the rest are uuids of assistant records already rung.
rung_list() { [ -n "$state_file" ] && [ -r "$state_file" ] && tail -n +2 "$state_file" 2>/dev/null | tr '\n' ' '; }

# Mid-turn marker scan. Reads only the bytes appended since the last call
# (the last 4 MB on the first call or after the file shrank), stops at the
# last complete line, and prints "ring" for an assistant record carrying a
# line that starts with `[needs-you]`, outside code fences, not rung yet.
midturn_verdict() {
    [ -n "$state_file" ] && [ -n "$tpath" ] && [ -r "$tpath" ] || return 0
    local size off="" start first=0 skip chunk body consumed found rung new
    size="$(wc -c <"$tpath" 2>/dev/null | tr -d ' ')" || return 0
    [ -n "$size" ] || return 0
    [ -r "$state_file" ] && off="$(head -n 1 "$state_file" 2>/dev/null)"
    case "$off" in ''|*[!0-9]*) off="" ;; esac
    if [ -z "$off" ] || [ "$off" -gt "$size" ]; then
        first=1; start=$((size > 4194304 ? size - 4194304 : 0))
    else
        start="$off"
    fi
    [ "$size" -gt "$start" ] || return 0
    chunk="$(tail -c +$((start + 1)) "$tpath" 2>/dev/null | head -c $((size - start)); printf x)" || return 0
    chunk="${chunk%x}"
    case "$chunk" in *$'\n'*) ;; *) return 0 ;; esac
    body="${chunk%$'\n'*}"
    consumed=$(( $(printf '%s\n' "$body" | wc -c) ))
    # A tail read that starts mid-file begins inside a line: drop it. Done
    # with tail, not `${body#*$'\n'}`, which is quadratic in that line's
    # length and can take seconds on one attachment record.
    skip=1
    [ "$first" = 1 ] && [ "$start" -gt 0 ] && skip=2
    rung="$(rung_list)"
    found="$(printf '%s\n' "$body" | tail -n +"$skip" | jq -nrR --arg rung "$rung" '
        ($rung | split(" ")) as $done
        | [inputs | fromjson? | select(type == "object" and .type == "assistant")
           | select((.uuid // "") as $u | ($done | index($u)) | not)
           | select([.message.content | if type == "array" then .[] else empty end
                     | select(.type == "text") | .text
                     | split("\n")
                     | reduce .[] as $l ({f: false, hit: false};
                         if ($l | test("^\\s*(```|~~~)")) then .f |= not
                         elif .f then .
                         elif ($l | test("^\\s*\\[needs-you\\]")) then .hit = true
                         else . end) | .hit] | any)
           | .uuid // "x"] | .[]' 2>/dev/null)" || return 0
    new="$(printf '%s\n' "$rung" | tr ' ' '\n' | grep -v '^$'; printf '%s\n' "$found" | grep -v '^$')"
    new="$((start + consumed))
$(printf '%s\n' "$new" | grep -v '^$' | tail -n 20)"
    mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$new" >"$state_file" 2>/dev/null
    [ -n "$found" ] && printf ring
    return 0
}

# Prints ring or quiet for the turn `prompt_id`, from the transcript tail.
# Tool-result user records carry the turn's promptId too, so the turn is
# everything after the last record with it, up to the next turn. Widens the tail once.
idle_verdict() {
    local path="$1" pid="$2" size bytes v
    [ -n "$path" ] && [ -n "$pid" ] && [ -r "$path" ] || return 0
    size="$(wc -c <"$path" 2>/dev/null | tr -d ' ')" || return 0
    for bytes in 524288 8388608; do
        v="$(tail -c "$bytes" "$path" 2>/dev/null | jq -nrR --arg pid "$pid" --arg rung "$(rung_list)" '
            ($rung | split(" ")) as $done
            | [inputs | fromjson? | select(type == "object")] as $r
            | ([$r | to_entries[] | select(.value.type == "user" and .value.promptId == $pid) | .key] | last) as $i
            | if $i == null then "missing"
              elif ([label $out | $r[$i + 1:][]
                  | if .type == "user" and .promptId != null and .promptId != $pid then break $out else . end
                  | select(.type == "assistant") | (.uuid // "x") as $u | ($done | index($u))] | any)
              then "quiet"
              else
                ([label $out | $r[$i + 1:][]
                  | if .type == "user" and .promptId != null and .promptId != $pid then break $out else . end
                  | select(.type == "assistant")
                  | .message.content | if type == "array" then .[] else empty end
                  | select(.type == "text") | .text] | last // "") as $t
                | if ($t | sub("^\\s+"; "") | startswith("[needs-you]")) then "ring"
                  else
                    # Last non-empty line, where anything fenced counts as code.
                    (reduce ($t | split("\n")[]) as $l ({f: false, last: null};
                        if ($l | test("^\\s*(```|~~~)")) then .f |= not | .last = "fence"
                        elif .f then .last = "fence"
                        elif ($l | test("^\\s*$")) then .
                        else .last = $l end) | .last) as $last
                    | if $last == null or $last == "fence" or ($last | test("^\\s*>")) then "quiet"
                      elif ($last | test("\\?[\\s*_)]*$")) then "ring"
                      else "quiet" end
                  end
              end' 2>/dev/null)" || return 0
        if [ "$v" = ring ] || [ "$v" = quiet ]; then printf '%s' "$v"; return 0; fi
        [ "$size" -le "$bytes" ] && return 0
    done
}

if [ "$kind" = idle ]; then
    kind="$(idle_verdict "$tpath" "$pid")"
elif [ "$kind" = midturn ]; then
    kind="$(midturn_verdict)"
fi

[ "$kind" = "ring" ] && printf '{"terminalSequence":"\\u0007"}\n'
exit 0
