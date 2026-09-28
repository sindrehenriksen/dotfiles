#!/usr/bin/env bash
# Generic step-kind drivers (design.md §9(c), §10 D8: "generic step kinds
# ... fetch, judge, write, ticket-status, close, commit-and-push"). Each
# function here builds the right isolation flags and scratch-dir
# arrangement for its kind and calls desk_call_model; none of them
# interpret a model's actual output beyond generic shape (stream-json ->
# tool_results/tool_uses). Turning that into Slack/Gmail/Jira-specific
# facts, a validated proposal item, or a pinned exact-id write is D8b's
# job — every such point is a clearly named stub below, not guessed at.
set -u

# ---------------------------------------------------------------------------
# Prompt rendering: plain {{name}} substitution from a flat JSON object of
# string values. Generic (design.md §9(c): "Prompts take scalars as
# {{name}} placeholders and bulk inputs as files") — only *which* values
# go in is pass-specific, and that's supplied by the caller, not decided
# here.
# ---------------------------------------------------------------------------
desk_render_prompt() {
	local template_file="$1" placeholders_json="${2:-}"
	# NOT `"${2:-{}}"` on the line above: bash's own `${..:-word}` scanning
	# stops at the first unescaped `}` in `word`, so a literal "{}" default
	# there closes the expansion one character early and leaves a stray `}`
	# appended after *every* value, default or not (confirmed live: jq then
	# errors "Unmatched '}'" on stderr on every call — silently swallowed
	# below, and self-healing only because jq still emits a well-formed
	# leading object's own keys before choking on the trailing garbage).
	[ -n "$placeholders_json" ] || placeholders_json='{}'
	# NOT bash's own `${text//\{\{$k\}\}/$v}` (a loop, one pass per key):
	# two independent ways for that to stop treating a value literally.
	# First, bash 5.2+'s own `patsub_replacement` (on by default) makes an
	# unescaped `&` in a `${..//pat/repl}` replacement mean "the matched
	# text", same as sed — a value that happens to contain a literal `&`
	# (a URL query string, a headline) would silently splice in the
	# `{{key}}` token itself instead. Second, looping key by key rescans
	# the *whole* text on every iteration, inserted values included — a
	# value that happens to contain another key's own `{{other}}` marker
	# gets that marker substituted too, on a later iteration, even though
	# it was never part of the template to begin with. jq's `gsub` here
	# does one single left-to-right pass over the ORIGINAL template text,
	# substituting every `{{key}}` token at once from the placeholders
	# object — never rescanning what it just inserted, and never
	# reinterpreting a value's own text as anything but a literal string.
	# A `{{name}}` whose key isn't in `placeholders_json` (or maps to
	# null) is left exactly as it was, same as the old loop only ever
	# touching keys it was actually given.
	jq -Rrs --argjson ph "$placeholders_json" '
		gsub("\\{\\{(?<key>[A-Za-z0-9_]+)\\}\\}";
			(($ph[.key] // "{{\(.key)}}")
			| if type == "string" then . else tostring end))
	' "$template_file"
}

# Resolves a step's `prompt` path (relative to $DESK_CONFIG's directory,
# design.md §9(c)) to an absolute one.
desk_prompt_path() {
	local prompt_rel="$1"
	[[ "$prompt_rel" = /* ]] && { echo "$prompt_rel"; return; }
	echo "$(dirname "$DESK_CONFIG")/$prompt_rel"
}

# The exact --allowedTools value for a step: its own `tools` array, comma-
# joined — design's "exact --allowedTools" per call. A judge/close step
# (the two kinds that only ever legitimately read their own seeded
# scratch files, never anywhere else) whose tools include a bare "Read"
# gets it scoped instead, to Read(<scratch>/**) — an absolute glob under
# that call's own scratch dir, passed as $2. Any other step, or a call
# with no scratch dir yet, gets the plain unscoped join it always had.
desk_step_allowed_tools() {
	local step_json="$1" scratch="${2:-}"
	local kind
	kind="$(jq -r '.kind // empty' <<< "$step_json")"
	if [ -n "$scratch" ] && { [ "$kind" = "judge" ] || [ "$kind" = "close" ]; }; then
		jq -r --arg scratch "$scratch" '
			(.tools // []) | map(if . == "Read" then "Read(" + $scratch + "/**)" else . end) | join(",")
		' <<< "$step_json"
	else
		jq -r '(.tools // []) | join(",")' <<< "$step_json"
	fi
}

# ---------------------------------------------------------------------------
# Pass-level context and named producers (prompts/README.md's own table:
# every call's {{placeholders}} and scratch-dir input files, keyed by name
# rather than by which step happens to want them — this is the "runner
# knows how to produce each kind" half; which names a step's own prompt
# actually references is that prompt's business, so a producer here is
# always safe to compute even for a step that won't use it (an unused
# {{key}} is simply never substituted, per desk_render_prompt above).
# ---------------------------------------------------------------------------

# "DAILY" normally; "WEEKLY" on the first run of the ISO week (design.md
# §4's own daily/weekly split for a pass's own bar). $1 = this pass's last
# "ok" run (epoch, "" for never) — the same value the caller already reads
# for its Gmail-window lookback, never re-derived a second way here.
desk_compute_mode() {
	local last_ok="${1:-}"
	[ -n "$last_ok" ] || { echo WEEKLY; return; }
	local cur_week last_week
	cur_week="$(date +%G-%V)"
	if desk_is_linux; then
		last_week="$(date -d "@$last_ok" +%G-%V 2> /dev/null)"
	else
		last_week="$(date -j -r "$last_ok" +%G-%V 2> /dev/null)"
	fi
	if [ -n "$last_week" ] && [ "$cur_week" = "$last_week" ]; then echo DAILY; else echo WEEKLY; fi
}

# $1 (epoch) as ISO 8601 with an explicit Europe/Oslo offset (prompts/
# README.md: "ISO 8601, Oslo offset") — always that zone, regardless of
# this machine's own, so a test or a run from anywhere still renders the
# zone the prompts are written against.
desk_iso8601_oslo() {
	local epoch="$1"
	if desk_is_linux; then
		TZ=Europe/Oslo date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%:z 2> /dev/null
	else
		local out
		out="$(TZ=Europe/Oslo date -j -r "$epoch" +%Y-%m-%dT%H:%M:%S%z 2> /dev/null)"
		# BSD date has no %:z; splice the colon into the numeric offset by hand.
		printf '%s' "$out" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
	fi
}

# The `{{caps}}` scalar (morning-j.md: "e.g. `ACT ≤3, worth knowing ≤3,
# wildcard ≤1`") from one pass's own caps object ({act, worth_knowing,
# wildcard}).
desk_caps_string() {
	local caps_json="$1" act wk wc
	act="$(jq -r '.act // "?"' <<< "$caps_json")"
	wk="$(jq -r '.worth_knowing // "?"' <<< "$caps_json")"
	wc="$(jq -r '.wildcard // "?"' <<< "$caps_json")"
	printf 'ACT ≤%s, worth knowing ≤%s, wildcard ≤%s' "$act" "$wk" "$wc"
}

# A fixed, sed-safe (no /, &, \) literal suffix marking a scratch-copy line
# whose content the ledger says is an accepted suggestion (design's "agent-
# originated lines marked", morning-j.md: "don't treat them as his own
# phrasing to imitate"). Never written back to the real file — only ever
# appears in a scratch copy J reads, and desk-lib/validate.sh strips it
# again from anything J echoes back before that text is used as an anchor.
DESK_AGENT_MARK="  <<agent-suggested>>"

# desk_write_marked_head_copy <repo> <file> <out_path>
# `<file>`'s HEAD content, byte for byte, except every line that exactly
# matches an accepted ledger item's own `after` text gets `$DESK_AGENT_MARK`
# appended. "Accepted" is derived the same way desk.ledger already does
# (ledger-derive, via cli.lua) against this file's *real* current head/
# index/worktree — never re-implemented here — so this is exactly the set
# of lines that landed in HEAD as a laid-in suggestion he accepted, not a
# second heuristic. A line his own edit happens to match byte-for-byte is a
# rare, low-stakes false positive (informational only); nothing here is
# ever used as ground truth for placement.
desk_write_marked_head_copy() {
	local repo="$1" file="$2" out="$3"
	local head_content
	head_content="$(git -C "$repo" show "HEAD:$file" 2> /dev/null)"
	if [ -z "$head_content" ]; then
		: > "$out"
		return
	fi
	local derived marked_lines
	derived="$(desk_nvim_cli ledger-derive "$repo" "$file" 2> /dev/null)"
	[ -n "$derived" ] || derived='{}'
	marked_lines="$(jq -r '
		(.states // {}) as $states
		| (.items // {}) | to_entries[]
		| select($states[.key] == "accepted" and .value.kind != "remove")
		| .value.after
		| splits("\n")
	' <<< "$derived" 2> /dev/null)"
	if [ -z "$marked_lines" ]; then
		printf '%s\n' "$head_content" > "$out"
		return
	fi
	while IFS= read -r line; do
		if [ -n "$line" ] && grep -qxF "$line" <<< "$marked_lines" 2> /dev/null; then
			printf '%s%s\n' "$line" "$DESK_AGENT_MARK"
		else
			printf '%s\n' "$line"
		fi
	done <<< "$head_content" > "$out"
}

# desk_write_tickets_diff <old-ticket-cache-json> <ticket-cache-file> <out>
# J's `tickets.json` (prompts/README.md, morning-j.md: "ticket keys his
# lines mention whose status changed since the last pass"): every ticket
# present in both the cache from before this pass's own T step ran and the
# (now current) cache, whose status differs. A brand-new key (nothing to
# have "changed" from) and an unchanged one are both left out.
desk_write_tickets_diff() {
	local old_cache_json="$1" cache_file="$2" out="$3"
	[ -n "$old_cache_json" ] || old_cache_json='{}'
	local new_cache_json
	new_cache_json="$(cat "$cache_file" 2> /dev/null || echo '{}')"
	jq -e . > /dev/null 2>&1 <<< "$new_cache_json" || new_cache_json='{}'
	jq -n --argjson old "$old_cache_json" --argjson new "$new_cache_json" '
		($old.tickets // {}) as $ot
		| ($new.tickets // {}) as $nt
		| [ $nt | to_entries[]
			| select($ot[.key] != null and $ot[.key].status != .value.status)
			| {key: .key, summary: (.value.summary // ""), status: .value.status, previous_status: $ot[.key].status}
		  ]
	' > "$out" 2> /dev/null || echo '[]' > "$out"
}

# desk_write_sessions_summary <out>
# J's optional `sessions.json`: session-status.sh's own entries, names and
# status only (morning-j.md: "names and status only"). Bare on PATH, same
# as desk_close_candidates's own reader call — never a second lookup
# convention for the same tool.
desk_write_sessions_summary() {
	local out="$1"
	session-status.sh 2> /dev/null | jq -s '[.[] | {name, status}]' > "$out" 2> /dev/null
	[ -s "$out" ] || echo '[]' > "$out"
}

# desk_write_open_items <repo> <files-json-array> <out>
# J's optional `open-items.json`: every ledger item, across every
# configured file, that's laid in and not yet resolved ("queued" — never
# laid in at all — or "pending"/"postponed"), in the same pinned proposal
# shape a fresh judge item takes. Reuses desk-lib/git-ops.sh's own
# `_DESK_JQ_LEDGER_TO_PROPOSAL` (never re-derived a second way here) — a
# caller of this function is expected to have sourced that file too, the
# same dependency desk-run's own step loop already has.
desk_write_open_items() {
	local repo="$1" files_json="$2" out="$3"
	local all="[]"
	local n
	n="$(jq 'length' <<< "$files_json" 2> /dev/null || echo 0)"
	local i
	for ((i = 0; i < n; i++)); do
		local f derived items filter
		f="$(jq -r ".[$i]" <<< "$files_json")"
		derived="$(desk_nvim_cli ledger-derive "$repo" "$f" 2> /dev/null)" || continue
		[ -n "$derived" ] || derived='{}'
		filter='(.states // {}) as $states
			| [(.items // {}) | to_entries[]
				| select(.value.file == $f
					and ($states[.key] as $s | $s == "queued" or $s == "pending" or $s == "postponed"))
				| (.value | '"$_DESK_JQ_LEDGER_TO_PROPOSAL"')]'
		items="$(jq -c --arg f "$f" "$filter" <<< "$derived" 2> /dev/null)"
		[ -n "$items" ] || items="[]"
		all="$(jq -cn --argjson a "$all" --argjson b "$items" '$a + $b')"
	done
	printf '%s' "$all" > "$out"
}

# desk_seed_named_file <name> <dest_dir> <ctx_json>
# Writes one named scratch-dir input file (prompts/README.md's own table)
# into $2. `ctx_json` carries whatever the producer needs: `repo`,
# `sources_path`, `pass_scratch`, `files` (the configured file list),
# `old_ticket_cache` (the cache as it stood before this pass's own T step
# ran). Unknown names are logged and skipped, never a hard failure — an
# optional file a step lists but this build doesn't know how to produce
# yet shouldn't take the whole call down.
desk_seed_named_file() {
	local name="$1" dest_dir="$2" ctx_json="$3"
	local repo
	repo="$(jq -r '.repo // empty' <<< "$ctx_json")"
	case "$name" in
		notes.md | reading.md)
			desk_write_marked_head_copy "$repo" "$name" "$dest_dir/$name"
			;;
		sources.json)
			local sp
			sp="$(jq -r '.sources_path // empty' <<< "$ctx_json")"
			if [ -n "$sp" ] && cp -f "$sp" "$dest_dir/sources.json" 2> /dev/null; then :; else
				echo '{}' > "$dest_dir/sources.json"
			fi
			;;
		f-private.json | f-web.json)
			local step_id="F-private" pass_scratch text
			[ "$name" = "f-web.json" ] && step_id="F-web"
			pass_scratch="$(jq -r '.pass_scratch // empty' <<< "$ctx_json")"
			text="$(desk_extract_final_text "$pass_scratch/${step_id}-stream.jsonl" 2> /dev/null)"
			if [ -n "$text" ] && jq -e . > /dev/null 2>&1 <<< "$text"; then
				printf '%s' "$text" > "$dest_dir/$name"
			else
				echo '{}' > "$dest_dir/$name"
			fi
			;;
		tickets.json)
			local old_cache
			old_cache="$(jq -c '.old_ticket_cache // {}' <<< "$ctx_json")"
			desk_write_tickets_diff "$old_cache" "$DESK_TICKET_CACHE" "$dest_dir/tickets.json"
			;;
		sessions.json)
			desk_write_sessions_summary "$dest_dir/sessions.json"
			;;
		open-items.json)
			desk_write_open_items "$repo" "$(jq -c '.files // []' <<< "$ctx_json")" "$dest_dir/open-items.json"
			;;
		*)
			desk_log - "desk_seed_named_file: unknown file kind: $name (skipped)"
			;;
	esac
}

# ---------------------------------------------------------------------------
# Partial-proposal support: a fetch (source) step's own failure never
# aborts the whole pass (desk-run's own step loop is what actually decides
# that — see its "fetch" case) — but it also shouldn't cost a source that
# already succeeded once *this scheduled date* a redundant, budget-burning
# re-run on the next retry slot. This is the per-(pass, scheduled_date, id)
# cache that makes "later slots only retry the missing sources" true: a
# fetch step's own raw stream/tool-results/tool-uses, kept only long enough
# to survive to the next slot the same day, keyed on scheduled_date so a
# new day never sees a stale hit.
# ---------------------------------------------------------------------------
DESK_FETCH_CACHE_ROOT="${DESK_FETCH_CACHE_ROOT:-$DESK_STATE_DIR/fetch-cache}"

desk_fetch_cache_dir() {
	local pass="$1" scheduled_date="$2" id="$3"
	printf '%s/%s-%s-%s' "$DESK_FETCH_CACHE_ROOT" "$pass" "$scheduled_date" "$id"
}

# True (exit 0) if $3 (a fetch step's own id) already completed ok for
# $1/$2 (pass, scheduled date) earlier this same day.
desk_fetch_already_done() {
	local dir
	dir="$(desk_fetch_cache_dir "$1" "$2" "$3")"
	[ -f "$dir/done" ]
}

# Persists $3's own scratch-jsonl outputs (desk_step_model_call's own
# "$PASS_SCRATCH/${id}-*.jsonl" naming) so a later retry slot the same day
# can skip re-running this source entirely and still hand J the same
# inputs it would have gotten from a fresh run.
desk_fetch_cache_save() {
	local pass="$1" scheduled_date="$2" id="$3"
	local dir
	dir="$(desk_fetch_cache_dir "$pass" "$scheduled_date" "$id")"
	mkdir -p "$dir" 2> /dev/null
	cp -f "$PASS_SCRATCH/$id"-*.jsonl "$dir/" 2> /dev/null
	: > "$dir/done"
}

# The inverse of desk_fetch_cache_save: copies a previously cached source's
# own scratch-jsonl files back into $PASS_SCRATCH, as if this run had just
# made the call itself.
desk_fetch_cache_restore() {
	local pass="$1" scheduled_date="$2" id="$3"
	local dir
	dir="$(desk_fetch_cache_dir "$pass" "$scheduled_date" "$id")"
	cp -f "$dir/$id"-*.jsonl "$PASS_SCRATCH/" 2> /dev/null
}

# Clears every cached source for $1 (pass) — called once the pass finishes
# with no failed sources left, since a cache entry only ever exists to
# survive to that pass's own next same-day retry slot; a pass that's fully
# "ok" has no more retrying left to do, cached or not.
desk_fetch_cache_clear() {
	local pass="$1"
	rm -rf "${DESK_FETCH_CACHE_ROOT:?}/$pass-"* 2> /dev/null
}

# ---------------------------------------------------------------------------
# fetch / judge / ticket_status: all "one model call, generic isolation"
# kinds, differing only in a couple of flags — driven by one function.
# `write` (the pinned single-tool call) is its own function below since it
# also needs the deny-hook's pinned-label extension (D8b).
# ---------------------------------------------------------------------------

# desk_step_model_call <pass> <step_json> <label> <placeholders_json>
#   [<extra-files-dir-to-copy-into-scratch>] [<pinned_args_json>] [<scheduled_date>]
# Runs one model call for a fetch/judge/ticket_status/write-shaped step.
# Writes the raw stream-json to $PASS_SCRATCH/<id>-stream.jsonl and the
# generic tool_results/tool_uses extraction beside it — downstream, pass-
# specific parsing reads those, never the model's prose. `pinned_args_json`
# (a JSON array, or "null"/"" for none) additionally pins a connector
# call's own tool_input to that exact set, via deny-unlisted-tool.sh's
# `--pinned` (W's own extra layer — see desk_step_write). Prints
# "ok"/"failed"/"timeout".
#
# A step whose own config sets `"visible": true` (design.md's later
# "Visible run sessions") gets a durable, named, persisted call instead of
# the ordinary ephemeral one: its cwd is desk_pass_scratch_dir under
# $DESK_RUNS_ROOT rather than a throwaway desk_scratch_dir, named
# `desk-<pass>-<scheduled date>-<id>` (desk_open_follow_up_tab is what
# later resolves that name back to a session to resume), and never
# removed here afterward — see desk_call_model's own header on why.
desk_step_model_call() {
	local pass="$1" step_json="$2" label="${3:-}" placeholders_json="${4:-}" seed_dir="${5:-}"
	[ -n "$placeholders_json" ] || placeholders_json='{}' # see desk_render_prompt's own comment on why not "${4:-{}}"
	local pinned_args_json="${6:-null}"
	local scheduled_date="${7:-$(date +%F)}"
	local id kind prompt_rel tools_csv connector cap timeout max_budget_usd
	id="$(jq -r '.id' <<< "$step_json")"
	kind="$(jq -r '.kind // empty' <<< "$step_json")"
	prompt_rel="$(jq -r '.prompt // empty' <<< "$step_json")"
	connector="$(jq -r '.connector // false' <<< "$step_json")"
	timeout="$(jq -r '.timeout // 300' <<< "$step_json")"
	# A step's own `max_budget_usd`, falling back to the generic default
	# (common.sh's own DESK_DEFAULT_MAX_BUDGET_USD) — every call gets a
	# real spend cap, never an unbounded one, whether or not its own step
	# config ever names one.
	max_budget_usd="$(jq -r '.max_budget_usd // empty' <<< "$step_json")"
	[ -n "$max_budget_usd" ] || max_budget_usd="$DESK_DEFAULT_MAX_BUDGET_USD"

	local visible session_name=""
	visible="$(jq -r '.visible // false' <<< "$step_json")"
	[ "$visible" = "true" ] && session_name="desk-$pass-$scheduled_date-$id"

	desk_log "$pass" "model call: $id${label:+ ($label)}"
	local call_scratch
	if [ -n "$session_name" ]; then
		call_scratch="$(desk_pass_scratch_dir "$pass" "$scheduled_date" "$id")"
	else
		call_scratch="$(desk_scratch_dir "$pass-$id")"
	fi
	if [ -n "$seed_dir" ] && [ -d "$seed_dir" ]; then
		cp -R "$seed_dir"/. "$call_scratch"/ 2> /dev/null || true
	fi

	# The scratch dir a judge/close call's Read is scoped to: whatever its
	# prompt's own {{scratch}} placeholder resolves to below, computed the
	# same way — call_scratch, its actual cwd, UNLESS the caller already
	# set its own (desk_step_close's own per-session seed dir, which
	# persists past this call and is what its prompt is actually pointed
	# at). These must always agree, or a scoped Read can't reach what the
	# prompt just told the model to read.
	local effective_scratch
	effective_scratch="$(jq -r '.scratch // empty' <<< "$placeholders_json")"
	[ -n "$effective_scratch" ] || effective_scratch="$call_scratch"
	tools_csv="$(desk_step_allowed_tools "$step_json" "$effective_scratch")"

	# The same judge/close-and-has-Read condition desk_step_allowed_tools
	# checks, so the deny hook's own --scratch backstop (deny-unlisted-
	# tool.sh) gets wired up for exactly the calls whose --allowedTools
	# just got a Read(...) glob, never trusting that glob alone.
	local hook_scratch=""
	if { [ "$kind" = "judge" ] || [ "$kind" = "close" ]; } \
		&& jq -e '(.tools // []) | index("Read")' > /dev/null 2>&1 <<< "$step_json"; then
		hook_scratch="$effective_scratch"
	fi

	local prompt_file="$call_scratch/prompt.txt"
	if [ -n "$prompt_rel" ]; then
		# `scratch` is filled in here, generically, for any prompt that
		# references it: call_scratch is exactly the cwd desk_call_model is
		# about to run in (below), so it's the one universally-correct value
		# — UNLESS the caller already set its own (see effective_scratch
		# just above).
		local full_placeholders
		full_placeholders="$(jq -c --arg scratch "$call_scratch" \
			'if has("scratch") then . else . + {scratch: $scratch} end' <<< "$placeholders_json")"
		desk_render_prompt "$(desk_prompt_path "$prompt_rel")" "$full_placeholders" > "$prompt_file"
	else
		: > "$prompt_file"
	fi

	local settings_arg="" restricted="true" strict_mcp="false" mcp_config=""
	if [ "$connector" = "true" ]; then
		restricted="false"
		local tools_arr
		tools_arr="$(jq -r '(.tools // [])[]' <<< "$step_json")"
		local pinned_args_file=""
		if [ -n "$pinned_args_json" ] && [ "$pinned_args_json" != "null" ]; then
			pinned_args_file="$call_scratch/pinned-args.json"
			printf '%s' "$pinned_args_json" > "$pinned_args_file"
		fi
		settings_arg="$(desk_write_deny_hook_settings "$call_scratch" "$pinned_args_file" "$hook_scratch" $tools_arr)"
	else
		# A non-connector call whose tools need an MCP server (e.g. T's
		# ticket search) supplies its own --mcp-config via the
		# step's `mcp_config` field, resolved relative to $DESK_CONFIG's
		# directory the same way `prompt` is (desk_prompt_path is generic
		# over any config-relative path, not just prompt files). A step
		# with none just gets none, same as a plain --restricted call with
		# only built-ins.
		mcp_config="$(jq -r '.mcp_config // empty' <<< "$step_json")"
		if [ -n "$mcp_config" ]; then
			mcp_config="$(desk_prompt_path "$mcp_config")"
			strict_mcp="true"
		fi
		# A restricted call otherwise gets no --settings at all (it needs
		# none: --allowedTools plus --permission-mode dontAsk already do
		# the job) — except a judge/close call whose Read is scoped above,
		# which still gets this hook wired in as that scoping's own second
		# layer.
		if [ -n "$hook_scratch" ]; then
			local tools_arr
			tools_arr="$(jq -r '(.tools // [])[]' <<< "$step_json")"
			settings_arg="$(desk_write_deny_hook_settings "$call_scratch" "" "$hook_scratch" $tools_arr)"
		fi
	fi

	local out="$PASS_SCRATCH/${id}-stream.jsonl"
	# `--tools` (which tools are even LOADED) is its own layer beneath
	# `--allowedTools`/`--permission-mode dontAsk` (which of the loaded
	# ones may actually be called): a connector call needs the claude.ai
	# connectors loaded at all, which also loads every built-in
	# (Bash, Write, WebFetch, ...) unless `--tools` narrows the set — the
	# deny hook (desk_write_deny_hook_settings) then refuses any of those
	# by NAME, but a tool that was never loaded is refused before it ever
	# gets that far. Only a connector call needs this: a plain
	# `--restricted` call already loads nothing but its own `--allowedTools`.
	local tools_arg=""
	[ "$connector" = "true" ] && tools_arg="$tools_csv"
	local rc
	desk_call_model \
		--scratch "$call_scratch" \
		--prompt-file "$prompt_file" \
		--allowed-tools "$tools_csv" \
		${tools_arg:+--tools "$tools_arg"} \
		--connector "$connector" \
		--restricted "$restricted" \
		${mcp_config:+--mcp-config "$mcp_config"} \
		--strict-mcp-config "$strict_mcp" \
		${settings_arg:+--settings "$settings_arg"} \
		--max-budget-usd "$max_budget_usd" \
		${session_name:+--name "$session_name"} \
		--timeout "$timeout" \
		--config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
		--out "$out"
	rc=$?

	desk_extract_tool_results "$out" > "$PASS_SCRATCH/${id}-tool-results.jsonl" 2> /dev/null
	desk_extract_tool_uses "$out" > "$PASS_SCRATCH/${id}-tool-uses.jsonl" 2> /dev/null
	# This call's own real spend, appended to the pass's own running cost
	# log (one number per line — desk-run sums it into status.json's
	# per-pass total_cost_usd once the whole pass is done; a bash function
	# invoked via command substitution, as every step here is, can't hand
	# a running total back to its caller through a variable, so a file is
	# the one channel that survives the subshell).
	local call_cost
	call_cost="$(desk_extract_total_cost_usd "$out")"
	[ -n "$call_cost" ] && printf '%s\n' "$call_cost" >> "$PASS_SCRATCH/.costs.log"
	# A visible call's own cwd is left standing (desk_call_model's own
	# header comment): a follow-up `claude --resume` needs it, and
	# desk_prune_old_runs is the only thing that ever sweeps it, days
	# later. An ordinary ephemeral call's scratch dir is still cleaned up
	# right here, same as before.
	[ -n "$session_name" ] || rm -rf "$call_scratch"

	if [ "$rc" -eq 124 ]; then
		echo "timeout"
	elif [ "$rc" -ne 0 ]; then
		echo "failed"
	else
		echo "ok"
	fi
}

desk_step_fetch() { desk_step_model_call "$@"; }
desk_step_ticket_status() { desk_step_model_call "$@"; }

# desk_step_judge <pass> <step_json> <repo> <placeholders_json> <pass_ctx_json> <file>...
# The judge call's own scratch-dir inputs (prompts/README.md's own table:
# notes.md, reading.md, sources.json, f-private.json, f-web.json,
# tickets.json, optional sessions.json/open-items.json) — named generically
# via the step's own `input_files` (falling back to that full pinned list
# when a step doesn't declare one, so an as-yet-unconfigured private config
# still gets everything J's own prompt expects) and produced one by one via
# desk_seed_named_file, never re-derived per file kind here. `pass_ctx_json`
# is desk-run's own per-pass context (repo/sources_path/pass_scratch/
# old_ticket_cache); this adds `files` (this call's own file list) to it
# before handing it to each producer.
desk_step_judge() {
	local pass="$1" step_json="$2" repo="$3" placeholders_json="${4:-}" pass_ctx_json="${5:-}"
	[ -n "$placeholders_json" ] || placeholders_json='{}'
	[ -n "$pass_ctx_json" ] || pass_ctx_json='{}'
	shift 5
	local files=("$@")
	local seed="$PASS_SCRATCH/judge-seed"
	mkdir -p "$seed"

	local files_json ctx
	files_json="$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"
	ctx="$(jq -c --argjson files "$files_json" '. + {files: $files}' <<< "$pass_ctx_json")"

	local input_files_json
	input_files_json="$(jq -c '.input_files // [
		"notes.md", "reading.md", "sources.json", "f-private.json", "f-web.json",
		"tickets.json", "sessions.json", "open-items.json"
	]' <<< "$step_json")"
	local n name i
	n="$(jq 'length' <<< "$input_files_json" 2> /dev/null || echo 0)"
	for ((i = 0; i < n; i++)); do
		name="$(jq -r ".[$i]" <<< "$input_files_json")"
		desk_seed_named_file "$name" "$seed" "$ctx"
	done

	local scheduled_date
	scheduled_date="$(jq -r '.scheduled_date // empty' <<< "$pass_ctx_json")"
	desk_step_model_call "$pass" "$step_json" "judge" "$placeholders_json" "$seed" "" "$scheduled_date"
}

# ---------------------------------------------------------------------------
# write: the pinned single-tool call (design.md's W / "the one unattended
# external write"). Exactly one tool allowed, plus (when `pinned_args_json`
# is given) the deny-hook also refuses any call whose own tool_input isn't
# one of that exact set — the caller (desk-run, for W specifically) is the
# one place that knows the runner-pinned thread ids/label this pass, built
# from a fetch step's own raw tool_results, never model prose.
# ---------------------------------------------------------------------------
desk_step_write() {
	local pass="$1" step_json="$2" pinned_args_json="${3:-null}" placeholders_json="${4:-}" scheduled_date="${5:-}"
	[ -n "$placeholders_json" ] || placeholders_json='{}' # see desk_render_prompt's own comment on why not "${4:-{}}"
	local id tool
	id="$(jq -r '.id' <<< "$step_json")"
	tool="$(jq -r '(.tools // [])[0] // empty' <<< "$step_json")"
	if [ -z "$tool" ]; then
		desk_log "$pass" "write step $id: no tool configured"
		echo "failed"
		return
	fi
	desk_step_model_call "$pass" "$step_json" "write" "$placeholders_json" "" "$pinned_args_json" "$scheduled_date"
}

# ---------------------------------------------------------------------------
# commit_push: fully generic, no stub — see claude/desk-lib/git-ops.sh.
# ---------------------------------------------------------------------------
desk_step_commit_push_kind() {
	local repo="$1"
	shift
	desk_step_commit_push "$repo" "$@"
}

# ---------------------------------------------------------------------------
# close: session selection is generic/config-driven (design.md §3
# "Closing"). Ordering follows design's own words exactly: capture written
# to the proposal and queued in the ledger; only once at least the name
# is queued, `close` (session-recorder.sh) records it; SIGTERM; liveness
# re-checked, a survivor recorded as a failed close — so SIGTERM is never
# sent to a session nothing durable ever recorded wanting to close.
# ---------------------------------------------------------------------------

# Every session-status.sh entry that's a `close` candidate right now:
# live, has a recorder start event, not on `keep_open`, and idle at least
# `close_after_working_days` *working* days by last_activity (an exact
# Mon-Fri walk, desk-lib/lock.sh's desk_working_days_since — no longer the
# calendar-day approximation this build started with). Design's other
# guards (max_closes this pass, "not the first pass after more than N
# days away", a live re-check "just before" SIGTERM) are applied by the
# caller around this list, not inside it.
desk_close_candidates() {
	local close_after_working_days="$1" keep_open_json="$2"
	local now
	now="$(desk_now)"
	local all
	all="$(session-status.sh 2> /dev/null | jq -s '.')" || return 1
	local pre_filtered
	pre_filtered="$(jq -c --argjson keep "$keep_open_json" '
		[ .[] | select(
			.live == true
			and .has_start_event == true
			and (.name as $n | ($keep | index($n)) | not)
			and (.last_activity != null)
			and (.duplicate_pids != true)
		) ]
	' <<< "$all")"

	local n out
	out="[]"
	n="$(jq 'length' <<< "$pre_filtered")"
	local i
	for ((i = 0; i < n; i++)); do
		local sess last_activity wd
		sess="$(jq -c ".[$i]" <<< "$pre_filtered")"
		last_activity="$(jq -r '.last_activity' <<< "$sess")"
		wd="$(desk_working_days_since "$last_activity" "$now")"
		if [ "$wd" -ge "$close_after_working_days" ]; then
			out="$(jq -c --argjson s "$sess" '. + [$s]' <<< "$out")"
		fi
	done
	printf '%s' "$out"
}

# SIGTERMs $2 (a pid) and re-checks liveness after a short grace period.
# Prints "closed" or "failed" (a survivor). Never `/exit`-into-a-tab
# (design.md §3): this only ever signals the process directly.
desk_close_session() {
	local pid="$1" grace="${2:-5}"
	kill -TERM "$pid" 2> /dev/null
	local waited=0
	while desk_pid_alive "$pid" && [ "$waited" -lt "$grace" ]; do
		sleep 1
		waited=$((waited + 1))
	done
	if desk_pid_alive "$pid"; then
		echo "failed"
	else
		echo "closed"
	fi
}

# ---------------------------------------------------------------------------
# capture: the 16:30 pass's own "running"/"dropped" session captures
# (design.md §3 "Capture" — a name on top, no model call, no transcript
# read: purely mechanical, built off session-status.sh and the ledger).
# ---------------------------------------------------------------------------

# The short id every capture of an unnamed session labels itself with
# (design.md's own "<auto title> · <short id>"), also what the hotkey's
# resume-by-token relies on to disambiguate one from another.
desk_short_session_id() {
	printf '%s' "${1:0:8}"
}

# True (exit 0) if $2 (a session's own display name) already appears
# somewhere in $1 (a file's committed HEAD content) as a whole token —
# letters, digits, `_`, `-` only, the same alphabet a token under the
# cursor is read with elsewhere — never as a bare substring inside a
# longer word. design.md §3: "a name already in the notes" is never
# re-captured; an empty name never matches anything, by design (nothing to
# have already written down).
desk_name_in_notes() {
	local head_content="$1" name="$2"
	[ -n "$name" ] || return 1
	NAME="$name" perl -0777 -ne '
		my $n = quotemeta($ENV{NAME});
		exit(/(?<![A-Za-z0-9_-])$n(?![A-Za-z0-9_-])/ ? 0 : 1);
	' <<< "$head_content"
}

# True (exit 0) if $1 (ledger-state's own JSON) already holds an item for
# (session_id $2, capture_kind $3) — design.md §2 "Captures dedup on
# (session id, kind), not content": whatever that item's own state (still
# queued, laid in, even postponed), this pass must never add a second one
# for the same session and the same kind. A repeat "running" capture folds
# into the existing queued/pending one simply by never being re-emitted;
# one already accepted or declined never comes back either, the same way.
# A different kind for the same session (a later "dropped" after an
# earlier "running") is never blocked by this — the two dedup separately.
desk_capture_already_ledgered() {
	local ledger_state_json="$1" session_id="$2" capture_kind="$3"
	jq -e --arg sid "$session_id" --arg ck "$capture_kind" '
		[.items[] | select(.session_id == $sid and .capture_kind == $ck)] | length > 0
	' > /dev/null 2>&1 <<< "$ledger_state_json"
}

# desk_step_capture_sessions <pass> <repo> <scheduled_date> <file>...
# design.md §3's own two kinds: "running" (live right now) and "dropped"
# (has a start event, isn't live, and its last run never got a deliberate
# end — prompt_input_exit/clear/logout/resume all surface as `ended: true`
# with exactly that reason, which the filter below excludes outright;
# whether that's because the machine rebooted since or the process itself
# crashed within the same boot, session-status.sh's own liveness check
# already tells the two apart, so "not live" is all this needs). Only
# sessions with a recorder start event qualify (excludes both pre-recorder
# transcripts and a scheduled desk-run call, source-tagged and excluded by
# name) — design's "so pre-recorder transcripts and headless calls never
# flood the top."
#
# `$4..` are the pass's configured files, needed only for
# desk_stage_and_write_proposal's own postponed/queued bookkeeping across
# all of them; every capture item itself always lands in notes.md
# (design's own convention for a suggestion with no clearer home — the
# same literal desk_apply_caps's own overflow summary already uses).
#
# Prints "ok" once every candidate is processed (nothing here is ever a
# per-candidate step failure), "failed" only if the mechanism itself
# (session-status.sh, the ledger read) breaks.
desk_step_capture_sessions() {
	local pass="$1" repo="$2" scheduled_date="$3"
	shift 3
	local files=("$@")

	local all
	all="$(session-status.sh 2> /dev/null | jq -s '.')" || {
		desk_log "$pass" "capture: session-status.sh failed"
		echo "failed"
		return
	}

	local head_content
	head_content="$(git -C "$repo" show HEAD:notes.md 2> /dev/null || true)"

	local ledger_state
	ledger_state="$(desk_nvim_cli ledger-state "$repo")" || {
		desk_log "$pass" "capture: ledger-state failed"
		echo "failed"
		return
	}

	# Excludes a scheduled run's own session on any of three independent
	# grounds (design.md's own "16:30 never captures a desk-run session" —
	# each is a separate defense, since any one alone can miss it): the
	# recorder's own any_desk_run_start (true the moment ANY of its start
	# events, not just the last, was tagged desk-run — a scheduled call he
	# later resumes himself under his own permissions gets a second, real
	# start event that would otherwise overwrite a last-event-only check
	# right as he starts using it); its name starting with "desk-" (the
	# runner's own naming convention for a visible call,
	# "desk-<pass>-<date>-<step>"); or its cwd sitting under
	# $DESK_RUNS_ROOT (a visible call's own durable scratch dir) — this
	# third check is what still catches one even if the first two were
	# somehow both wrong (an old recorder record predating this field, a
	# session renamed away from the convention).
	local candidates
	candidates="$(jq -c --arg runs_root "$DESK_RUNS_ROOT" '
		def is_desk_run:
			(.any_desk_run_start == true)
			or ((.name // "") | startswith("desk-"))
			or (($runs_root != "") and ((.cwd // "") | startswith($runs_root)));
		[ .[] | select(.has_start_event == true and (is_desk_run | not)) ] as $eligible
		| [ $eligible[] | select(.live == true) | . + {capture_kind: "running"} ]
		+ [ $eligible[] | select(.live == false and (.ended == false or .end_reason == "other")) | . + {capture_kind: "dropped"} ]
	' <<< "$all")"

	local n items_json
	items_json="[]"
	n="$(jq 'length' <<< "$candidates")"
	local i
	for ((i = 0; i < n; i++)); do
		local sess id name name_source capture_kind headline
		sess="$(jq -c ".[$i]" <<< "$candidates")"
		id="$(jq -r '.id' <<< "$sess")"
		name="$(jq -r '.name // ""' <<< "$sess")"
		name_source="$(jq -r '.name_source // "ai_or_none"' <<< "$sess")"
		capture_kind="$(jq -r '.capture_kind' <<< "$sess")"

		if [ "$name_source" = "user" ] && [ -n "$name" ]; then
			if desk_name_in_notes "$head_content" "$name"; then
				desk_log "$pass" "capture: $id ($capture_kind) — '$name' already in the notes, skipping"
				continue
			fi
			headline="$name"
		else
			headline="$name · $(desk_short_session_id "$id")"
		fi

		if desk_capture_already_ledgered "$ledger_state" "$id" "$capture_kind"; then
			desk_log "$pass" "capture: $id ($capture_kind) — already captured, skipping"
			continue
		fi

		items_json="$(jq -c --arg h "$headline" --arg sid "$id" --arg ck "$capture_kind" '
			. + [{file: "notes.md", kind: "add", target: "top", before: "", after: $h,
			      source: ("session:" + $sid), headline: $h, session_id: $sid, capture_kind: $ck}]
		' <<< "$items_json")"
	done

	local kept_n
	kept_n="$(jq 'length' <<< "$items_json")"
	if [ "$kept_n" -eq 0 ]; then
		desk_log "$pass" "capture: nothing new to capture"
		echo "ok"
		return
	fi

	items_json="$(desk_validate_items "$items_json" "")"

	local items_file sha
	items_file="$PASS_SCRATCH/capture-items.json"
	jq -n --argjson items "$items_json" '{items: $items}' > "$items_file"
	if ! sha="$(desk_stage_and_write_proposal "$repo" "$pass" "$scheduled_date" "$items_file" "${files[@]}")" || [ -z "$sha" ]; then
		desk_log "$pass" "capture: staging failed"
		echo "failed"
		return
	fi
	desk_log "$pass" "capture: staged $kept_n item(s)"
	echo "ok"
}

# The capped tail of a session's own transcript (design's "the capped end
# of that session's transcript"), as JSON lines, each keeping its own
# `uuid` — the 16:30-close prompt's own per-bullet turn citations are
# checked against exactly this file, never the full transcript. $3 = cap
# in lines (the step's own `cap` field; a step with none gets 200).
desk_write_transcript_tail() {
	local transcript_path="$1" out_file="$2" cap="${3:-200}"
	if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
		tail -n "$cap" "$transcript_path" > "$out_file" 2> /dev/null || : > "$out_file"
	else
		: > "$out_file"
	fi
}

# desk_step_close <pass> <step_json> <config_json> <repo> <file>...
# The composite close step (design.md §3 "Closing", §5's own ordering).
# Skips every candidate (closes nothing) on the first pass after more than
# `away_days` days away — design's own safety valve against a close storm
# on first wake. Otherwise, per candidate, in order: the per-session call;
# its reply's turn citations verified/stripped and its text sanitized
# (desk-lib/validate.sh); if a closure-note item survives, staged into the
# ledger/proposal (capture_kind "would_close" under `log_only`, "closed"
# otherwise) — only once that staging succeeds does this re-check the
# session is still live and idle, then (unless `log_only`, default true)
# tell session-recorder.sh to record the close, SIGTERM, and re-check
# liveness, counting a survivor as a failed close rather than retrying —
# and telling session-recorder.sh that too (its own `close-failed` event,
# surfaced by session-status.sh), since the "close" event already recorded
# stays exactly as it was and would otherwise be the only record, silently
# wrong about what actually happened.
# `max_closes` (K) bounds real closes only; `log_only` queues every
# would-close candidate regardless, so the dry-run week (design.md §8)
# sees the whole list. Prints "ok" once every candidate is processed (each
# one's own outcome is only ever logged/counted, never a step failure),
# "failed" only if the mechanism itself (session-status.sh) breaks.
desk_step_close() {
	local pass="$1" step_json="$2" config_json="$3" repo="$4" scheduled_date="$5"
	shift 5
	local files=("$@")

	local close_after keep_open max_closes away_days log_only cap
	close_after="$(jq -r '.close_after_working_days // 3' <<< "$config_json")"
	keep_open="$(jq -c '.keep_open // []' <<< "$config_json")"
	max_closes="$(jq -r '.max_closes // 3' <<< "$config_json")"
	away_days="$(jq -r '.away_days // 5' <<< "$config_json")"
	# NOT `.log_only // true`: jq's `//` treats a real `false` as falsy
	# too, so that spelling would silently ignore an explicit
	# "log_only": false and always come back "true".
	log_only="$(jq -r 'if .log_only == null then true else .log_only end' <<< "$config_json")"
	cap="$(jq -r '.cap // 200' <<< "$step_json")"

	local last_ok now away_gap
	now="$(desk_now)"
	last_ok="$(desk_status_last_ok_run "$pass")"
	if [ -n "$last_ok" ]; then
		away_gap=$(( (now - last_ok) / 86400 ))
		if [ "$away_gap" -gt "$away_days" ]; then
			desk_log "$pass" "close: first pass after ${away_gap}d away (> ${away_days}d) — closing nothing this pass"
			echo "ok"
			return
		fi
	fi

	local candidates
	candidates="$(desk_close_candidates "$close_after" "$keep_open")" || {
		desk_log "$pass" "close: session-status.sh failed"
		echo "failed"
		return
	}

	local n closes_this_pass=0
	n="$(jq 'length' <<< "$candidates")"
	desk_log "$pass" "close: $n candidate(s) idle >= $close_after working days"

	local i
	for ((i = 0; i < n; i++)); do
		local sess id name transcript_path
		sess="$(jq -c ".[$i]" <<< "$candidates")"
		id="$(jq -r '.id' <<< "$sess")"
		name="$(jq -r '.name // .id' <<< "$sess")"
		transcript_path="$(jq -r '.transcript_path // empty' <<< "$sess")"

		local seed
		seed="$PASS_SCRATCH/close-seed-$id"
		mkdir -p "$seed"
		echo "$sess" > "$seed/session.json"
		desk_write_transcript_tail "$transcript_path" "$seed/transcript-tail.jsonl" "$cap"
		cp -f "$seed/transcript-tail.jsonl" "$PASS_SCRATCH/close-$id-transcript-tail.jsonl" 2> /dev/null
		# "notes.md: his committed notes, for placement only" (prompts/
		# README.md, 1630-close.md) — the marked copy, same as J's, though a
		# 1630 call never anchors an *edit* on a marked line the way J's own
		# in-place suggestions might, only ever placing new bullets under or
		# after one.
		desk_write_marked_head_copy "$repo" "notes.md" "$seed/notes.md"

		local per_session_step
		per_session_step="$(jq -c --arg id "$id" '.id = ("close-" + $id)' <<< "$step_json")"
		local placeholders
		placeholders="$(jq -n --arg sn "$name" --arg sid "$id" --arg scratch "$seed" --arg today "$(date +%F)" \
			'{session_name: $sn, session_id: $sid, scratch: $scratch, today: $today}')"
		local call_result
		call_result="$(desk_step_model_call "$pass" "$per_session_step" "close:$name" "$placeholders" "$seed" "" "$scheduled_date")"
		desk_log "$pass" "close: session $name call -> $call_result"
		[ "$call_result" = "ok" ] || continue

		local final_text items_json
		final_text="$(desk_extract_final_text "$PASS_SCRATCH/close-${id}-stream.jsonl")"
		items_json="$(jq -c 'if type == "object" and has("items") then .items else . end' \
			<<< "$final_text" 2> /dev/null)"
		if [ -z "$items_json" ] || ! jq -e . > /dev/null 2>&1 <<< "$items_json"; then
			desk_log "$pass" "close: session $name reply wasn't the pinned items shape — no capture"
			continue
		fi
		items_json="$(desk_verify_and_strip_turn_citations "$items_json" "$PASS_SCRATCH/close-$id-transcript-tail.jsonl")"
		items_json="$(desk_validate_items "$items_json" "")" # no fetch tool results: no URL is ever allowed
		if [ "$(jq 'length' <<< "$items_json")" -eq 0 ]; then
			desk_log "$pass" "close: session $name — no valid closure-note item (invalid citation, or none returned)"
			continue
		fi

		# Real closing needs BOTH log_only off and this pass still under
		# its K cap; either one missing means queue the capture (as a
		# dry-run "would_close") without ever signaling the session.
		local would_close="true"
		if [ "$log_only" != "true" ] && [ "$closes_this_pass" -lt "$max_closes" ]; then
			would_close="false"
		fi
		local capture_kind="closed"
		[ "$would_close" = "true" ] && capture_kind="would_close"
		items_json="$(jq -c --arg sid "$id" --arg ck "$capture_kind" \
			'map(.session_id = $sid | .capture_kind = $ck)' <<< "$items_json")"

		local items_file sha
		items_file="$PASS_SCRATCH/close-$id-items.json"
		jq -n --argjson items "$items_json" '{items: $items}' > "$items_file"
		if ! sha="$(desk_stage_and_write_proposal "$repo" "$pass" "$scheduled_date" "$items_file" "${files[@]}")" || [ -z "$sha" ]; then
			desk_log "$pass" "close: session $name — staging the capture failed, not closing"
			continue
		fi

		if [ "$would_close" = "true" ]; then
			desk_log "$pass" "close: session $name — would close (log_only or over max_closes); capture queued"
			continue
		fi

		# Re-check just before signaling (design's "still idle on a
		# re-check just before"): a fresh read, the same session id,
		# still both live AND idle — the candidate list was built (and
		# every earlier candidate in this same loop was processed,
		# model call included) possibly minutes ago, so "still live" alone
		# isn't "still idle": he may have come back to this exact session
		# in the meantime, and a session he's actively using again must
		# never be the one that gets SIGTERM'd just because it was idle
		# when the pass started.
		local recheck_matches recheck_n
		recheck_matches="$(session-status.sh 2> /dev/null | jq -c --arg id "$id" 'select(.id == $id)')"
		recheck_n="$(jq -s 'length' <<< "$recheck_matches" 2> /dev/null || echo 0)"
		if [ "$recheck_n" -gt 1 ]; then
			# Two live pid files claiming the same session id is exactly
			# the kind of corruption that must never be resolved by
			# guessing which one is "really" this session — refuse outright
			# rather than risk signaling the wrong process.
			desk_log "$pass" "close: session $name — $recheck_n pid files share session id $id on re-check — refusing to signal"
			continue
		fi
		if [ "$recheck_n" -ne 1 ]; then
			desk_log "$pass" "close: session $name is no longer live on re-check — not signaling"
			continue
		fi
		local recheck
		recheck="$recheck_matches"
		if [ "$(jq -r '.live // false' <<< "$recheck")" != "true" ]; then
			desk_log "$pass" "close: session $name is no longer live on re-check — not signaling"
			continue
		fi
		if [ "$(jq -r '.duplicate_pids // false' <<< "$recheck")" = "true" ]; then
			# More than one pid file names this session id (session-status.sh's
			# own duplicate_pids) — the reader's own "prefer the live one" is
			# a best-effort display choice, never grounds for actually
			# signaling a process: refuse outright rather than risk killing
			# the wrong one.
			desk_log "$pass" "close: session $name has more than one pid file on re-check — refusing to signal"
			continue
		fi

		local recheck_last_activity recheck_working_days
		recheck_last_activity="$(jq -r '.last_activity // empty' <<< "$recheck")"
		if [ -z "$recheck_last_activity" ]; then
			desk_log "$pass" "close: session $name has no last_activity on re-check — not signaling"
			continue
		fi
		recheck_working_days="$(desk_working_days_since "$recheck_last_activity" "$(desk_now)")"
		if [ "$recheck_working_days" -lt "$close_after" ]; then
			desk_log "$pass" "close: session $name is active again on re-check (idle only ${recheck_working_days}d) — not signaling"
			continue
		fi

		local pid
		pid="$(jq -r '.pid // empty' <<< "$recheck")"
		if [ -z "$pid" ]; then
			desk_log "$pass" "close: session $name has no pid on re-check — not signaling"
			continue
		fi

		"$DESK_SESSION_RECORDER_BIN" close "$id" 2> /dev/null
		local close_result
		close_result="$(desk_close_session "$pid" "$DESK_KILL_GRACE_SECS")"
		if [ "$close_result" = "closed" ]; then
			closes_this_pass=$((closes_this_pass + 1))
			desk_status_bump closes
			desk_log "$pass" "close: session $name closed"
		else
			desk_status_bump failed_closes
			"$DESK_SESSION_RECORDER_BIN" close-failed "$id" 2> /dev/null
			desk_log "$pass" "close: session $name survived SIGTERM — recorded as a failed close"
		fi
	done
	echo "ok"
}

# desk_open_follow_up_tab <pass> <scheduled_date> <follow_up_step>
# design.md's later "Runs he can open and continue": after this pass
# FINISHES (desk-run calls this once, after the step loop, whatever the
# pass's own result — "a failed pass still opens the tab on what exists"),
# open one Ghostty tab resuming the pass's own `follow_up_step` call — the
# morning pass's J (which holds his notes plus the fetched material), or
# 16:30's most recently-run close call, the config's own per-pass
# `follow_up_step` naming which step id.
#
# `follow_up_step` matches a run directory under
# $DESK_RUNS_ROOT/<pass>-<scheduled_date>/ either by its exact id (a plain
# step like "J") or by prefix "<follow_up_step>-" (desk_step_close's own
# per-session ids, "close-<session id>" — several may exist in one pass);
# each match's --session-id/-n name is resolved back to a live session
# through session-status.sh's own `resolve` mode (D7's own exact-match
# lookup, never re-derived here). Nothing configured, nothing that
# actually ran this pass, or nothing that resolves to a real session are
# all "ok", not "failed" — there was simply nothing to open. The other
# names, when more than one resolves, are logged only (design's "the
# others' names in status"); the most recently active one is what
# actually gets a tab.
#
# At most one tab is ever opened per (pass, scheduled_date) — a guard
# stamp under $DESK_GUARD_DIR, written only once this function has
# actually opened or focused something, so a later retry slot the same
# scheduled date (a partial pass's own re-run) never opens a second one on
# top of a tab he may already be sitting in. If the resolved session is
# already LIVE (he's already in it — resumed it himself, or an earlier
# slot's own call this same run is still there), this never opens a
# second process against it: it focuses the live tab by tty instead (the
# same D7 mechanism the notes hotkey uses for a live session), and skips
# entirely — never resumes — if focusing fails or no tty was recorded,
# same reasoning as the hotkey: a second process against a live transcript
# is worse than no tab at all. Only a not-live session gets a fresh
# `claude --resume` tab (the same his-default-permissions envelope: no
# --restricted, --tools, --strict-mcp-config or --permission-mode)
# desk_step_open_tab's own `restricted: false` path uses for the
# Wednesday tab.
desk_open_follow_up_tab() {
	local pass="$1" scheduled_date="$2" follow_up_step="$3"
	if [ -z "$follow_up_step" ]; then
		echo "ok"
		return
	fi

	local guard_marker="$DESK_GUARD_DIR/followup-$pass-$scheduled_date"
	if [ -f "$guard_marker" ]; then
		desk_log "$pass" "follow-up tab: already opened/focused one for $pass-$scheduled_date — skipping"
		echo "ok"
		return
	fi

	local runs_dir="$DESK_RUNS_ROOT/$pass-$scheduled_date"
	if [ ! -d "$runs_dir" ]; then
		desk_log "$pass" "follow-up tab: no runs directory for $pass-$scheduled_date — nothing to open"
		echo "ok"
		return
	fi

	local -a candidate_names=()
	local d base
	for d in "$runs_dir"/*; do
		[ -d "$d" ] || continue
		base="$(basename "$d")"
		case "$base" in
			"$follow_up_step" | "$follow_up_step"-*) candidate_names+=("desk-$pass-$scheduled_date-$base") ;;
		esac
	done
	if [ "${#candidate_names[@]}" -eq 0 ]; then
		desk_log "$pass" "follow-up tab: no $follow_up_step call ran this pass — nothing to open"
		echo "ok"
		return
	fi

	local -a resolved=()
	local name entry
	for name in "${candidate_names[@]}"; do
		entry="$(session-status.sh resolve "$name" 2> /dev/null)" && [ -n "$entry" ] && resolved+=("$entry")
	done
	if [ "${#resolved[@]}" -eq 0 ]; then
		desk_log "$pass" "follow-up tab: $follow_up_step ran but no session resolved by name — nothing to open"
		echo "ok"
		return
	fi

	# Most recently active wins; the rest are named in the log only.
	local sorted best id cwd others
	sorted="$(printf '%s\n' "${resolved[@]}" | jq -s 'sort_by(.last_activity // 0)')"
	best="$(jq -c '.[-1]' <<< "$sorted")"
	others="$(jq -r '.[0:-1][] | .name' <<< "$sorted" | tr '\n' ',' | sed 's/,$//')"
	[ -n "$others" ] && desk_log "$pass" "follow-up tab: also ran this pass: $others"

	id="$(jq -r '.id // empty' <<< "$best")"
	cwd="$(jq -r '.cwd // empty' <<< "$best")"
	if [ -z "$id" ] || [ -z "$cwd" ]; then
		desk_log "$pass" "follow-up tab: resolved session missing id/cwd — not opening"
		echo "failed"
		return
	fi

	if [ "$(jq -r '.live // false' <<< "$best")" = "true" ]; then
		local tty
		tty="$(jq -r '.tty // empty' <<< "$best")"
		if [ -z "$tty" ]; then
			desk_log "$pass" "follow-up tab: $follow_up_step's session ($id) is live but has no recorded tty — never resuming a live one, skipping"
			echo "ok"
			return
		fi
		local focus_helper="${DESK_FOCUS_TAB_BIN:-desk-focus-tab.sh}"
		if "$focus_helper" "$tty" > /dev/null 2>&1; then
			desk_log "$pass" "follow-up tab: $follow_up_step's session ($id) is already live — focused its tab instead of opening a second one"
			desk_write_atomic "$guard_marker" ""
			echo "ok"
		else
			desk_log "$pass" "follow-up tab: $follow_up_step's session ($id) is live but focusing its tab failed — not resuming (would risk a second process)"
			echo "ok"
		fi
		return
	fi

	local command
	command="claude --resume $(desk_shq "$id")"
	local helper="${DESK_OPEN_TAB_BIN:-desk-open-tab.sh}"
	if "$helper" "$command" "$id" "$cwd" > /dev/null 2>&1; then
		desk_log "$pass" "follow-up tab: opened $follow_up_step ($id) in $cwd"
		desk_write_atomic "$guard_marker" ""
		echo "ok"
	else
		desk_log "$pass" "follow-up tab: $helper failed"
		echo "failed"
	fi
}

# Resolves an open_tab step's own launch-envelope paths (`mcp_config`,
# `settings`, `skill`) relative to the *workspace* root — one directory
# above $DESK_CONFIG's own (desk/config.json sits inside the workspace's
# own desk/ directory, so its parent is the workspace root itself) — rather
# than desk_prompt_path's config-directory base. This matches how those
# fields are actually spelled in the private config ("desk/weekly/mcp.json",
# "agents/skills/.../SKILL.md": both resolve against the workspace root,
# never against desk/config.json's own directory) — a prompt step's own
# `prompt`/`mcp_config` fields are a different, config-directory-relative
# convention, never confused with this one.
desk_workspace_path() {
	local rel="$1"
	[[ "$rel" = /* ]] && { echo "$rel"; return; }
	# Plain string manipulation, deliberately not `cd -P`-resolved (unlike
	# desk_project_folder_name's own canonicalization elsewhere): the same
	# convention desk_prompt_path already uses, so this never returns a
	# symlink-resolved path a test's own (unresolved) tmp dir wouldn't match.
	echo "$(dirname "$(dirname "$DESK_CONFIG")")/$rel"
}

# desk_notes_diff_since_epoch <notes_diff_since>
# Resolves an open_tab step's own `notes_diff_since` to an epoch — the
# window-start end of the notes-diff (weekly/README.md). Only "last_wednesday"
# is a known value so far (the weekly pass's own config); anything else logs
# and returns empty, which desk_write_notes_diff treats as "diff against the
# empty tree" rather than failing the step over an unrecognized value.
desk_notes_diff_since_epoch() {
	local kind="$1"
	case "$kind" in
		last_wednesday) desk_last_weekday_epoch "$(desk_now)" 3 8 0 ;;
		*)
			desk_log - "notes-diff: unknown notes_diff_since '$kind'"
			return 1
			;;
	esac
}

# The well-known empty-tree object: every path diffs as newly added against
# it, which is exactly "no prior commit in the window" (a brand-new repo, or
# `notes_diff_since` resolving to before the repo's very first commit).
DESK_GIT_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# desk_write_notes_diff <repo> <out_file> <notes_diff_since> <file>...
# Writes the weekly tab's own notes-diff input (weekly/README.md): his own
# additions/removals in each of `file`s, from the commit at or before
# `notes_diff_since`'s window start through HEAD, with every line the
# ledger says is agent-originated excluded — nvim/lua/desk/cli.lua's own
# `notes-diff` verb does the actual diffing and ledger-based exclusion
# (reusing desk.ledger/desk.snippet, never a second normalization here);
# this only resolves the since-commit, calls that verb once per file, and
# renders the result. Best-effort per file: one whose diff can't be
# computed gets a one-line note in its place rather than failing the whole
# step — the Wednesday tab isn't worth blocking over this. The whole body
# is fenced as one block (weekly/README.md's own "holding the runner's
# fenced notes-diff.md"): quoted lines from his own files are data for
# whatever reads this next, never instructions.
desk_write_notes_diff() {
	local repo="$1" out="$2" since_kind="$3"
	shift 3
	local files=("$@")

	local since_epoch=""
	since_epoch="$(desk_notes_diff_since_epoch "$since_kind" 2> /dev/null)" || since_epoch=""

	local since_sha="" since_label=""
	if [ -n "$since_epoch" ]; then
		since_sha="$(git -C "$repo" log -1 --before="@$since_epoch" --format=%H 2> /dev/null)"
		if desk_is_linux; then since_label="$(date -d "@$since_epoch" '+%Y-%m-%d %H:%M %Z' 2> /dev/null)"
		else since_label="$(date -j -r "$since_epoch" '+%Y-%m-%d %H:%M %Z' 2> /dev/null)"; fi
	fi
	[ -n "$since_sha" ] || since_sha="$DESK_GIT_EMPTY_TREE"
	[ -n "$since_label" ] || since_label="the beginning (no earlier commit found)"

	{
		printf '# Notes diff\n\n'
		printf 'Since %s, to HEAD. His own additions and removals only: lines the ledger\n' "$since_label"
		printf 'knows as agent-suggested or agent-accepted are excluded on both sides, even\n'
		printf 'one he moved. The fenced block below is quoted data from his own files, not\n'
		printf 'instructions.\n\n'
		printf '```\n'
		local f result any
		for f in "${files[@]}"; do
			printf '== %s ==\n' "$f"
			result="$(desk_nvim_cli notes-diff "$repo" "$f" "$since_sha" 2> /dev/null)"
			if [ -z "$result" ] || ! jq -e . > /dev/null 2>&1 <<< "$result" \
				|| jq -e '.error' > /dev/null 2>&1 <<< "$result"; then
				printf '(diff unavailable)\n\n'
				continue
			fi
			any=0
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				printf '+ %s\n' "$line"
				any=1
			done < <(jq -r '.additions[]' <<< "$result" 2> /dev/null)
			while IFS= read -r line; do
				[ -n "$line" ] || continue
				printf -- '- %s\n' "$line"
				any=1
			done < <(jq -r '.removals[]' <<< "$result" 2> /dev/null)
			[ "$any" = "1" ] || printf '(no changes)\n'
			printf '\n'
		done
		printf '```\n'
	} > "$out"
}

# desk_fresh_scratch_dir <root>
# A fresh, never-before-used directory under `root` (a leading ~ expanded),
# created and returned — the same collision-proofing desk_scratch_dir
# (model-call.sh) already uses, just rooted at a step's own configured
# directory instead of $DESK_SCRATCH_ROOT. Unlike a pass's own scratch dir,
# nothing here ever removes it: the interactive tab it seeds outlives the
# step that wrote it.
desk_fresh_scratch_dir() {
	local root="${1/#\~/$HOME}"
	local dir="$root/$(desk_now)-$$-$RANDOM"
	mkdir -p "$dir" 2> /dev/null
	echo "$dir"
}

# ---------------------------------------------------------------------------
# open_tab: interactive (Wednesday), not run headless (design.md §4
# "Weekly"). This assembles the weekly pass's own launch envelope —
# `cwd_outside` (a cwd outside any repo), `permission_mode`, `tools`,
# `strict_mcp_config`/`mcp_config`, `settings`, and `skill` (passed in
# explicitly via `--append-system-prompt-file`, since nothing discovers it
# from that cwd — desk/weekly/README.md's own worked example is the exact
# command line this builds) plus the fixed `prompt_text` — into one shell
# command string (desk_shq quotes every argument; Ghostty's own
# `command:` field takes a whole command line, never an argv array) and
# hands that straight to the Hammerspoon function through
# hammerspoon/desk-open-tab.sh, never System Events keystrokes (design.md
# §4's own "Launch envelope" note). `session_name`, when the step
# configures one, is checked against the reader first: a session already
# live under that name means he's already in the tab (or resumed it
# himself), so this skips opening a second one — "ok", not "failed", since
# nothing here actually went wrong.
#
# `repo` and `files` (the pass's own notes repo and configured file list —
# desk-run's own `$repo`/`${files[@]}`) are optional: a caller with neither
# to hand (the existing D8b test) gets the exact old behavior, since
# everything below is gated on the step's own `scratch_dir`/`notes_diff_file`/
# `notes_diff_since` fields, absent from that fixture. When `scratch_dir` is
# configured, a fresh directory under it becomes the tab's actual cwd in
# place of `cwd_outside` (weekly/README.md: "from a fresh scratch dir ...
# holding the runner's fenced notes-diff.md"), and — when the notes-diff
# fields are configured too — desk_write_notes_diff seeds that fresh
# directory with the notes-diff file before the tab opens.
#
# `restricted` (default true, so an existing config with the field simply
# absent keeps its full isolation envelope) gates `--restricted`,
# `--permission-mode`, `--tools` and `--strict-mcp-config` together: a step
# that sets it `false` gets none of those — his own default permissions,
# same as any session he opens by hand (design.md's later "Runner
# decisions" call on the Wednesday tab, and a run's own follow-up tab).
# `mcp_config`/`settings`/`skill` are independent of it and still apply
# when configured either way.
# ---------------------------------------------------------------------------
desk_step_open_tab() {
	local step_json="${1:-}" repo="${2:-}"
	local -a files=()
	if [ "$#" -gt 2 ]; then
		shift 2
		files=("$@")
	fi
	[ -n "$step_json" ] || step_json='{}'
	local cwd permission_mode tools_csv strict_mcp mcp_config_rel settings_rel skill_rel prompt_text session_name
	local scratch_root notes_diff_file notes_diff_since restricted
	cwd="$(jq -r '.cwd_outside // empty' <<< "$step_json")"
	cwd="${cwd/#\~/$HOME}"
	# Default true: every existing caller (the original Wednesday-tab-only
	# envelope) configures the full isolation envelope and never sets this
	# field, so an absent `restricted` must keep behaving exactly as before.
	# A step whose launch instead wants his own default permissions (a run's
	# own follow-up tab, design.md's own later "Runner decisions" call on the
	# Wednesday tab too) sets `"restricted": false` and gets none of the
	# isolation/restriction flags below — `claude` then reads his own
	# settings, same as any session he opens by hand.
	restricted="$(jq -r 'if .restricted == null then true else .restricted end' <<< "$step_json")"
	permission_mode="$(jq -r '.permission_mode // "default"' <<< "$step_json")"
	tools_csv="$(desk_step_allowed_tools "$step_json")"
	strict_mcp="$(jq -r '.strict_mcp_config // false' <<< "$step_json")"
	mcp_config_rel="$(jq -r '.mcp_config // empty' <<< "$step_json")"
	settings_rel="$(jq -r '.settings // empty' <<< "$step_json")"
	skill_rel="$(jq -r '.skill // empty' <<< "$step_json")"
	prompt_text="$(jq -r '.prompt_text // empty' <<< "$step_json")"
	session_name="$(jq -r '.session_name // empty' <<< "$step_json")"
	scratch_root="$(jq -r '.scratch_dir // empty' <<< "$step_json")"
	notes_diff_file="$(jq -r '.notes_diff_file // empty' <<< "$step_json")"
	notes_diff_since="$(jq -r '.notes_diff_since // empty' <<< "$step_json")"

	if [ -z "$cwd" ] || [ -z "$prompt_text" ]; then
		desk_log - "open_tab step: missing cwd_outside or prompt_text"
		echo "failed"
		return
	fi

	if [ -n "$scratch_root" ]; then
		local fresh_dir
		fresh_dir="$(desk_fresh_scratch_dir "$scratch_root")"
		if [ -n "$fresh_dir" ] && [ -d "$fresh_dir" ]; then
			cwd="$fresh_dir"
			if [ -n "$notes_diff_file" ] && [ -n "$notes_diff_since" ] && [ -n "$repo" ] && [ "${#files[@]}" -gt 0 ]; then
				desk_write_notes_diff "$repo" "$fresh_dir/$notes_diff_file" "$notes_diff_since" "${files[@]}"
			fi
		else
			desk_log - "open_tab: could not create scratch_dir under '$scratch_root' — keeping cwd_outside"
		fi
	fi

	if [ -n "$session_name" ]; then
		local live_id
		live_id="$(session-status.sh 2> /dev/null \
			| jq -r --arg n "$session_name" 'select(.name == $n and .live == true) | .id' 2> /dev/null | head -n 1)"
		if [ -n "$live_id" ]; then
			desk_log - "open_tab: session '$session_name' is already live ($live_id) — skipping"
			echo "ok"
			return
		fi
	fi

	local -a argv=(claude)
	if [ "$restricted" = "true" ]; then
		argv+=(--restricted --permission-mode "$permission_mode")
		[ -n "$tools_csv" ] && argv+=(--tools "$tools_csv")
		[ "$strict_mcp" = "true" ] && argv+=(--strict-mcp-config)
	fi
	# Names the session so the live-check above can actually find it next
	# time — session_name was already read for that check but never handed
	# to `claude` itself, which left the check permanently unable to match.
	[ -n "$session_name" ] && argv+=(-n "$session_name")
	[ -n "$mcp_config_rel" ] && argv+=(--mcp-config "$(desk_workspace_path "$mcp_config_rel")")
	[ -n "$settings_rel" ] && argv+=(--settings "$(desk_workspace_path "$settings_rel")")
	[ -n "$skill_rel" ] && argv+=(--append-system-prompt-file "$(desk_workspace_path "$skill_rel")")
	argv+=("$prompt_text")

	local command="" a
	for a in "${argv[@]}"; do
		command="${command:+$command }$(desk_shq "$a")"
	done
	# A non-restricted tab (the Wednesday weekly's own "his default
	# permissions" envelope) loads his real settings and hooks exactly like
	# any session he opens by hand, so without this its own genuine
	# SessionStart would land untagged (source "startup") — indistinguishable
	# from a session he actually opened himself, and never excluded from a
	# later 16:30 capture. A plain env-var prefix on the assembled command
	# line (never user-controlled content, so never quoted) is the only
	# lever available here: this call never goes through desk_call_model
	# (it opens a brand-new terminal tab, not a background call this
	# process can set its own env on).
	[ "$restricted" != "true" ] && command="DESK_HEADLESS=1 $command"

	local helper="${DESK_OPEN_TAB_BIN:-desk-open-tab.sh}"
	if "$helper" "$command" "" "$cwd" > /dev/null 2>&1; then
		echo "ok"
	else
		desk_log - "open_tab: $helper failed"
		echo "failed"
	fi
}
