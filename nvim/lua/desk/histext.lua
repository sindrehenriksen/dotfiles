-- His text (design.md §2, updated by the "Review rounds" section): the
-- working file with each *pending* item's suggested content dropped and,
-- for a gap-shaped item (a removal, or a move/merge's leaving side), its
-- `before` put back — at its own round-mapped range (desk.round /
-- desk.ledger.derive_all's own `ranges` output), never by re-resolving an
-- anchor against a stale reference: that's exactly the positional approach
-- design.md's "Review rounds" section replaced. One implementation, called
-- the same way from the review key, his commit key, and the runner via
-- `nvim -l` (that last caller never touches this module's index-write path
-- against the working file — it writes only the index, per design.md §2).
local git = require("desk.git")
local snippet = require("desk.snippet")

local M = {}

--- Computes his text: `worktree_lines` with each of `pending_items`
--- reverted, at its own `pending_ranges[item.id]` (worktree-relative,
--- 1-indexed `{line, count, role}` — desk.ledger.derive_all's own
--- "pending" output, already content-diff-mapped against the round, so his
--- edits elsewhere never throw off where this lands). No index/head
--- content is read here at all: a pending item, by definition, hasn't
--- reached the index yet (desk.ledger.derive_all already excludes anything
--- accepted), so there is nothing left to check it against — only to
--- revert.
---
--- A `move`/`merge` item has two ranges — the leaving one (gap-shaped:
--- reverting re-inserts `before`) and the landing one (content-shaped:
--- reverting removes it, nothing replaces it there) — everything else
--- (`add`/`edit`/`new`/`link`) has one content-shaped range, and `remove`
--- has one gap-shaped one. An item whose `pending_ranges` entry doesn't
--- have exactly the number of ranges its kind implies (one, or two for
--- move/merge) is left untouched and reported "waiting_edit" (design.md
--- §2: "an edit of his that waits on the suggestion beside it") — the same
--- signal a move/merge's two sides disagreeing on state already produces
--- one level up, in desk.ledger.derive_all.
---
--- Returns the new lines, and per item id one of:
---   "reverted"     — its content was found at its own range and undone
---                     (both ranges, for move/merge).
---   "waiting_edit" — its `pending_ranges` entry is missing or incomplete.
function M.compute(worktree_lines, pending_items, pending_ranges)
	local edits = {}
	local results = {}

	for _, item in ipairs(pending_items) do
		local rs = pending_ranges[item.id]
		local expected_n = (item.kind == "move" or item.kind == "merge") and 2 or 1
		if not rs or #rs ~= expected_n then
			results[item.id] = "waiting_edit"
		else
			local before_lines = snippet.split_lines(item.before)
			for _, r in ipairs(rs) do
				if r.count == 0 then
					-- Gap-shaped (leave/removal): reverting re-inserts `before`.
					edits[#edits + 1] = { pos = r.line - 1, remove = 0, insert = before_lines }
				else
					-- Content-shaped ("edit": replace with `before`, empty
					-- for a pure insertion; "land": replace with nothing —
					-- a move/merge's landing side never had a `before` of
					-- its own there).
					local replacement = (r.role == "edit") and before_lines or {}
					edits[#edits + 1] = { pos = r.line - 1, remove = r.count, insert = replacement }
				end
			end
			results[item.id] = "reverted"
		end
	end

	-- Bottom-of-file-up, same reasoning as desk.apply.apply_file: an
	-- earlier (smaller-position) edit's own position survives untouched
	-- past every edit applied after it, since those all sit below it.
	table.sort(edits, function(a, b)
		return a.pos > b.pos
	end)

	local lines = vim.deepcopy(worktree_lines)
	for _, e in ipairs(edits) do
		for _ = 1, e.remove do
			table.remove(lines, e.pos + 1)
		end
		for i = #e.insert, 1, -1 do
			table.insert(lines, e.pos + 1, e.insert[i])
		end
	end

	return lines, results
end

--- Writes `path`'s index entry to whatever `compute_content(state)`
--- returns (a file content string, plus any second value the caller wants
--- back on success), retrying if the index changes between the read and
--- the write (design.md §2: "writes the index only if it is unchanged
--- since its read... else recomputes"). `get_state()` is called once per
--- attempt and must return fresh state each time — this function doesn't
--- know or care what shape it is, only `compute_content` does. Shared by
--- `write_to_index` below (his-text) and desk.review.accept (staging a
--- single accepted item) — design.md's own instruction that accept's index
--- write use the same guard this one already had.
---
--- The residual race this doesn't close — a write landing in the narrow
--- gap between the last fingerprint check and update-index itself — is
--- what design.md's "or holds index.lock across both" would close fully;
--- this implementation takes the retry-on-drift half only.
---
--- Returns the new blob sha and `compute_content`'s second value on
--- success, or nil, nil, an error message after exhausting `max_attempts`.
function M.write_index_guarded(repo_dir, path, get_state, compute_content, max_attempts)
	max_attempts = max_attempts or 5
	for _ = 1, max_attempts do
		local fp_before = git.index_fingerprint(repo_dir)
		local state = get_state()
		local new_content, extra = compute_content(state)
		local fp_after_read = git.index_fingerprint(repo_dir)

		if fp_before == fp_after_read then
			local sha = git.hash_object_write(repo_dir, new_content)
			if sha and git.index_fingerprint(repo_dir) == fp_before then
				local entry = git.index_entry(repo_dir, path) or { mode = "100644" }
				if git.update_index_cacheinfo(repo_dir, entry.mode, sha, path) then
					return sha, extra
				end
			end
		end
		-- else: the index moved while we were reading/computing; loop and
		-- let get_state() hand back fresh state next attempt.
	end
	return nil, nil, string.format("index kept changing; gave up after %d attempts", max_attempts)
end

--- Computes his text and writes it to the git index for `path`, without
--- ever touching the working file. `get_state()` must return
--- { worktree_lines, pending_items, pending_ranges } freshly read each
--- attempt (see compute()) — this module doesn't know how pending items or
--- their ranges are derived (that's desk.ledger's job, via desk.round),
--- only how to revert and write them.
---
--- Returns the new blob sha and per-item results on success, or nil, nil,
--- an error message after exhausting `max_attempts`.
function M.write_to_index(repo_dir, path, get_state, max_attempts)
	return M.write_index_guarded(repo_dir, path, get_state, function(state)
		local new_lines, results = M.compute(state.worktree_lines, state.pending_items, state.pending_ranges)
		return snippet.join_lines(new_lines, true), results
	end, max_attempts)
end

return M
