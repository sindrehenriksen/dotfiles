-- His text (design.md §2): the working file with each *pending* item's
-- `after` put back to its `before`, skipping any `after` already in the
-- index (already staged — an accept, whether by the key or by accident).
-- One implementation, called the same way from the review key, his commit
-- key, and the runner via `nvim -l` (that last caller never touches this
-- module's index-write path against the working file — it writes only the
-- index, per design.md §2).
local block = require("desk.block")
local git = require("desk.git")
local snippet = require("desk.snippet")

local M = {}

--- Computes his text: `worktree_lines` with each of `pending_items`
--- reverted to its `before`, unless the item's `after` already sits at its
--- anchor in `index_lines` (already accepted). Anchors are resolved
--- against `head_lines` (occurrence-aware — desk.block re-resolves each
--- fresh, so drift from edits elsewhere doesn't go stale) — his last
--- commit, the one reference no pending item's own content can ever be
--- baked into, unlike `index_lines`: an item accepted by something outside
--- the normal flow (a `git add -A`) grows the index at exactly its own
--- anchor, which would otherwise shift the anchor's resolved position past
--- the very content being checked (the same trap desk.ledger's `derive_all`
--- avoids the same way). `head_lines` defaults to `index_lines` when
--- omitted, which is fine whenever nothing has been accepted by anything
--- but the normal flow — the ordinary case — but a caller that already has
--- HEAD's content on hand (the runner always does) should pass it.
---
--- A `move`/`merge` item has two locations — the leaving anchor
--- (`before`-shaped: reverting re-inserts it) and the landing one
--- (`after`-shaped: reverting removes it, nothing replaces it there) — so
--- it becomes two events; a `remove` is one `before`-shaped event (its
--- `after` is always empty, which would otherwise vacuously "match"
--- anywhere); everything else (`add`/`edit`/`new`/`link`) is one
--- `after`-shaped event.
---
--- No running offset is needed across events, despite several sharing one
--- file: a successful revert — in every shape — brings `lines` back to
--- exactly matching `index_lines` at that location (a removed insertion
--- leaves nothing where `index_lines` also has nothing; a restored
--- `before` matches what `index_lines` still holds there), so it
--- contributes zero divergence to anything positioned after it. The two
--- non-revert outcomes are the same: "skipped_in_index" means the index
--- already grew (or shrank) exactly as the worktree did, so nothing
--- diverges either; "waiting_edit" is unknowable and treated as zero, the
--- least-wrong default. So every event resolves its position directly
--- against `index_lines`, independent of what any other event did.
---
--- Returns the new lines, and per item id one of:
---   "reverted"        — its `after` was found in the worktree and undone
---                        (both locations, for move/merge).
---   "skipped_in_index" — its `after` is already in the index; left alone.
---   "waiting_edit"    — its anchor resolved, but the expected content
---                        wasn't there cleanly (design.md §2: "an edit of
---                        his that waits on the suggestion beside it"), or
---                        (move/merge) its two locations disagree.
function M.compute(worktree_lines, index_lines, pending_items, head_lines)
	head_lines = head_lines or index_lines
	-- "land"/"single" (after-shaped) events fall back to the top of the
	-- file when their anchor can't be resolved at all, same as
	-- desk.apply's initial lay-in and desk.ledger's own re-derivation
	-- (desk.block.find_after_anchor) — otherwise a bad-anchor item that
	-- landed on top would never get reverted here (its anchor still can't
	-- resolve), leaving its suggested `after` silently baked into his
	-- committed text the moment he next commits, never having been
	-- accepted. "leave"/"removal" (before-shaped) events keep the plain
	-- nil on purpose: their absence is a real content conflict
	-- ("waiting_edit"), not a landing case.
	local events = {}
	for _, item in ipairs(pending_items) do
		local leave_anchor, land_anchor = block.parse_target(item.anchor)
		if item.kind == "move" or item.kind == "merge" then
			events[#events + 1] =
				{ item = item, role = "leave", index_pos = leave_anchor and block.find_anchor(head_lines, leave_anchor) }
			events[#events + 1] =
				{ item = item, role = "land", index_pos = block.find_after_anchor(head_lines, land_anchor) }
		elseif item.kind == "remove" then
			events[#events + 1] =
				{ item = item, role = "removal", index_pos = leave_anchor and block.find_anchor(head_lines, leave_anchor) }
		else
			events[#events + 1] =
				{ item = item, role = "single", index_pos = block.find_after_anchor(head_lines, land_anchor) }
		end
	end
	-- Order still matters even with no explicit offset: an earlier
	-- (smaller-position) event's revert has to land in `lines` before a
	-- later one is looked up, so that by the time we reach it, everything
	-- before its position already matches `index_lines` exactly.
	table.sort(events, function(a, b)
		return (a.index_pos or math.huge) < (b.index_pos or math.huge)
	end)

	local lines = vim.deepcopy(worktree_lines)
	local partial = {}

	for _, e in ipairs(events) do
		local item, index_pos, role = e.item, e.index_pos, e.role
		local before_lines = snippet.split_lines(item.before)
		local after_lines = snippet.split_lines(item.after)
		partial[item.id] = partial[item.id] or {}

		if index_pos == nil then
			partial[item.id][role] = "waiting_edit"
		elseif role == "leave" or role == "removal" then
			-- `before`-shaped: reverting re-inserts it. Nothing to remove —
			-- the suggestion already took it out of the worktree.
			if not snippet.lines_match_at(index_lines, index_pos + 1, before_lines) then
				partial[item.id][role] = "skipped_in_index" -- already accepted here
			elseif snippet.lines_match_at(lines, index_pos + 1, before_lines) then
				-- `before` is already sitting there — the suggestion hasn't
				-- actually been laid in at this spot, or was already
				-- undone; reverting again would duplicate it.
				partial[item.id][role] = "waiting_edit"
			else
				for i = #before_lines, 1, -1 do
					table.insert(lines, index_pos + 1, before_lines[i])
				end
				partial[item.id][role] = "reverted"
			end
		else
			-- "single" (add/edit/new/link) or a move/merge's "land":
			-- `after`-shaped. A "land" position removes `after` with
			-- nothing replacing it; a "single" one replaces it with
			-- `before` (empty for add/new/link).
			if snippet.lines_match_at(index_lines, index_pos + 1, after_lines) then
				partial[item.id][role] = "skipped_in_index"
			elseif snippet.lines_match_at(lines, index_pos + 1, after_lines) then
				for _ = 1, #after_lines do
					table.remove(lines, index_pos + 1)
				end
				local replacement = (role == "single") and before_lines or {}
				for i = #replacement, 1, -1 do
					table.insert(lines, index_pos + 1, replacement[i])
				end
				partial[item.id][role] = "reverted"
			else
				partial[item.id][role] = "waiting_edit"
			end
		end
	end

	local results = {}
	for id, p in pairs(partial) do
		if p.single then
			results[id] = p.single
		elseif p.removal then
			results[id] = p.removal
		elseif p.leave == p.land then
			results[id] = p.leave
		else
			results[id] = "waiting_edit" -- move/merge's two sides disagree
		end
	end

	return lines, results
end

--- Computes his text and writes it to the git index for `path`, without
--- ever touching the working file. `get_state()` is called once per
--- attempt and must return { worktree_lines, index_lines, pending_items,
--- head_lines } freshly read (`head_lines` may be omitted; see compute())
--- — this module doesn't know how pending items are derived (that's
--- desk.ledger's job), only how to revert and write them.
---
--- Retries if the index changes between the read and the write (design.md
--- §2: "writes the index only if it is unchanged since its read... else
--- recomputes"). The residual race this doesn't close — a write landing in
--- the narrow gap between the last fingerprint check and update-index
--- itself — is what design.md's "or holds index.lock across both" would
--- close fully; this implementation takes the retry-on-drift half only.
---
--- Returns the new blob sha and per-item results on success, or nil, nil,
--- an error message after exhausting `max_attempts`.
function M.write_to_index(repo_dir, path, get_state, max_attempts)
	max_attempts = max_attempts or 5
	for _ = 1, max_attempts do
		local fp_before = git.index_fingerprint(repo_dir)
		local state = get_state()
		local new_lines, results =
			M.compute(state.worktree_lines, state.index_lines, state.pending_items, state.head_lines)
		local new_content = snippet.join_lines(new_lines, true)
		local fp_after_read = git.index_fingerprint(repo_dir)

		if fp_before == fp_after_read then
			local sha = git.hash_object_write(repo_dir, new_content)
			if sha and git.index_fingerprint(repo_dir) == fp_before then
				local entry = git.index_entry(repo_dir, path) or { mode = "100644" }
				if git.update_index_cacheinfo(repo_dir, entry.mode, sha, path) then
					return sha, results
				end
			end
		end
		-- else: the index moved while we were reading/computing; loop and
		-- let get_state() hand back fresh state next attempt.
	end
	return nil, nil, string.format("index kept changing; gave up after %d attempts", max_attempts)
end

return M
