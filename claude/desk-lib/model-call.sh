#!/usr/bin/env bash
# The model-call wrapper (design.md §5 "Isolation, enforced", the
# Interfaces brief's own bullet, and the Runner decisions note on
# connectors). Every headless `claude -p` desk makes — fetch, judge, the
# pinned single-tool write, ticket-status, a per-session close call — goes
# through desk_call_model, so the isolation flags are set in exactly one
# place rather than re-typed at every call site.
set -u

# The claude binary to invoke — overridable so a test points this at a
# fake one on PATH without needing a real install or real credentials.
DESK_CLAUDE_BIN="${DESK_CLAUDE_BIN:-claude}"

# Computes the config dir's project-folder name for a given cwd. Verified
# live against a real call (the D8 canary, whose scratch cwd was a plain
# `mktemp -d` path under /var/folders — a macOS symlink to
# /private/var/folders): Claude Code names the folder after the cwd's
# *canonical* path (symlinks resolved), with every character that isn't
# alnum turned into "-" — not just "/": a "." in the path (mktemp's own
# "tmp.XXXXXX" suffix) came out as "-" too, which an earlier version of
# this function, tested only against its own fake reproduction rather than
# a real one, got wrong.
desk_project_folder_name() {
	local cwd="$1" real
	real="$(cd "$cwd" 2> /dev/null && pwd -P)" || real="$cwd"
	printf '%s' "$real" | tr -c 'A-Za-z0-9' '-'
}

# Deletes $2's project folder under config dir $1 (design.md's "tool-result
# spill": `--no-session-persistence` still spills overflowing tool results
# under here). Always safe to call even if the folder never got created.
desk_cleanup_project_folder() {
	local config_dir="$1" cwd="$2" name
	name="$(desk_project_folder_name "$cwd")"
	rm -rf "${config_dir:?}/projects/${name:?}" 2>/dev/null
}

# A fresh per-run scratch cwd outside any repo (design.md: "a per-run
# scratch cwd outside any repo"), built from plain alnum/hyphen segments
# only (see desk_project_folder_name above). Caller is responsible for
# removing it when done; desk-run's own cleanup happens in its trap.
desk_scratch_dir() {
	local label="$1" # e.g. "morning-F-private"
	local dir
	dir="$DESK_SCRATCH_ROOT/${label}-$(desk_now)-$$-$RANDOM"
	mkdir -p "$dir"
	echo "$dir"
}

# desk_pass_scratch_dir <pass> <scheduled_date> <step_id>
# The durable cwd for one "visible" (persisted) call — design.md's later
# "Runs he can open and continue": "its scratch dir is kept under
# ~/.local/state/desk/runs/<pass>-<date>/ ... so resume finds its cwd".
# Deterministic (no random suffix, unlike desk_scratch_dir above): a same-day
# retry of the same step re-enters the exact cwd a `claude --resume` for it
# would still be pointed at, rather than orphaning the first attempt's own
# directory. Never removed here — see desk_prune_old_runs, the only thing
# that ever sweeps these, and only once they're a week old.
desk_pass_scratch_dir() {
	local pass="$1" scheduled_date="$2" step_id="$3"
	local dir="$DESK_RUNS_ROOT/$pass-$scheduled_date/$step_id"
	mkdir -p "$dir"
	echo "$dir"
}

# desk_prune_old_runs [<now_epoch>]
# Removes any $DESK_RUNS_ROOT/<pass>-<date> directory whose <date> is more
# than 7 days old (design.md's "pruned after 7 days"), taking each visible
# call's own CLAUDE_CONFIG_DIR project folder down with it (design's "...
# with their config-dir project folder") — a persisted call's transcript and
# any spilled tool-results otherwise never get cleaned up at all, since
# desk_cleanup_project_folder above only ever ran right after an ephemeral
# (--no-session-persistence) call. Best-effort and silent about anything it
# can't parse: a directory whose name doesn't end in a plain YYYY-MM-DD is
# left alone rather than guessed at.
desk_prune_old_runs() {
	local now="${1:-$(desk_now)}"
	local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
	[ -d "$DESK_RUNS_ROOT" ] || return 0
	local d base date_part date_epoch age_days step_dir
	for d in "$DESK_RUNS_ROOT"/*; do
		[ -d "$d" ] || continue
		base="$(basename "$d")"
		date_part="$(printf '%s' "$base" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}$')"
		[ -n "$date_part" ] || continue
		if desk_is_linux; then
			date_epoch="$(date -d "$date_part" +%s 2> /dev/null)"
		else
			date_epoch="$(date -j -f '%Y-%m-%d' "$date_part" +%s 2> /dev/null)"
		fi
		[ -n "$date_epoch" ] || continue
		age_days=$(( (now - date_epoch) / 86400 ))
		[ "$age_days" -gt 7 ] || continue
		for step_dir in "$d"/*; do
			[ -d "$step_dir" ] || continue
			desk_cleanup_project_folder "$config_dir" "$step_dir"
		done
		rm -rf "$d" 2> /dev/null
	done
}

# desk_write_deny_hook_settings <dir> <pinned-args-file-or-""> <scratch-dir-or-""> <tool>...
# Writes the PreToolUse deny-hook settings file for a call's exact
# allowlist (the remaining args, tool names) into $1 (a path this call's
# own scratch dir owns), optionally also pinning tool_input itself to a
# pre-computed exact set (design's W: "runner-pinned thread ids and
# label" — see deny-unlisted-tool.sh's own `--pinned` doc) and/or scoping
# a Read call to under a directory (a judge/close call's own
# Read(<scratch>/**) --allowedTools entry, backed up here in case that
# glob alone is ever not enough — see deny-unlisted-tool.sh's own
# `--scratch` doc). Prints the settings file's path.
desk_write_deny_hook_settings() {
	local dir="$1" pinned_args_file="$2" scratch_dir="$3"
	shift 3
	# Built as a properly shell-quoted command LINE (desk_shq — the same
	# helper desk_step_open_tab already uses for exactly this reason),
	# never plain string concatenation: this is handed to Claude Code as
	# a hook's own `command`, run through a shell, so an unquoted path
	# containing a space (a scratch dir under a tmp root that has one, a
	# pinned-args file beside it) would word-split into the wrong
	# argv — a hook that then can't find its own script, or reads the
	# wrong thing as `$pinned_file`, is a broken safety check, not merely
	# a cosmetic bug.
	local hook_cmd path
	hook_cmd="$(desk_shq "$DESK_LIB_DIR/deny-unlisted-tool.sh")"
	if [ -n "$pinned_args_file" ]; then
		hook_cmd="$hook_cmd --pinned $(desk_shq "$pinned_args_file")"
	fi
	if [ -n "$scratch_dir" ]; then
		hook_cmd="$hook_cmd --scratch $(desk_shq "$scratch_dir")"
	fi
	if [ -n "$pinned_args_file" ] || [ -n "$scratch_dir" ]; then
		hook_cmd="$hook_cmd --"
	fi
	local t
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
#   [--tools VALUE] [--connector true|false] [--restricted true|false]
#   [--mcp-config PATH] [--strict-mcp-config true|false] [--settings PATH]
#   [--max-budget-usd N] [--name NAME] --timeout SECS --config-dir DIR --out PATH
#
# Runs the call under run_with_timeout, from --scratch as cwd, with
# CLAUDE_CONFIG_DIR=--config-dir; writes raw stream-json to --out. Returns
# run_with_timeout's exit code (0 ok, 124 killed on timeout, anything else
# the claude process's own exit code).
#
# `--name` (design.md's later "Runs he can open and continue") is what
# turns this from the ordinary ephemeral call (`--no-session-persistence`,
# cleaned up immediately after) into a "visible" one: the session persists
# under a runner-picked --session-id, named via `-n NAME` so a later
# `session-status.sh resolve NAME` can find it again, and its config-dir
# project folder is left standing (desk_prune_old_runs is the only thing
# that ever removes it, days later) rather than cleaned up here — its
# transcript is the very thing a follow-up `claude --resume` needs. Empty
# (the default) keeps the old ephemeral behavior exactly.
#
# A --restricted call loads no hooks at all (design.md §5), so nothing
# else would ever record its lifecycle: this function calls
# session-recorder.sh's own start/end verbs itself, source "desk-run". A
# non-restricted (`--connector`) call DOES load his real settings (merged
# in alongside its own --settings deny-hook file), so its own SessionStart/
# SessionEnd fire on their own — recording it here too would double up, so
# this only sets DESK_HEADLESS=1 in its environment instead (the hook's own
# DESK_HEADLESS handling tags that event source "desk-run" itself).
desk_call_model() {
	local scratch="" prompt_file="" allowed_tools="" tools="" connector="false" restricted="false"
	local mcp_config="" strict_mcp="false" settings="" max_budget_usd="" timeout_secs="" config_dir="" out="" name=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--scratch) scratch="$2"; shift 2 ;;
			--prompt-file) prompt_file="$2"; shift 2 ;;
			--allowed-tools) allowed_tools="$2"; shift 2 ;;
			--tools) tools="$2"; shift 2 ;;
			--connector) connector="$2"; shift 2 ;;
			--restricted) restricted="$2"; shift 2 ;;
			--mcp-config) mcp_config="$2"; shift 2 ;;
			--strict-mcp-config) strict_mcp="$2"; shift 2 ;;
			--settings) settings="$2"; shift 2 ;;
			--max-budget-usd) max_budget_usd="$2"; shift 2 ;;
			--name) name="$2"; shift 2 ;;
			--timeout) timeout_secs="$2"; shift 2 ;;
			--config-dir) config_dir="$2"; shift 2 ;;
			--out) out="$2"; shift 2 ;;
			*) desk_log - "desk_call_model: unknown option $1"; return 2 ;;
		esac
	done
	for req in scratch prompt_file allowed_tools timeout_secs config_dir out; do
		if [ -z "${!req}" ]; then
			desk_log - "desk_call_model: missing --$req"
			return 2
		fi
	done

	local argv=(
		# --verbose is not optional here: --print with --output-format
		# stream-json refuses to run without it (confirmed live, D8's
		# canary run — not something design.md's own Phase-0 table had
		# caught).
		"$DESK_CLAUDE_BIN" -p --output-format stream-json --verbose --permission-mode dontAsk
		--allowedTools "$allowed_tools"
	)
	local session_id=""
	if [ -n "$name" ]; then
		session_id="$(desk_new_session_id)"
		argv+=(--session-id "$session_id" -n "$name")
	else
		argv+=(--no-session-persistence)
	fi
	[ -n "$tools" ] && argv+=(--tools "$tools")
	[ "$restricted" = "true" ] && argv+=(--restricted)
	[ -n "$mcp_config" ] && argv+=(--mcp-config "$mcp_config")
	[ "$strict_mcp" = "true" ] && argv+=(--strict-mcp-config)
	[ -n "$settings" ] && argv+=(--settings "$settings")
	[ -n "$max_budget_usd" ] && argv+=(--max-budget-usd "$max_budget_usd")

	# The rendered prompt is passed as claude's own positional argument
	# (design.md §9(e): "Prompts take scalars as {{name}} placeholders and
	# bulk inputs as files in the per-run scratch dir" — bulk content is
	# never what's substituted into the prompt text itself, so the whole
	# rendered prompt stays small enough to pass this way).
	local prompt_text
	prompt_text="$(cat "$prompt_file")"

	if [ -n "$name" ] && [ "$restricted" = "true" ]; then
		local transcript_path
		transcript_path="$config_dir/projects/$(desk_project_folder_name "$scratch")/$session_id.jsonl"
		jq -cn --arg sid "$session_id" --arg cwd "$scratch" --arg tp "$transcript_path" --arg src "desk-run" \
			'{session_id:$sid, cwd:$cwd, transcript_path:$tp, source:$src}' \
			| "$DESK_SESSION_RECORDER_BIN" start 2> /dev/null
	fi

	local rc
	(
		cd "$scratch" || exit 2
		export CLAUDE_CONFIG_DIR="$config_dir"
		[ -n "$name" ] && [ "$restricted" != "true" ] && export DESK_HEADLESS=1
		run_with_timeout "$timeout_secs" "$out" "${argv[@]}" "$prompt_text" < /dev/null
	)
	rc=$?

	if [ -n "$name" ] && [ "$restricted" = "true" ]; then
		jq -cn --arg sid "$session_id" --arg reason "other" '{session_id:$sid, reason:$reason}' \
			| "$DESK_SESSION_RECORDER_BIN" end 2> /dev/null
	fi

	# run_with_timeout keeps stderr out of $out (never mixed into the
	# stream-json a downstream extraction slurps) but still writes it,
	# to "$out.stderr" — surfaced here as a log line so it's never just
	# silently discarded, then removed since nothing downstream reads it.
	if [ -s "$out.stderr" ]; then
		desk_log - "model call stderr ($out): $(cat "$out.stderr")"
	fi
	rm -f "$out.stderr"

	# A visible call's own project folder (transcript included) is left
	# standing for a later `claude --resume` — see this function's own
	# header comment and desk_prune_old_runs, the only thing that ever
	# removes it.
	[ -n "$name" ] || desk_cleanup_project_folder "$config_dir" "$scratch"
	return "$rc"
}

# The raw tool_result content blocks from a stream-json transcript, one
# JSON object per line — what the fetch/judge/ticket-status/close steps'
# own (pass-specific, D8b) parsing reads instead of the model's prose,
# per design.md's "accepts a source URL only if it appears verbatim in the
# fetch calls' raw tool_results". Generic across every call: stream-json's
# tool results arrive as `user`-role messages whose content carries
# `tool_result` blocks, the same shape transcripts already use elsewhere in
# desk. Exact field names are pinned by design.md §8's Phase-0 table as
# something to confirm live (not yet fully verified in this build); this is
# the one place to adjust if a real call's shape differs.
desk_extract_tool_results() {
	local stream_file="$1"
	jq -c 'select(.type == "user") | .message.content[]? | select(.type == "tool_result")' \
		"$stream_file" 2> /dev/null
}

# Every tool_use block a stream-json transcript's assistant turns made —
# the runner's own check that a denied call never actually ran (the D8
# canary, and any future audit of what a restricted call attempted).
desk_extract_tool_uses() {
	local stream_file="$1"
	jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")' \
		"$stream_file" 2> /dev/null
}

# A judge-shaped call's own final reply text (every text content block of
# the LAST assistant message, joined) — J and 16:30 hold no output tool,
# so their pinned {"items": [...]} shape (design.md §9(e)) is their last
# assistant turn's own text, never a tool_result. Prints "" if the stream
# has no assistant text at all (a hung/killed call, or one that only ever
# called tools).
desk_extract_final_text() {
	local stream_file="$1"
	jq -cs '[.[] | select(.type == "assistant")] | last' "$stream_file" 2> /dev/null \
		| jq -r '
			if . == null then ""
			else (.message.content // [] | map(select(.type == "text") | .text) | join("\n"))
			end
		' 2> /dev/null
}

# claude -p --output-format stream-json's own final line (`{"type":
# "result", "subtype": "success"|"error", "total_cost_usd": N, ...}`) own
# `total_cost_usd` — this one call's own real spend, the runner's basis
# for a per-pass running total (desk_step_model_call appends this to the
# pass's own cost log). Prints "" if the stream never got a result
# message at all (a hung/killed call) or that field is absent — never 0,
# so a caller summing these across a pass never mistakes "unknown" for
# "free".
desk_extract_total_cost_usd() {
	local stream_file="$1"
	jq -r 'select(.type == "result") | .total_cost_usd // empty' "$stream_file" 2> /dev/null | tail -n1
}
