#!/usr/bin/env bash
# The commit_push step: the daily commit of the user's files exactly as they
# are on disk, and the push. Never `git pull`, `git fetch`, `merge`,
# `rebase`, or a `--force`/`-f` push: none of those verbs appear below.
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

# Commits the user's on-disk files exactly as they are (only the configured
# files, only if something changed), records any suggestion now in the user's HEAD
# as taken, then pushes main and the ledger. Prints one status word to
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
	# leaves anything else the user has staged alone.
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
# (main, plus the ledger wrapped in a commit when there is one), BatchMode +
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

	local refspecs=(refs/heads/main:refs/heads/main) wrapped
	if wrapped="$(desk_ledger_wrap "$repo")"; then
		refspecs+=("$wrapped:refs/desk/ledger")
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

# desk_ledger_wrap <repo>: the commit the ledger is pushed as. The ledger
# ref is a bare blob, which GitHub refuses to store, so each push sends a
# commit whose tree holds it as ledger.jsonl, parented on the last one sent
# (refs/desk/ledger-pushed) so every push fast-forwards. Prints nothing and
# fails when there is no ledger yet, since a refspec naming a missing ref
# fails the whole push, main included.
desk_ledger_wrap() {
	local repo="$1" blob prev tree commit
	blob="$(git -C "$repo" rev-parse -q --verify 'refs/desk/ledger^{blob}' 2> /dev/null)" || return 1
	prev="$(git -C "$repo" rev-parse -q --verify 'refs/desk/ledger-pushed^{commit}' 2> /dev/null)"
	if [ -n "$prev" ] && [ "$(git -C "$repo" rev-parse -q --verify "$prev:ledger.jsonl" 2> /dev/null)" = "$blob" ]; then
		printf '%s' "$prev"
		return 0
	fi
	tree="$(printf '100644 blob %s\tledger.jsonl\n' "$blob" | git -C "$repo" mktree)" || return 1
	commit="$(git -C "$repo" commit-tree "$tree" ${prev:+-p "$prev"} -m ledger)" || return 1
	git -C "$repo" update-ref refs/desk/ledger-pushed "$commit" ${prev:+"$prev"} || return 1
	printf '%s' "$commit"
}
