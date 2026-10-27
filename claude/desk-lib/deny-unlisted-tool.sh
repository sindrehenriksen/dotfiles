#!/usr/bin/env bash
# The PreToolUse hook a headless desk call runs with. Every positional
# argument after the options is one tool this call may use; the hook reads
# the tool call Claude Code feeds it on stdin (`tool_name`, `tool_input`)
# and exits 2, a deny no permission rule overrides, the moment the tool is
# not one of them. `--allowedTools` and `--permission-mode dontAsk` already
# refuse an unlisted tool; this is the second, independent layer, and the
# only one that checks a pattern's spec and pinned arguments.
#
# `--pinned <file>`: <file> holds a JSON array of exact tool_input shapes
# this call may use, e.g. the one `{to, message}` a send may make. When given, an otherwise-
# allowed tool call is still denied unless its own tool_input deep-equals
# one array entry exactly (jq object equality, so key order never
# matters) — never trusting the model to only ask for the ids it was told
# about. A call with more than one tool pins each separately: <file> is
# then an object from tool name to that tool's array, and a tool missing
# from it may make no call at all.
#
# `--ignore-keys <k1,k2>`: with `--pinned`, these keys are dropped from
# tool_input before the comparison, for a field the tool takes that has no
# effect outside the call (the follow pass's send pins `to` and `message`
# and ignores SendMessage's transcript-only `summary` and the preview
# fields Claude Code adds to its input). Any other extra key still fails
# the comparison.
#
# An allowed tool written as a pattern, `Name(spec)`, admits a call to
# Name only when its input fits spec, as the same entry does in
# --allowedTools. Bash is the one tool whose spec is checked here: an exact
# command, or a prefix ending in `:*` or ` *` that the command equals or
# continues after a space. A command holding a shell operator or a
# substitution (`; & | < > ( ) $` or a backtick, a newline), quoted or not,
# fits no pattern, so a second command can never ride on an allowed one.
# Any other pattern, a wildcard elsewhere in a Bash spec included, admits
# nothing: what the hook cannot check it refuses.
#
# Fails closed: a hook that exits 1 (or crashes) is only a non-blocking
# error to Claude Code, so the call would go through. Every path out of this
# script that is not the one explicit allow at the bottom exits 2, whatever
# went wrong (a missing jq, a missing option argument, an
# unbound variable, a failing command).
set -u -E

allowed="false"
trap '[ "$allowed" = "true" ] || exit 2' EXIT
trap 'exit 2' ERR

pinned_file=""
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

# bash_command_fits <spec> <command>: whether a Bash command fits the spec
# of a `Bash(spec)` entry (the header has the rule).
bash_command_fits() {
	local spec="$1" cmd="$2" prefix
	case "$cmd" in
		*[\;\&\|\<\>\(\)\$\`]* | *$'\n'* | *$'\r'*) return 1 ;;
	esac
	case "$spec" in
		*:\*) prefix="${spec%:\*}" ;;
		*' *') prefix="${spec% \*}" ;;
		*) prefix="" ;;
	esac
	if [ -z "$prefix" ]; then
		[[ "$spec" != *\** ]] && [ "$cmd" = "$spec" ]
		return
	fi
	[[ "$prefix" != *\** ]] || return 1
	[ "$cmd" = "$prefix" ] || [[ "$cmd" == "$prefix "* ]]
}

allowed_name="false"
for candidate in "$@"; do
	if [ "$tool_name" = "$candidate" ]; then
		allowed_name="true"
		break
	fi
	case "$candidate" in
		"$tool_name("*")") ;;
		*) continue ;;
	esac
	[ "$tool_name" = "Bash" ] || continue
	spec="${candidate#"$tool_name("}"
	spec="${spec%)}"
	# -j and a sentinel, so a trailing newline in the command survives the
	# command substitution and is judged like any other.
	command="$(printf '%s' "$input" | jq -j '.tool_input.command // "" | strings'; printf x)"
	command="${command%x}"
	if bash_command_fits "$spec" "$command"; then
		allowed_name="true"
		break
	fi
done
if [ "$allowed_name" != "true" ]; then
	echo "desk deny-hook: this '$tool_name' call is not on this call's allowlist ($*)" >&2
	exit 2
fi

if [ -n "$pinned_file" ]; then
	# A missing pinned file is a broken pin, not no pin: it fails closed.
	if [ ! -f "$pinned_file" ]; then
		echo "desk deny-hook: --pinned file is missing ($pinned_file) — denying" >&2
		exit 2
	fi
	tool_input="$(printf '%s' "$input" | jq -c --arg ign "$ignore_keys" \
		'(.tool_input // {}) | if $ign == "" then . else delpaths([$ign | split(",")[] | [.]]) end' 2>/dev/null)"
	if ! jq -e --argjson want "$tool_input" --arg tool "$tool_name" \
		'(if type == "object" then (.[$tool] // []) else . end) | any(.[]?; . == $want)' "$pinned_file" > /dev/null 2>&1; then
		echo "desk deny-hook: '$tool_name' tool_input isn't one of the pinned set ($pinned_file)" >&2
		exit 2
	fi
fi

allowed="true"
exit 0
