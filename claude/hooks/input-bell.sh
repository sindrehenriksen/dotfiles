#!/usr/bin/env bash
# Rings the terminal bell when Claude Code needs the user: a permission
# prompt, a question, a plan awaiting approval, or an idle session waiting
# on input. Ghostty's default `bell-features` includes `title`, so the bell
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
        | if ($t | IN("permission_prompt", "idle_prompt", "elicitation_dialog",
                      "elicitation_url_dialog", "agent_needs_input"))
          then "ring" else "quiet" end
    elif .hook_event_name == "PreToolUse" then
        if (.tool_name // "" | IN("AskUserQuestion", "ExitPlanMode"))
        then "ring" else "quiet" end
    else "quiet" end' 2>/dev/null)" || exit 0

[ "$kind" = "ring" ] && printf '{"terminalSequence":"\\u0007"}\n'
exit 0
