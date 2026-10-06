#!/usr/bin/env bash
# The notes-repo git operations: the daily commit-and-push of his on-disk
# files exactly as they are, and the one proposal commit per pass. Every
# ledger/proposal write goes through nvim/lua/desk/cli.lua — this file only
# orchestrates: which files to commit, what the refused-commit conditions
# are, how a pass's new items reach the proposal builder, and the exact
# push invocation. Never `git pull`, `git fetch`, `merge`, `rebase`, or a
# `--force`/`-f` push — none of those verbs appear below.
set -u

DESK_NOTES_REMOTE="${DESK_NOTES_REMOTE:-origin}"

# True (exit 0) if $1 is a repo the commit step may write to right now:
# HEAD is the branch "main" (never detached, never another branch) and no
# rebase or merge is mid-flight.
desk_repo_committable() {
	local repo="$1" head
	head="$(git -C "$repo" symbolic-ref --short -q HEAD 2> /dev/null || true)"
	[ "$head" = "main" ] || return 1
	[ -d "$repo/.git/rebase-merge" ] && return 1
	[ -d "$repo/.git/rebase-apply" ] && return 1
	[ -f "$repo/.git/MERGE_HEAD" ] && return 1
	return 0
}

# Commits his on-disk files exactly as they are (only the configured
# files, only if something changed), records any suggestion now in his HEAD
# as taken, then pushes main + refs/desk/ledger. Prints one status word to
# stdout: "ok" (ran, whether or not there was anything new to commit),
# "skipped" (HEAD isn't main / mid-rebase — reported, never attempted), or
# "error" (the commit or the taken-sync failed — a loud failure). The push
# comes last and only on the "ok" path: it sets status.json's `push` field to
# "ok"/"failed" (or "disabled" when config's `push_enabled`, default false,
# is off: commit every day, never push). A "skipped" or "error" run never
# reaches it, so it neither pushes nor touches the `push` field, which keeps
# its previous value.
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
	# `git commit -- <paths>` commits those paths' on-disk content and
	# leaves anything else he has staged alone.
	local existing=() f
	for f in "${files[@]}"; do
		[ -e "$repo/$f" ] && existing+=("$f")
	done
	if [ "${#existing[@]}" -gt 0 ] && [ -n "$(git -C "$repo" status --porcelain -- "${existing[@]}" 2> /dev/null)" ]; then
		if ! { git -C "$repo" add -- "${existing[@]}" \
			&& git -C "$repo" commit -q -m "notes" -- "${existing[@]}"; } > "$err_file" 2>&1; then
			desk_log commit_push "git commit failed: $(cat "$err_file")"
			rm -f "$err_file"
			echo "error"
			return 1
		fi
	fi

	local sync_out
	if ! sync_out="$(desk_nvim_cli taken-sync "$repo" 2> "$err_file")" || ! jq -e . > /dev/null 2>&1 <<< "$sync_out"; then
		desk_log commit_push "taken-sync failed: $(cat "$err_file" 2> /dev/null)"
		rm -f "$err_file"
		echo "error"
		return 1
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
# Proposal staging: one proposal commit per pass (nvim/lua/desk/proposal.lua).
# ---------------------------------------------------------------------------

# Builds the proposal commit for this pass and moves refs/desk/proposal to
# it: his newest HEAD, plus the previous proposal's items he has neither
# taken nor declined (an untaken one returning is "not now"), plus this
# pass's new items — all applied to the configured files. Id namespacing,
# dropping what he declined (by id or source URL), and superseding a carried
# item a new one replaces all happen inside the builder. Prints the new
# proposal commit sha, or nothing (and a non-zero exit) on failure.
#
# $1 repo, $2 pass, $3 scheduled_date (the guard's own key — new ids are
# namespaced against it), $4 new-items-file ({"items":[...]} or a bare
# array), $5.. the configured files (notes.md reading.md).
desk_stage_and_write_proposal() {
	local repo="$1" pass="$2" scheduled_date="$3" new_items_file="$4"
	shift 4
	local files=("$@")

	local items_file out
	items_file="$(mktemp)"
	jq -c 'if type == "object" and has("items") then {items: .items} else {items: .} end' "$new_items_file" > "$items_file" \
		|| { rm -f "$items_file"; return 1; }
	out="$(desk_nvim_cli proposal-build "$repo" "$pass" "$scheduled_date" "$items_file" "${files[@]}")"
	rm -f "$items_file"
	jq -e '.sha' > /dev/null 2>&1 <<< "$out" || return 1
	jq -r '.sha' <<< "$out"
}
