#!/usr/bin/env bash
# The notes-repo git operations: commit-and-push (design.md §2 "his text",
# §4, §5 Push) and the ledger/proposal writes (§2 "The ledger", §9(d)/(e),
# and the design's own "Proposal ref layout" note). Every actual git-
# plumbing write goes through nvim/lua/desk/cli.lua — this file only
# orchestrates: which files to commit, what the refused-commit conditions
# are, how to merge a pass's new items with what the ledger already holds,
# and the exact push invocation. Never `git pull`, `git fetch`, `merge`,
# `rebase`, or a `--force`/`-f` push — none of those verbs appear below.
set -u

DESK_NOTES_REMOTE="${DESK_NOTES_REMOTE:-origin}"

# True (exit 0) if $1 is a repo the commit step may write to right now:
# HEAD is the branch "main" (never detached, never another branch) and no
# rebase or merge is mid-flight (design.md §4: "commits only when HEAD is
# main with no rebase or merge in progress").
desk_repo_committable() {
	local repo="$1" head
	head="$(git -C "$repo" symbolic-ref --short -q HEAD 2> /dev/null || true)"
	[ "$head" = "main" ] || return 1
	[ -d "$repo/.git/rebase-merge" ] && return 1
	[ -d "$repo/.git/rebase-apply" ] && return 1
	[ -f "$repo/.git/MERGE_HEAD" ] && return 1
	return 0
}

# Commits his text (index-only, via cli.lua's commit-his-text — never the
# working file) across every configured file, then commits if anything
# changed, then pushes main + refs/desk/ledger. Prints one status word to
# stdout: "ok" (ran, whether or not there was anything new to commit),
# "skipped" (HEAD isn't main / mid-rebase — reported, never attempted), or
# "error" (cli.lua itself failed — a loud failure, design.md §5). Sets
# status.json's `push` field to "ok"/"failed"/"disabled" (config's own
# `push_enabled`, default false: commit every day, never push) regardless
# of which of those three it prints, since a push can still be retried
# even after a skipped commit (an earlier pass's commit might still be
# sitting there unpushed).
#
# $1 = repo, $2 = push_enabled ("true"/"false"), $3.. = files (notes.md
# reading.md, per config's `files`).
desk_step_commit_push() {
	local repo="$1" push_enabled="${2:-false}"
	shift 2
	local files=("$@")

	if ! desk_repo_committable "$repo"; then
		local reason="HEAD is not main"
		{ [ -d "$repo/.git/rebase-merge" ] || [ -d "$repo/.git/rebase-apply" ]; } && reason="a rebase is in progress"
		[ -f "$repo/.git/MERGE_HEAD" ] && reason="a merge is in progress"
		desk_log commit_push "skipped: $reason"
		echo "skipped"
		return 0
	fi

	local err_file
	err_file="$(mktemp)"
	local cli_out
	cli_out="$(desk_nvim_cli commit-his-text "$repo" "${files[@]}" 2> "$err_file")"
	if [ -z "$cli_out" ] || ! jq -e . > /dev/null 2>&1 <<< "$cli_out"; then
		desk_log commit_push "commit-his-text failed: $(cat "$err_file" 2> /dev/null)"
		rm -f "$err_file"
		echo "error"
		return 1
	fi
	if jq -e 'any(.[]; has("error"))' > /dev/null 2>&1 <<< "$cli_out"; then
		desk_log commit_push "commit-his-text reported an error: $cli_out"
		rm -f "$err_file"
		echo "error"
		return 1
	fi

	local any_changed
	any_changed="$(jq -e 'any(.[]; .changed == true)' <<< "$cli_out" 2> /dev/null || echo false)"
	if [ "$any_changed" = "true" ]; then
		# No pathspec here, deliberately: `git commit <pathspec>` re-stages
		# those paths FROM THE WORKTREE first (the same as `git add`), which
		# would silently undo the index-only revert commit-his-text just
		# did. Committing bare takes the index exactly as it stands.
		if ! git -C "$repo" commit -q -m "notes" > "$err_file" 2>&1; then
			desk_log commit_push "git commit failed: $(cat "$err_file")"
			rm -f "$err_file"
			echo "error"
			return 1
		fi
	fi
	rm -f "$err_file"

	desk_push_notes "$repo" "$push_enabled"
	echo "ok"
	return 0
}

# The one push desk-run ever makes for the notes repo: a pinned refspec
# (main, plus refs/desk/ledger when it exists locally), BatchMode +
# ConnectTimeout, never a pull/fetch/merge/rebase beforehand and never
# --force. A single attempt — a rejected push is recorded (status.json's
# `push` field) and left for the next pass, never retried in a loop here.
#
# $2 = push_enabled ("true"/"false", default false — config's own
# `push_enabled`): commits happen every day regardless, but a push is an
# outward-facing, harder-to-undo action than a local commit, so it only
# ever runs when explicitly turned on. Recorded as "disabled" rather than
# silently skipped, so status.json still says why nothing moved.
desk_push_notes() {
	local repo="$1" push_enabled="${2:-false}"
	if [ "$push_enabled" != "true" ]; then
		desk_status_set_string_field push "disabled"
		return 0
	fi

	# refs/desk/ledger may not exist yet (a brand-new repo, or one that's
	# never had a judge/close step stage anything) — a refspec naming a
	# ref that doesn't exist locally fails the ENTIRE push, main included,
	# so it's only ever added when it's actually there to push.
	local refspecs=(refs/heads/main:refs/heads/main)
	if git -C "$repo" show-ref --verify --quiet refs/desk/ledger; then
		refspecs+=(refs/desk/ledger:refs/desk/ledger)
	fi

	local push_err
	if push_err="$(GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10" \
		git -C "$repo" push "$DESK_NOTES_REMOTE" "${refspecs[@]}" 2>&1)"; then
		desk_status_set_string_field push "ok"
	else
		desk_log commit_push "push failed (recorded, not retried this run): $push_err"
		desk_status_set_string_field push "failed"
	fi
}

# ---------------------------------------------------------------------------
# Ledger / proposal staging (design.md §2 "The ledger", §9(d)/(e), and the
# "Proposal ref layout" note: parent-chained refs/desk/proposal commits,
# ledger writes via one CAS helper, postponed items re-added unless
# superseded by (target, kind)).
# ---------------------------------------------------------------------------

# jq helper: deep-comparable canonical form (sorted object keys), so two
# anchors/targets built with the same content in a different key order still
# compare equal.
_DESK_JQ_CANON='def canon:
	if type == "object" then to_entries | sort_by(.key) | map({(.key): (.value | canon)}) | (add // {})
	elif type == "array" then map(canon)
	else . end;'

# jq helper: matches($n; $e) — whether a candidate proposal-shaped item $n
# (`.target`/`.kind`/`.source`/`.supersedes`) refers to the SAME suggestion
# as an existing ledger-shaped item $e (`.anchor`/`.kind`/`.id`/`.source`).
# design.md's own "Review rounds" section: "Supersede only when a new item
# names it (`supersedes: <id>`) or shares its `source` URL; (target, kind)
# supersedes only where the target isn't `top`" — top is where every news
# item lands, so two unrelated news items sharing kind "new" and target
# "top" must never read as the same suggestion. One predicate, used both
# directions below: a new item matching a POSTPONED one supersedes it
# (dropped from what's carried forward); a new item matching a PENDING one
# is itself dropped (he already has this suggestion in front of him,
# unresolved — never proposed a second time).
_DESK_JQ_MATCHES='def matches($n; $e):
	(($n.supersedes // null) != null and $n.supersedes == $e.id)
	or ((($n.source // "") != "") and ($n.source == $e.source))
	or (
		(($n.target | canon) == ($e.anchor | canon)) and ($n.kind == $e.kind)
		and (($e.anchor | canon) != ("top" | canon))
	);'

# Converts one ledger `item` record to the pinned proposal-item shape
# (design.md §9(e)): `anchor` -> `target`, drop bookkeeping-only fields.
_DESK_JQ_LEDGER_TO_PROPOSAL='{id, file, kind, target: .anchor, before, after, source, headline}
	+ (if .tier then {tier: .tier} else {} end)'

# Converts one new proposal-shaped item (from a judge call, `target`) into a
# ledger `item` record (`anchor`) with pass/proposed_at bookkeeping added.
_DESK_JQ_PROPOSAL_TO_LEDGER='. as $it
	| {type: "item", id: $it.id, file: $it.file, kind: $it.kind, anchor: $it.target,
	   before: $it.before, after: $it.after, source: $it.source, headline: $it.headline,
	   pass: $pass, proposed_at: $now}
	+ (if $it.tier then {tier: $it.tier} else {} end)
	+ (if $it.session_id then {session_id: $it.session_id} else {} end)
	+ (if $it.capture_kind then {capture_kind: $it.capture_kind} else {} end)'

# Merges `new_items` (a JSON array, the pinned proposal shape, already
# validated by the pass-specific step — D8b's job) into the standing
# proposal: drops any new item matching a currently-PENDING one
# (_DESK_JQ_MATCHES — he already has it, unresolved, in his buffer), then
# appends what's left to the ledger, re-adds every postponed item (laid in,
# then "not now"'d) unless a new item matches it too (same predicate —
# design's "supersedes"), and carries forward every still-queued item
# (never laid in at all). A pending item itself is never carried forward —
# it's already in his buffer; this function only ever reads it to dedup
# against. Writes the merged set as the new refs/desk/proposal tip. Prints
# the new proposal commit sha, or nothing (and a non-zero exit) on failure.
#
# $1 repo, $2 pass, $3 scheduled_date (the guard's own key — cli.lua's
# `namespace-ids` verb namespaces every new item's id against exactly
# this, same as the guard/status keys everything else this pass writes),
# $4 new-items-file (the pinned shape, {"items":[...]} or a bare array —
# either is accepted), $5.. the configured files (notes.md reading.md) —
# postponed-vs-declined needs each one's own derived state
# (desk.ledger.derive_all via cli.lua's ledger-derive), never approximated
# a second way here.
desk_stage_and_write_proposal() {
	local repo="$1" pass="$2" scheduled_date="$3" new_items_file="$4"
	shift 4
	local files=("$@")
	local now
	now="$(desk_now)"

	local state
	state="$(desk_nvim_cli ledger-state "$repo")" || return 1

	local queued_json
	queued_json="$(jq -c --argjson state "$state" \
		'$state.items | to_entries | map(select(.key as $id | ($state.laid_in | index($id)) | not)) | map(.value)' \
		<<< '{}')"

	# desk.ledger.derive_all resolves every ledger item's anchor against
	# whichever one file's content it's handed — including items that
	# belong to the *other* configured file, whose anchor then simply fails
	# to resolve there (harmlessly landing on "pending", never mis-firing as
	# accepted/declined). Filtering each pass's result to items whose own
	# `.file` matches `$f` is what keeps that cross-file noise out of the
	# postponed/pending sets gathered here. Pending items are fetched too —
	# never to carry them forward into the proposal (he already has them,
	# unstaged, in his buffer; re-adding one would duplicate it) — only so a
	# new item matching one (_DESK_JQ_MATCHES) can be dropped before it's
	# ever proposed, in the dedup filter below.
	local postponed_items_json="[]" pending_items_json="[]"
	local f
	for f in "${files[@]}"; do
		local derived
		derived="$(desk_nvim_cli ledger-derive "$repo" "$f")" || return 1
		local file_postponed file_pending
		file_postponed="$(jq -c --arg f "$f" '.states as $s | .items | to_entries
			| map(select(.value.file == $f and $s[.key] == "postponed")) | map(.value)' <<< "$derived")"
		file_pending="$(jq -c --arg f "$f" '.states as $s | .items | to_entries
			| map(select(.value.file == $f and $s[.key] == "pending")) | map(.value)' <<< "$derived")"
		postponed_items_json="$(jq -c -n --argjson a "$postponed_items_json" --argjson b "$file_postponed" '$a + $b')"
		pending_items_json="$(jq -c -n --argjson a "$pending_items_json" --argjson b "$file_pending" '$a + $b')"
	done

	local new_items
	new_items="$(jq -c 'if type == "object" and has("items") then .items else . end' "$new_items_file")"

	# Namespaces every new item's own (model-assigned) id into one unique
	# across the whole ledger BEFORE anything below ever appends a ledger
	# record or writes a proposal — a model's own promise of id uniqueness
	# only ever holds within its own single reply; two different passes
	# (a morning J and a 16:30 close the same day), or two retry slots of
	# the same pass, can otherwise trivially collide on the same literal
	# id and silently overwrite one another in the ledger.
	local namespace_in namespace_out
	namespace_in="$(mktemp)"
	jq -n --argjson items "$new_items" '{items: $items}' > "$namespace_in"
	namespace_out="$(desk_nvim_cli namespace-ids "$repo" "$pass" "$scheduled_date" "$namespace_in")"
	rm -f "$namespace_in"
	jq -e . > /dev/null 2>&1 <<< "$namespace_out" || return 1
	new_items="$(jq -c '.items' <<< "$namespace_out")"

	# Dedup direction first: a new item matching a currently-PENDING one
	# (_DESK_JQ_MATCHES) is dropped outright — he already has this
	# suggestion sitting unresolved in his buffer, never re-proposed a
	# second time (design.md: "don't re-propose pending items — the runner
	# only excludes them from dedup"). Built by concatenating plain
	# (single-quoted) jq source fragments rather than interpolating them
	# inside a double-quoted string, so a jq `$var` reference is never
	# mistaken for a bash one — the bug this whole function tripped on
	# during its own testing.
	local dedup_filter
	dedup_filter="$_DESK_JQ_CANON$_DESK_JQ_MATCHES"'
		($pending) as $pending_items
		| [ .[] | select(. as $n | [$pending_items[] | select(matches($n; .))] | length == 0) ]'
	new_items="$(jq -c --argjson pending "$pending_items_json" "$dedup_filter" <<< "$new_items")"

	# Supersede direction: a POSTPONED item a new item matches
	# (_DESK_JQ_MATCHES — an explicit `supersedes`, a shared `source`, or a
	# same (target, kind) whose target isn't "top") is dropped; the rest
	# are carried forward.
	local supersede_filter
	supersede_filter="$_DESK_JQ_CANON$_DESK_JQ_MATCHES"'
		($new) as $new_items
		| [ .[] | select(. as $e | [$new_items[] | select(matches(.; $e))] | length == 0) ]'
	local surviving_postponed
	surviving_postponed="$(jq -c --argjson new "$new_items" "$supersede_filter" <<< "$postponed_items_json")"

	# The merged proposal: this pass's new items, on top of surviving
	# postponed ones, on top of still-queued ones — new items first so a
	# fresh version of something also queued/postponed reads as the
	# current one (design's "the newer replacing older suggestions").
	local merged_ledger_shaped
	merged_ledger_shaped="$(jq -c --argjson q "$queued_json" \
		'. + $q' <<< "$surviving_postponed")"

	local new_ledger_records
	new_ledger_records="$(jq -c --arg pass "$pass" --argjson now "$now" \
		"map($_DESK_JQ_PROPOSAL_TO_LEDGER)" <<< "$new_items")"

	if [ "$(jq 'length' <<< "$new_ledger_records")" -gt 0 ]; then
		local ndjson_file
		ndjson_file="$(mktemp)"
		jq -c '.[]' <<< "$new_ledger_records" > "$ndjson_file"
		if ! desk_nvim_cli ledger-append-batch "$repo" "$ndjson_file" > /dev/null; then
			rm -f "$ndjson_file"
			return 1
		fi
		rm -f "$ndjson_file"
	fi

	local proposal_items
	proposal_items="$(jq -c --argjson new "$new_items" --argjson old "$merged_ledger_shaped" \
		"(\$new) + (\$old | map($_DESK_JQ_LEDGER_TO_PROPOSAL))" <<< '{}')"

	local proposal_file
	proposal_file="$(mktemp)"
	jq -n --argjson items "$proposal_items" '{items: $items}' > "$proposal_file"
	local out
	out="$(desk_nvim_cli proposal-write "$repo" "$proposal_file")"
	rm -f "$proposal_file"
	jq -e '.sha' > /dev/null 2>&1 <<< "$out" || return 1
	jq -r '.sha' <<< "$out"
}
