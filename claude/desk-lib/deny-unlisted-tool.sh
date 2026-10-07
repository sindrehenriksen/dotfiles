#!/usr/bin/env bash
# The PreToolUse hook a connector model call is launched with. Every positional argument after an optional `--pinned <file>
# --` is one allowed tool name for THIS call only; the hook reads the
# tool-call JSON Claude Code feeds it on stdin (`tool_name`, `tool_input`)
# and exits 2 — an unconditional, override-proof deny, regardless of what
# any settings file's own permission rules would otherwise allow — the
# moment the tool isn't one of them.
#
# `--allowedTools` plus `--permission-mode dontAsk` already refuse an
# unlisted tool on their own; this hook is the second, independent layer a
# connector call needs specifically because loading user settings (required
# to load the claude.ai connectors at all) also loads the user's 220 allow rules,
# which this hook denies regardless of.
#
# `--pinned <file>`: <file> holds a JSON array of exact tool_input shapes
# this call may use, e.g. one `{"threadId": "...", "labelIds":
# ["UNREAD"]}` per runner-pinned thread id. When given, an otherwise-
# allowed tool call is still denied unless its own tool_input deep-equals
# one array entry exactly (jq object equality, so key order never
# matters) — never trusting the model to only ask for the ids it was told
# about.
#
# `--ignore-keys <k1,k2>`: with `--pinned`, these keys are dropped from
# tool_input before the comparison, for a field the tool takes that has no
# effect outside the call (the watch pass's send pins `to` and `message`
# and ignores SendMessage's transcript-only `summary`). Any other extra
# key still fails the comparison.
#
# `--scratch <dir>` (a judge/close call's own second layer under its
# scoped `Read(<dir>/**)` --allowedTools entry, steps.sh's
# desk_step_allowed_tools): when given, a Read call is additionally
# denied unless its own tool_input.file_path resolves (symlinks and
# `..` included) under <dir> — never trusting the --allowedTools glob
# alone, the same way --pinned never trusts a connector tool's own
# claimed args.
#
# Fails closed: a hook that exits 1 (or crashes) is only a non-blocking
# error to Claude Code, so the call would go through. Every path out of this
# script that is not the one explicit allow at the bottom exits 2, whatever
# went wrong (a missing jq or realpath, a missing option argument, an
# unbound variable, a failing command).
set -u -E

allowed="false"
trap '[ "$allowed" = "true" ] || exit 2' EXIT
trap 'exit 2' ERR

pinned_file=""
scratch_dir=""
ignore_keys=""
while :; do
	case "${1:-}" in
		--pinned)
			[ $# -ge 2 ] || { echo "desk deny-hook: --pinned needs a file — denying" >&2; exit 2; }
			pinned_file="$2"
			shift 2
			;;
		--ignore-keys)
			[ $# -ge 2 ] || { echo "desk deny-hook: --ignore-keys needs a list — denying" >&2; exit 2; }
			ignore_keys="$2"
			shift 2
			;;
		--scratch)
			[ $# -ge 2 ] || { echo "desk deny-hook: --scratch needs a dir — denying" >&2; exit 2; }
			scratch_dir="$2"
			shift 2
			;;
		--)
			shift
			break
			;;
		*) break ;;
	esac
done

input="$(cat)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

if [ -z "$tool_name" ]; then
	echo "desk deny-hook: no tool_name in hook input" >&2
	exit 2
fi

allowed_name="false"
for candidate in "$@"; do
	if [ "$tool_name" = "$candidate" ]; then
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
	tool_input="$(printf '%s' "$input" | jq -c --arg ign "$ignore_keys" \
		'(.tool_input // {}) | if $ign == "" then . else delpaths([$ign | split(",")[] | [.]]) end' 2>/dev/null)"
	if ! jq -e --argjson want "$tool_input" 'any(.[]?; . == $want)' "$pinned_file" > /dev/null 2>&1; then
		echo "desk deny-hook: '$tool_name' tool_input isn't one of the pinned set ($pinned_file)" >&2
		exit 2
	fi
fi

if [ -n "$scratch_dir" ] && [ "$tool_name" = "Read" ]; then
	file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
	if [ -z "$file_path" ]; then
		echo "desk deny-hook: Read call has no tool_input.file_path — denying" >&2
		exit 2
	fi
	# realpath resolves symlinks and `.`/`..` on both sides, so a string
	# that merely starts with "$scratch_dir/" (e.g. one built from
	# "$scratch_dir/../../etc/passwd") doesn't fool this. It also requires
	# the path to actually exist (no GNU -m/--canonicalize-missing here),
	# which fails closed on a Read of something that isn't there anyway —
	# rather than trust a path this hook can't verify.
	resolved_scratch="$(realpath -q "$scratch_dir" 2> /dev/null)"
	resolved_path="$(realpath -q "$file_path" 2> /dev/null)"
	if [ -z "$resolved_scratch" ] || [ -z "$resolved_path" ]; then
		echo "desk deny-hook: couldn't resolve '$file_path' against the scratch dir ($scratch_dir) — denying" >&2
		exit 2
	fi
	case "$resolved_path" in
		"$resolved_scratch" | "$resolved_scratch"/*) : ;;
		*)
			echo "desk deny-hook: Read of '$file_path' is outside this call's scratch dir ($scratch_dir) — denying" >&2
			exit 2
			;;
	esac
fi

allowed="true"
exit 0
