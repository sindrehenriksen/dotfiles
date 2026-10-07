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
# Wired from settings.json on `Notification` (matcher limited to the
# needs-you types below) and on `PreToolUse` for the tools that block on
# the user. Hook JSON on stdin. The bell goes out through the hook JSON
# field `terminalSequence`, which Claude Code writes itself: a hook has no
# controlling terminal, so writing BEL to stdout or /dev/tty would not
# reach one. The field is ignored in `-p` print mode, so headless runs
# never ring.
#
# Never fails the session: every path exits 0, silently, when in doubt.
set -u

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

kind="$(printf '%s' "$input" | jq -r '
    if .hook_event_name == "Notification" then
        (.notification_type // "" ) as $t
        | if ($t | IN("permission_prompt", "elicitation_dialog",
                      "elicitation_url_dialog", "agent_needs_input"))
          then "ring"
          elif $t == "idle_prompt" then "idle"
          else "quiet" end
    elif .hook_event_name == "PreToolUse" then
        if (.tool_name // "" | IN("AskUserQuestion", "ExitPlanMode"))
        then "ring" else "quiet" end
    else "quiet" end' 2>/dev/null)" || exit 0

# Prints ring or quiet for the turn `prompt_id`, from the transcript tail.
# Tool-result user records carry the turn's promptId too, so the turn is
# everything after the last record with it, up to the next turn. Widens the tail once.
idle_verdict() {
    local path="$1" pid="$2" size bytes v
    [ -n "$path" ] && [ -n "$pid" ] && [ -r "$path" ] || return 0
    size="$(wc -c <"$path" 2>/dev/null | tr -d ' ')" || return 0
    for bytes in 524288 8388608; do
        v="$(tail -c "$bytes" "$path" 2>/dev/null | jq -nrR --arg pid "$pid" '
            [inputs | fromjson? | select(type == "object")] as $r
            | ([$r | to_entries[] | select(.value.type == "user" and .value.promptId == $pid) | .key] | last) as $i
            | if $i == null then "missing"
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
    kind="$(idle_verdict \
        "$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)" \
        "$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null)")"
fi

[ "$kind" = "ring" ] && printf '{"terminalSequence":"\\u0007"}\n'
exit 0
