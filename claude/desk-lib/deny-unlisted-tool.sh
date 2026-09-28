#!/usr/bin/env bash
# The PreToolUse hook a connector model call is launched with (design.md
# §5 "Isolation, enforced" / the Runner decisions note: "the wall is a
# per-call allowlist PreToolUse hook ... it denies every tool not on that
# call's exact list, including anything his user allow rules would
# permit"). Every positional argument after an optional `--pinned <file>
# --` is one allowed tool name for THIS call only; the hook reads the
# tool-call JSON Claude Code feeds it on stdin (`tool_name`, `tool_input`)
# and exits 2 — an unconditional, override-proof deny, regardless of what
# any settings file's own permission rules would otherwise allow — the
# moment the tool isn't one of them.
#
# `--allowedTools` plus `--permission-mode dontAsk` already refuse an
# unlisted tool on their own; this hook is the second, independent layer a
# connector call needs specifically because loading user settings (required
# to load the claude.ai connectors at all) also loads his 220 allow rules,
# which this hook denies regardless of.
#
# `--pinned <file>` (W's own extra layer, design.md §5 "The one unattended
# external write"): <file> holds a JSON array of exact tool_input shapes
# this call may use, e.g. one `{"threadId": "...", "labelIds":
# ["UNREAD"]}` per runner-pinned thread id. When given, an otherwise-
# allowed tool call is still denied unless its own tool_input deep-equals
# one array entry exactly (jq object equality, so key order never
# matters) — never trusting the model to only ask for the ids it was told
# about.
set -u

pinned_file=""
if [ "${1:-}" = "--pinned" ]; then
	pinned_file="$2"
	shift 2
	[ "${1:-}" = "--" ] && shift
fi

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

if [ -z "$tool_name" ]; then
	echo "desk deny-hook: no tool_name in hook input" >&2
	exit 2
fi

allowed_name="false"
for allowed in "$@"; do
	if [ "$tool_name" = "$allowed" ]; then
		allowed_name="true"
		break
	fi
done
if [ "$allowed_name" != "true" ]; then
	echo "desk deny-hook: '$tool_name' is not on this call's allowlist ($*)" >&2
	exit 2
fi

if [ -n "$pinned_file" ]; then
	# A pinned call names a file that's SUPPOSED to exist — the caller
	# only ever passes --pinned when it has a real exact-set file to
	# write (desk_write_deny_hook_settings). Missing (or unreadable, or
	# not valid JSON) is never "no pinning configured, allow it through"
	# (that's what omitting --pinned entirely means) — it's "the pinning
	# this call was supposed to enforce is broken", and a broken safety
	# check has to fail closed, not fail open.
	if [ ! -f "$pinned_file" ]; then
		echo "desk deny-hook: --pinned file is missing ($pinned_file) — denying" >&2
		exit 2
	fi
	tool_input="$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)"
	if ! jq -e --argjson want "$tool_input" 'any(.[]?; . == $want)' "$pinned_file" > /dev/null 2>&1; then
		echo "desk deny-hook: '$tool_name' tool_input isn't one of the pinned set ($pinned_file)" >&2
		exit 2
	fi
fi

exit 0
