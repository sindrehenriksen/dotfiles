#!/usr/bin/env bash
# Starting each seat's usage window with the pass: sourced by desk-run.
set -u

# desk_warm_up <pass> <pass config JSON> <scratch dir>
# For each config dir in the pass's `warm_up.config_dirs` (absent: nothing,
# the default), one minimal request, so that seat's five-hour window starts
# when the pass does rather than at the first real message. The request has
# no tools, no MCP servers and no session, so it can send, post and write
# nothing; its reply is thrown away. `warm_up.model` (default haiku) and
# `warm_up.timeout` (seconds, default 60) tune it. A failure is logged and
# never stops the pass; one line is logged per dir.
desk_warm_up() {
	local pass="$1" pass_config="$2" scratch="$3" dirs d model timeout_secs out rc
	dirs="$(jq -r '.warm_up.config_dirs // [] | .[]' <<< "$pass_config" 2> /dev/null)" || return 0
	[ -n "$dirs" ] || return 0
	model="$(jq -r '.warm_up.model // "haiku"' <<< "$pass_config")"
	timeout_secs="$(jq -r '.warm_up.timeout // 60' <<< "$pass_config")"
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		d="${d/#\~/$HOME}"
		if [ ! -d "$d" ]; then
			desk_log "$pass" "warm-up: $d is not a directory, skipped"
			continue
		fi
		out="$scratch/warm-up-${d##*/}.out"
		(
			cd "$scratch" || exit 2
			export CLAUDE_CONFIG_DIR="$d"
			run_with_timeout "$timeout_secs" "$out" "$DESK_CLAUDE_BIN" -p "ok" --model "$model" \
				--no-session-persistence --tools "" --strict-mcp-config --disable-slash-commands \
				--permission-mode dontAsk < /dev/null
		) 9>&-
		rc=$?
		desk_cleanup_project_folder "$d" "$scratch"
		rm -f "$out" "$out.stderr" "$out.pid"
		if [ "$rc" -eq 0 ]; then
			desk_log "$pass" "warm-up: ${d##*/} window started ($model)"
		else
			desk_log "$pass" "warm-up: ${d##*/} failed (exit $rc), the pass goes on"
		fi
	done <<< "$dirs"
	return 0
}
