#!/usr/bin/env bash
# The model-call wrapper. Every headless `claude -p` desk makes — fetch, judge, the
# pinned single-tool write, ticket-status, a per-session close call — goes
# through desk_call_model, so the isolation flags are set in exactly one
# place rather than re-typed at every call site.
set -u

# The claude binary to invoke — overridable so a test points this at a
# fake one on PATH without needing a real install or real credentials.
DESK_CLAUDE_BIN="${DESK_CLAUDE_BIN:-claude}"

# Computes the config dir's project-folder name for a given cwd. Verified
# live against a real call (the live canary, whose scratch cwd was a plain
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

# Deletes $2's project folder under config dir $1. Always safe to call even if the folder never got created.
desk_cleanup_project_folder() {
	local config_dir="$1" cwd="$2" name
	name="$(desk_project_folder_name "$cwd")"
	rm -rf "${config_dir:?}/projects/${name:?}" 2>/dev/null
}

# A fresh per-run scratch cwd outside any repo, built from plain alnum/hyphen segments
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
# The durable cwd for one "visible" (persisted) call: its scratch dir is kept under
# ~/.local/state/desk/runs/ so a resume finds its cwd.
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
# than 7 days old, taking each visible
# call's own CLAUDE_CONFIG_DIR project folder down with it — a persisted call's transcript and
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
# pre-computed exact set (the write step's runner-pinned thread ids and
# label — see deny-unlisted-tool.sh's own `--pinned` doc) and/or scoping
# a Read call to under a directory (a judge/close call's own
# Read(<scratch>/**) --allowedTools entry, backed up here in case that
# glob alone is ever not enough — see deny-unlisted-tool.sh's own
# `--scratch` doc). Prints the settings file's path.
desk_write_deny_hook_settings() {
	local dir="$1" pinned_args_file="$2" scratch_dir="$3"
	shift 3
	# The hook script itself: desk-run's own $DESK_DENY_HOOK_SCRIPT (a copy
	# into this pass's own scratch, made once at pass start — see
	# claude/desk-run's own comment on why) when set, falling back to the
	# repo's own live copy for a caller with no full pass context (a direct
	# test, the live canary). Either way, missing at the moment this settings
	# file is written is a hard refusal, never a settings file whose own
	# `command` points at nothing: that would be a broken, silently
	# unenforced hook, not a working one.
	local hook_script="${DESK_DENY_HOOK_SCRIPT:-$DESK_LIB_DIR/deny-unlisted-tool.sh}"
	if [ ! -f "$hook_script" ]; then
		desk_log - "desk_write_deny_hook_settings: hook script is missing ($hook_script) — refusing to write settings for an unenforceable hook"
		return 1
	fi
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
	hook_cmd="$(desk_shq "$hook_script")"
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
#   [--max-budget-usd N] [--name NAME] [--model MODEL] [--spill-dir DIR]
#   --timeout SECS --config-dir DIR --out PATH
#
# `--resume ID` instead continues an existing persisted session under its own
# id: no new id, no -n, nothing cleaned up afterwards, and the transcript the
# call appends to is that session's own (confirmed live: a headless resume
# keeps the session id and writes to the same file, without --fork-session).
# An empty --allowed-tools is accepted, for a call meant to have no tools.
#
# Runs the call under run_with_timeout, from --scratch as cwd, with
# CLAUDE_CONFIG_DIR=--config-dir; writes raw stream-json to --out. Returns
# run_with_timeout's exit code (0 ok, 124 killed on timeout, anything else
# the claude process's own exit code).
#
# `--name` is what
# turns this from the ordinary ephemeral call (`--no-session-persistence`,
# cleaned up immediately after) into a "visible" one: the session persists
# under a runner-picked --session-id (written to --session-id-file when
# given, which is how a later follow-up tab finds exactly this session), named
# via `-n NAME` for display, and its config-dir
# project folder is left standing (desk_prune_old_runs is the only thing
# that ever removes it, days later) rather than cleaned up here — its
# transcript is the very thing a follow-up `claude --resume` needs. Empty
# (the default) keeps the old ephemeral behavior exactly.
#
# A --restricted call loads no hooks at all, so nothing
# else would ever record its lifecycle: this function calls
# session-recorder.sh's own start/end verbs itself, source "desk-run". A
# non-restricted (`--connector`) call DOES load the user's real settings (merged
# in alongside its own --settings deny-hook file), so its own SessionStart/
# SessionEnd fire on their own — recording it here too would double up, so
# this only sets DESK_HEADLESS=1 in its environment instead (the hook's own
# DESK_HEADLESS handling tags that event source "desk-run" itself). This is
# every non-restricted call, named or not: an EPHEMERAL connector call
# (F-private, W — no --name, --no-session-persistence) still loads the user's
# real settings and hooks exactly like a visible one does, so without
# DESK_HEADLESS its own genuine SessionStart/SessionEnd would land
# source "startup", reason "other" — indistinguishable from a session the user
# actually opened, and exactly what the capture step's own "dropped"
# criteria matches. Gating this on --name (as the code used to) left every
# ephemeral connector call unmarked.
desk_call_model() {
	local tools_given="false" allowed_given="false" scratch="" prompt_file="" allowed_tools="" tools="" connector="false" restricted="false"
	local mcp_config="" strict_mcp="false" settings="" max_budget_usd="" timeout_secs="" config_dir="" out="" name="" session_id_file="" resume="" model="" spill_dir=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--scratch) scratch="$2"; shift 2 ;;
			--prompt-file) prompt_file="$2"; shift 2 ;;
			--allowed-tools) allowed_tools="$2"; allowed_given="true"; shift 2 ;;
			--tools) tools="$2"; tools_given="true"; shift 2 ;;
			--connector) connector="$2"; shift 2 ;;
			--restricted) restricted="$2"; shift 2 ;;
			--mcp-config) mcp_config="$2"; shift 2 ;;
			--strict-mcp-config) strict_mcp="$2"; shift 2 ;;
			--settings) settings="$2"; shift 2 ;;
			--max-budget-usd) max_budget_usd="$2"; shift 2 ;;
			--name) name="$2"; shift 2 ;;
			--model) model="$2"; shift 2 ;;
			--spill-dir) spill_dir="$2"; shift 2 ;;
			--session-id-file) session_id_file="$2"; shift 2 ;;
			--resume) resume="$2"; shift 2 ;;
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
		# --verbose is not optional here: --print with --output-format
		# stream-json refuses to run without it (confirmed live).
		"$DESK_CLAUDE_BIN" -p --output-format stream-json --verbose --permission-mode dontAsk
		--allowedTools "$allowed_tools"
	)
	local session_id=""
	if [ -n "$resume" ]; then
		session_id="$resume"
		argv+=(--resume "$session_id")
	elif [ -n "$name" ]; then
		session_id="$(desk_new_session_id)"
		argv+=(--session-id "$session_id" -n "$name")
		[ -z "$session_id_file" ] || printf '%s\n' "$session_id" > "$session_id_file"
	else
		argv+=(--no-session-persistence)
	fi
	[ "$tools_given" = "true" ] && argv+=(--tools "$tools")
	[ "$restricted" = "true" ] && argv+=(--restricted)
	[ -n "$mcp_config" ] && argv+=(--mcp-config "$mcp_config")
	[ "$strict_mcp" = "true" ] && argv+=(--strict-mcp-config)
	[ -n "$settings" ] && argv+=(--settings "$settings")
	[ -n "$max_budget_usd" ] && argv+=(--max-budget-usd "$max_budget_usd")
	[ -n "$model" ] && argv+=(--model "$model")

	# The rendered prompt is passed as claude's own positional argument
	#.
	local prompt_text
	prompt_text="$(cat "$prompt_file")"

	# Whether this call's session outlives it: a visible call or a resume.
	local persisted="false"
	{ [ -n "$name" ] || [ -n "$resume" ]; } && persisted="true"

	if [ "$persisted" = "true" ] && [ "$restricted" = "true" ]; then
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
		[ "$restricted" != "true" ] && export DESK_HEADLESS=1
		run_with_timeout "$timeout_secs" "$out" "${argv[@]}" -- "$prompt_text" < /dev/null
	)
	rc=$?

	if [ "$persisted" = "true" ] && [ "$restricted" = "true" ]; then
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

	# `--spill-dir`: a tool result past Claude Code's output limit reaches
	# the stream only as a pointer to a file it saved under the project
	# folder; those files are copied out before the folder goes.
	if [ -n "$spill_dir" ]; then
		mkdir -p "$spill_dir"
		find "$config_dir/projects/$(desk_project_folder_name "$scratch")" -path '*/tool-results/*' -type f \
			-exec cp {} "$spill_dir"/ \; 2> /dev/null
	fi

	# A visible call's own project folder (transcript included) is left
	# standing for a later `claude --resume` — see this function's own
	# header comment and desk_prune_old_runs, the only thing that ever
	# removes it.
	[ "$persisted" = "true" ] || desk_cleanup_project_folder "$config_dir" "$scratch"
	return "$rc"
}

# The raw tool_result content blocks from a stream-json transcript, one
# JSON object per line — what the fetch/judge/ticket-status/close steps'
# own (pass-specific) parsing reads instead of the model's prose,
# since a source URL is accepted only if it appears verbatim in the
# fetch calls' raw tool_results. Generic across every call: stream-json's
# tool results arrive as `user`-role messages whose content carries
# `tool_result` blocks, the same shape transcripts already use elsewhere in
# desk. Exact field names are as
# something to confirm live (not yet fully verified in this build); this is
# the one place to adjust if a real call's shape differs.
desk_extract_tool_results() {
	local stream_file="$1"
	jq -c 'select(.type == "user") | .message.content[]? | select(.type == "tool_result")' \
		"$stream_file" 2> /dev/null
}

# Every tool_use block a stream-json transcript's assistant turns made —
# the runner's own check that a denied call never actually ran (the live
# canary, and any future audit of what a restricted call attempted).
desk_extract_tool_uses() {
	local stream_file="$1"
	jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")' \
		"$stream_file" 2> /dev/null
}

# A judge-shaped call's own final reply text (every text content block of
# the LAST assistant message, joined) — J and a close call hold no output tool,
# so their pinned {"items": [...]} shape is their last
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
