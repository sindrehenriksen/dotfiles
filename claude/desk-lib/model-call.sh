#!/usr/bin/env bash
# The model-call wrapper. Every headless `claude -p` desk makes goes through
# desk_call_model, so the isolation flags are set in one place.
set -u

# Overridable so a test points this at a fake on PATH.
DESK_CLAUDE_BIN="${DESK_CLAUDE_BIN:-claude}"

# The config dir's project-folder name for a cwd, as Claude Code makes it:
# the canonical path (symlinks resolved) with every non-alphanumeric
# character turned into "-", a "." included.
desk_project_folder_name() {
	local cwd="$1" real
	real="$(cd "$cwd" 2> /dev/null && pwd -P)" || real="$cwd"
	printf '%s' "$real" | tr -c 'A-Za-z0-9' '-'
}

# Deletes $2's project folder under config dir $1, if there is one.
desk_cleanup_project_folder() {
	local config_dir="$1" cwd="$2" name
	name="$(desk_project_folder_name "$cwd")"
	rm -rf "${config_dir:?}/projects/${name:?}" 2>/dev/null
}

# A fresh scratch cwd outside any repo. The caller removes it.
desk_scratch_dir() {
	local label="$1"
	local dir
	dir="$DESK_SCRATCH_ROOT/${label}-$(desk_now)-$$-$RANDOM"
	mkdir -p "$dir"
	echo "$dir"
}

# desk_prune_old_runs [<now_epoch>]
# Removes every $DESK_RUNS_ROOT/<pass>-<date> run directory more than seven
# days old, except one whose brief is still waiting to be delivered.
desk_prune_old_runs() {
	local now="${1:-$(desk_now)}"
	[ -d "$DESK_RUNS_ROOT" ] || return 0
	local d date_part date_epoch
	for d in "$DESK_RUNS_ROOT"/*; do
		[ -d "$d" ] || continue
		date_part="$(basename "$d" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$')"
		[ -n "$date_part" ] || continue
		if desk_is_linux; then
			date_epoch="$(date -d "$date_part" +%s 2> /dev/null)"
		else
			date_epoch="$(date -j -f '%Y-%m-%d' "$date_part" +%s 2> /dev/null)"
		fi
		[ -n "$date_epoch" ] || continue
		[ $(((now - date_epoch) / 86400)) -gt 7 ] || continue
		[ -e "$d/brief.pending" ] && continue
		rm -rf "$d" 2> /dev/null
	done
}

# desk_write_deny_hook_settings <dir> <tool>...
# Writes into <dir> the PreToolUse settings that run deny-unlisted-tool.sh
# with this call's exact tool list. Prints the settings file's path; fails, writing
# nothing, when the hook script is missing, since a hook pointing at
# nothing would be silently unenforced.
desk_write_deny_hook_settings() {
	local dir="$1"
	shift
	# desk-run's copy of the hook for the pass, so a pull mid-pass cannot
	# change it under a call; the repo's own for a caller with no pass.
	local hook_script="${DESK_DENY_HOOK_SCRIPT:-$DESK_LIB_DIR/deny-unlisted-tool.sh}"
	if [ ! -f "$hook_script" ]; then
		desk_log - "desk_write_deny_hook_settings: hook script is missing ($hook_script) — refusing to write settings for an unenforceable hook"
		return 1
	fi
	# A hook command runs through a shell, so every word is quoted.
	local hook_cmd path t
	hook_cmd="$(desk_shq "$hook_script")"
	for t in "$@"; do
		hook_cmd="$hook_cmd $(desk_shq "$t")"
	done
	path="$dir/deny-hook-settings.json"
	jq -n --arg cmd "$hook_cmd" '{
		hooks: {
			PreToolUse: [
				{ hooks: [ { type: "command", command: $cmd, timeout: 10 } ] }
			]
		}
	}' > "$path"
	echo "$path"
}

# desk_call_model --scratch DIR --prompt-file PATH --allowed-tools CSV
#   [--tools VALUE] [--restricted true|false] [--mcp-config PATH]
#   [--strict-mcp-config true|false] [--settings PATH] [--max-budget-usd N]
#   [--model MODEL] [--spill-dir DIR] --timeout SECS --config-dir DIR --out PATH
#
# Runs one ephemeral call (`--no-session-persistence`, `--permission-mode
# dontAsk`) under run_with_timeout, from --scratch as cwd, with
# CLAUDE_CONFIG_DIR=--config-dir, writing its stream-json to --out. Its
# project folder is removed afterwards; with --spill-dir, any tool result
# Claude Code saved to a file there (one past the output limit) is copied
# out first. Returns 0, 124 on a timeout, else the call's exit code.
desk_call_model() {
	local tools_given="false" allowed_given="false" scratch="" prompt_file="" allowed_tools="" tools="" restricted="false"
	local mcp_config="" strict_mcp="false" settings="" max_budget_usd="" timeout_secs="" config_dir="" out="" model="" spill_dir=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--scratch) scratch="$2"; shift 2 ;;
			--prompt-file) prompt_file="$2"; shift 2 ;;
			--allowed-tools) allowed_tools="$2"; allowed_given="true"; shift 2 ;;
			--tools) tools="$2"; tools_given="true"; shift 2 ;;
			--restricted) restricted="$2"; shift 2 ;;
			--mcp-config) mcp_config="$2"; shift 2 ;;
			--strict-mcp-config) strict_mcp="$2"; shift 2 ;;
			--settings) settings="$2"; shift 2 ;;
			--max-budget-usd) max_budget_usd="$2"; shift 2 ;;
			--model) model="$2"; shift 2 ;;
			--spill-dir) spill_dir="$2"; shift 2 ;;
			--timeout) timeout_secs="$2"; shift 2 ;;
			--config-dir) config_dir="$2"; shift 2 ;;
			--out) out="$2"; shift 2 ;;
			*) desk_log - "desk_call_model: unknown option $1"; return 2 ;;
		esac
	done
	if [ "$allowed_given" != "true" ]; then
		desk_log - "desk_call_model: missing --allowed-tools"
		return 2
	fi
	for req in scratch prompt_file timeout_secs config_dir out; do
		if [ -z "${!req}" ]; then
			desk_log - "desk_call_model: missing --$req"
			return 2
		fi
	done

	local argv=(
		# --print with stream-json refuses to run without --verbose.
		"$DESK_CLAUDE_BIN" -p --output-format stream-json --verbose --permission-mode dontAsk
		--allowedTools "$allowed_tools" --no-session-persistence
	)
	[ "$tools_given" = "true" ] && argv+=(--tools "$tools")
	[ "$restricted" = "true" ] && argv+=(--restricted)
	[ -n "$mcp_config" ] && argv+=(--mcp-config "$mcp_config")
	[ "$strict_mcp" = "true" ] && argv+=(--strict-mcp-config)
	[ -n "$settings" ] && argv+=(--settings "$settings")
	[ -n "$max_budget_usd" ] && argv+=(--max-budget-usd "$max_budget_usd")
	[ -n "$model" ] && argv+=(--model "$model")

	local prompt_text rc
	prompt_text="$(cat "$prompt_file")"
	(
		cd "$scratch" || exit 2
		export CLAUDE_CONFIG_DIR="$config_dir"
		run_with_timeout "$timeout_secs" "$out" "${argv[@]}" -- "$prompt_text" < /dev/null
	)
	rc=$?

	# run_with_timeout keeps stderr out of the stream, in "$out.stderr".
	if [ -s "$out.stderr" ]; then
		desk_log - "model call stderr ($out): $(cat "$out.stderr")"
	fi
	rm -f "$out.stderr"

	if [ -n "$spill_dir" ]; then
		mkdir -p "$spill_dir"
		find "$config_dir/projects/$(desk_project_folder_name "$scratch")" -path '*/tool-results/*' -type f \
			-exec cp {} "$spill_dir"/ \; 2> /dev/null
	fi
	desk_cleanup_project_folder "$config_dir" "$scratch"
	return "$rc"
}

# The tool_result blocks of a stream-json transcript, one per line: what the
# runner reads of a call's results, never its prose.
desk_extract_tool_results() {
	jq -c 'select(.type == "user") | .message.content[]? | select(.type == "tool_result")' "$1" 2> /dev/null
}

# Every tool_use block of a stream-json transcript's assistant turns.
desk_extract_tool_uses() {
	jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")' "$1" 2> /dev/null
}

# A call's final reply text: the result line's `result`, else the last
# assistant message's text. "" when there is none.
desk_extract_final_text() {
	local stream_file="$1" result
	result="$(jq -rs '[.[] | select(.type == "result") | .result | strings] | last // empty' "$stream_file" 2> /dev/null)"
	if [ -n "$result" ]; then
		printf '%s\n' "$result"
		return 0
	fi
	jq -cs '[.[] | select(.type == "assistant")] | last' "$stream_file" 2> /dev/null \
		| jq -r '
			if . == null then ""
			else (.message.content // [] | map(select(.type == "text") | .text) | join("\n"))
			end
		' 2> /dev/null
}

# The call's own `total_cost_usd` from its result line, or "" when it has
# none (never 0, so a sum never mistakes unknown for free).
desk_extract_total_cost_usd() {
	jq -r 'select(.type == "result") | .total_cost_usd // empty' "$1" 2> /dev/null | tail -n1
}
