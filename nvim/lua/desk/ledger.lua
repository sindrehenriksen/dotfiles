-- The ledger (design.md §2 "The ledger", §9(d)): one append-only JSON-lines
-- blob on `refs/desk/ledger` in the notes repo, holding `item`, `laid_in`
-- and `key` records. This module reads it, appends to it through the
-- compare-and-swap-with-retry helper, and derives each item's state from
-- its own snippets in the current index/worktree — never from `key`
-- records, which are kept only as provenance for the "resolved without a
-- key" / "accepted by accident" checks below.
--
-- An item's `anchor` field carries the same pinned wire shape as a
-- proposal's `target` (design.md §9(e) / the morning-J prompt): `"top"` |
-- `{under=...}` | `{after=...}` | `{at=...}`, or — for `merge`/`move` — a
-- two-element list of these. desk.block.parse_target turns it into this
-- module's internal anchor pair.
local block = require("desk.block")
local git = require("desk.git")
local snippet = require("desk.snippet")

local M = {}

M.LEDGER_REF = "refs/desk/ledger"

--- Parses the ledger blob into an ordered list of records (append order is
--- ledger order, which is also chronological).
function M.read(repo_dir)
	local sha = git.ref_sha(repo_dir, M.LEDGER_REF)
	if not sha then
		return {}
	end
	local content = git.cat_file(repo_dir, sha) or ""
	local records = {}
	for line in content:gmatch("[^\n]+") do
		local ok, rec = pcall(vim.json.decode, line)
		if ok and type(rec) == "table" then
			records[#records + 1] = rec
		end
	end
	return records
end

--- Appends every one of `records` (each a plain table; `type` must already
--- be set) to the ledger in a single compare-and-swap-with-retry, so a
--- concurrent writer (a pass, another review key press) never clobbers it —
--- one loses the race and retries against the new tip instead. Batching
--- several records under one CAS (rather than one `append` per record) is
--- what makes a pass's own writes — its new items plus any re-added
--- postponed ones — land atomically: a reader between them would otherwise
--- see a half-written pass.
function M.append_many(repo_dir, records)
	if #records == 0 then
		return git.ref_sha(repo_dir, M.LEDGER_REF) -- nothing to do; report the current tip
	end
	return git.cas_retry(repo_dir, M.LEDGER_REF, function(old_sha)
		local content = git.cat_file(repo_dir, old_sha) or ""
		if content ~= "" and content:sub(-1) ~= "\n" then
			content = content .. "\n"
		end
		for _, record in ipairs(records) do
			content = content .. vim.json.encode(record) .. "\n"
		end
		return git.hash_object_write(repo_dir, content)
	end)
end

--- Appends `record` (a plain table; `type` must already be set) to the
--- ledger via compare-and-swap-with-retry, so a concurrent writer (a pass,
--- another review key press) never clobbers it — one loses the race and
--- retries against the new tip instead.
function M.append(repo_dir, record)
	return M.append_many(repo_dir, { record })
end

--- `records` reduced to id -> item record (type "item" only).
function M.items_by_id(records)
	local out = {}
	for _, rec in ipairs(records) do
		if rec.type == "item" and rec.id then
			out[rec.id] = rec
		end
	end
	return out
end

--- Rewrites each of `items`' own (model-assigned) `id` into a
--- ledger-unique one, `<pass>-<scheduled_date>-<seq>-<model id>`: the
--- model only ever promises its own id is unique *within* one reply, never
--- across passes or days, so used directly as the ledger key, Tuesday's
--- "j1" inherits Monday's already-resolved state, and two same-pass
--- captures that both call themselves "c1" collide with each other. `seq`
--- is assigned in `items`' own order, 1-based, and bumped past anything
--- already in the ledger (or already produced earlier in this same batch)
--- so the result is unique across the whole ledger, not just this call —
--- belt-and-braces for a retried pass reusing the same (pass, date).
--- Returns a new list, same order, everything but `id` untouched. This is
--- the runner's own staging step (via `nvim -l`'s `namespace-ids` verb,
--- desk.cli); wiring the runner to actually call it is separate work —
--- this only has to exist and behave correctly.
function M.namespace_ids(repo_dir, pass, scheduled_date, items)
	local used = {}
	for id in pairs(M.items_by_id(M.read(repo_dir))) do
		used[id] = true
	end
	local out = {}
	local seq = 0
	for _, item in ipairs(items) do
		local new_id
		repeat
			seq = seq + 1
			new_id = string.format("%s-%s-%d-%s", pass, scheduled_date, seq, tostring(item.id))
		until not used[new_id]
		used[new_id] = true
		local copy = vim.deepcopy(item)
		copy.id = new_id
		out[#out + 1] = copy
	end
	return out
end

--- The set of item ids ever named by a `laid_in` record, and the most
--- recent `key` record per id (last one wins — the ledger is append-only,
--- so list order is chronological).
function M.laid_in_and_keys(records)
	local laid_in, last_key = {}, {}
	for _, rec in ipairs(records) do
		if rec.type == "laid_in" then
			for _, id in ipairs(rec.items or {}) do
				laid_in[id] = true
			end
		elseif rec.type == "key" and rec.id then
			last_key[rec.id] = rec
		end
	end
	return laid_in, last_key
end

--- Derives every laid-in item's state ("pending" / "accepted" /
--- "declined") plus every other item's ("queued" / "postponed") in one
--- pass.
---
--- `head_lines` is his last commit (HEAD) for the target file — the one
--- stable reference every anchor is resolved against. It has to be HEAD
--- rather than the current index: an `edit`/`remove`/move-leaving anchor
--- quotes the item's own `before`, which is exactly the text that
--- disappears from the index once *that same item* gets accepted, so
--- resolving it against a possibly-already-mutated index would fail on
--- the one item whose state most needs telling apart from "unresolved".
--- `index_lines` and `worktree_lines` are the current (possibly mutated)
--- content, used only for the presence checks.
---
--- Not-laid-in items need no positional work. Laid-in items are resolved
--- into one or two *location events* — most kinds have a single location,
--- but `move`/`merge` have two (the leaving anchor, `before`-shaped, and
--- the landing anchor, `after`-shaped), each with its own presence check
--- and its own contribution to the running offsets. All events (across
--- every laid-in item) are processed in one position-sorted pass, tracking
--- two running line-count offsets — one for the index, one for the
--- worktree — since they diverge from `head_lines` differently: the
--- worktree carries every laid-in item's content inline, the index only
--- what's been accepted. This is the same reasoning as
--- desk.histext.compute, applied to two locations where a single item
--- needs it, and to every laid-in item at once.
---
--- Returns id -> state, plus the items and last-key tables (so a caller
--- doesn't have to re-read the ledger for those), plus id -> a list of
--- { line, count } worktree ranges (1-indexed; count 0 for a removal or a
--- move's leaving side — a gap, not a line) for every "pending" item only
--- — the ones a review key's whole-item action (accept/decline/not-now)
--- can actually land on. A move/merge's list has two entries.
function M.derive_all(repo_dir, head_lines, index_lines, worktree_lines)
	local records = M.read(repo_dir)
	local items = M.items_by_id(records)
	local laid_in, last_key = M.laid_in_and_keys(records)

	local states = {}
	local laid_in_items = {}
	for id, item in pairs(items) do
		if not laid_in[id] then
			states[id] = "queued" -- never laid in, whatever any key record says
		else
			laid_in_items[#laid_in_items + 1] = item
		end
	end

	-- One event per single-location item; two (leave, land) for move/merge.
	--
	-- "land"/"edit" (after-shaped) events resolve via desk.block's
	-- find_after_anchor, falling back to the top of the file the same way
	-- desk.apply's own initial lay-in does when the anchor can't be
	-- resolved at all — so an item apply.apply_file actually landed on top
	-- (its anchor having gone missing) re-derives its state and range at
	-- that SAME position on every later run, rather than going stuck
	-- "pending" with no range (unreachable by the review keys, virtual
	-- text included) forever after. "leave"/"removal" (before-shaped)
	-- events deliberately keep the plain nil: their absence is a genuine
	-- content conflict, not a landing case — see apply.lua's own
	-- resolve_leave for the same split.
	local events = {}
	for _, item in ipairs(laid_in_items) do
		local leave_anchor, land_anchor = block.parse_target(item.anchor)
		if item.kind == "move" or item.kind == "merge" then
			events[#events + 1] =
				{ item = item, role = "leave", pos = leave_anchor and block.find_anchor(head_lines, leave_anchor) }
			events[#events + 1] = { item = item, role = "land", pos = block.find_after_anchor(head_lines, land_anchor) }
		elseif item.kind == "remove" then
			events[#events + 1] =
				{ item = item, role = "removal", pos = leave_anchor and block.find_anchor(head_lines, leave_anchor) }
		else
			events[#events + 1] = { item = item, role = "edit", pos = block.find_after_anchor(head_lines, land_anchor) }
		end
	end
	table.sort(events, function(a, b)
		return (a.pos or math.huge) < (b.pos or math.huge)
	end)

	-- Per-item-id partial results from each of its events, combined once
	-- every event for that id has been seen. `ranges` records where a
	-- still-pending event's content currently sits in the worktree (1-
	-- indexed line, count of lines) — a zero-count entry for a removal or
	-- a move's leaving side, since there's nothing left to select there,
	-- only the gap where gitsigns' deleted-lines display renders it.
	local partial = {}
	local ranges = {}
	local idx_offset, wt_offset = 0, 0

	for _, e in ipairs(events) do
		local item, pos, role = e.item, e.pos, e.role
		partial[item.id] = partial[item.id] or {}
		if pos == nil then
			partial[item.id][role] = "pending" -- can't resolve; conservatively still needs review
		else
			local before_lines = snippet.split_lines(item.before)
			local after_lines = snippet.split_lines(item.after)
			local idx_pos, wt_pos = pos + idx_offset, pos + wt_offset

			if role == "removal" then
				-- Purely `before`-shaped: `after` is empty at this location.
				local before_in_index = snippet.lines_match_at(index_lines, idx_pos + 1, before_lines)
				local before_in_wt = snippet.lines_match_at(worktree_lines, wt_pos + 1, before_lines)
				if before_in_index and not before_in_wt then
					partial[item.id].removal = "pending"
					ranges[item.id] = ranges[item.id] or {}
					table.insert(ranges[item.id], { line = wt_pos + 1, count = 0 })
					wt_offset = wt_offset - #before_lines
				elseif (not before_in_index) and (not before_in_wt) then
					partial[item.id].removal = "accepted"
					idx_offset = idx_offset - #before_lines
					wt_offset = wt_offset - #before_lines
				else
					partial[item.id].removal = "declined" -- reset: content's back, no length change
				end
			elseif role == "leave" then
				-- A move/merge's leaving side: `before`-shaped, same as a
				-- removal, but its own partial slot (combined with "land").
				local before_in_index = snippet.lines_match_at(index_lines, idx_pos + 1, before_lines)
				local before_in_wt = snippet.lines_match_at(worktree_lines, wt_pos + 1, before_lines)
				if before_in_index and not before_in_wt then
					partial[item.id].leave = "pending"
					ranges[item.id] = ranges[item.id] or {}
					table.insert(ranges[item.id], { line = wt_pos + 1, count = 0 })
					wt_offset = wt_offset - #before_lines
				elseif (not before_in_index) and (not before_in_wt) then
					partial[item.id].leave = "accepted"
					idx_offset = idx_offset - #before_lines
					wt_offset = wt_offset - #before_lines
				else
					partial[item.id].leave = "declined"
				end
			else
				-- "edit" (single-location add/edit/new/link) or a move/
				-- merge's "land": `after`-shaped. A "land" position has
				-- nothing of head's at that spot (a pure insertion point),
				-- so only `after` contributes there; an "edit" replaces
				-- `before` in place, so the net change is after-minus-
				-- before (0 for add/new/link, whose `before` is empty).
				local after_in_index = snippet.lines_match_at(index_lines, idx_pos + 1, after_lines)
				local after_in_wt = snippet.lines_match_at(worktree_lines, wt_pos + 1, after_lines)
				local head_len = (role == "edit") and #before_lines or 0
				local state
				if after_in_wt and not after_in_index then
					state = "pending"
					ranges[item.id] = ranges[item.id] or {}
					table.insert(ranges[item.id], { line = wt_pos + 1, count = #after_lines })
					wt_offset = wt_offset + (#after_lines - head_len)
				elseif after_in_wt and after_in_index then
					state = "accepted"
					idx_offset = idx_offset + (#after_lines - head_len)
					wt_offset = wt_offset + (#after_lines - head_len)
				elseif (not after_in_wt) and (not after_in_index) then
					state = "declined" -- reset: no net length change vs. head here
				else
					state = "pending" -- unresolved drift; still needs review
				end
				partial[item.id][role] = state
			end
		end
	end

	-- design.md §2 gives "postponed" no content signature of its own — a
	-- "not now" resets an item's lines exactly like a decline does, so the
	-- two are content-identical and only the key record (kept for exactly
	-- this) tells them apart. A content-derived "declined" is the only
	-- bucket a not_now key can override; pending/accepted never consult it.
	for id, p in pairs(partial) do
		local bucket
		if p.removal then
			bucket = p.removal
		elseif p.leave and p.land then
			bucket = (p.leave == p.land) and p.leave or "pending" -- disagreement: still needs review
		else
			bucket = p.edit
		end
		if bucket == "declined" and last_key[id] and last_key[id].action == "not_now" then
			bucket = "postponed"
		end
		states[id] = bucket
		if bucket ~= "pending" then
			ranges[id] = nil -- only pending items are actionable; drop stale/disagreeing ranges
		end
	end

	return states, items, last_key, ranges
end

--- Given the ids that were "pending" at the last run (the pending-set
--- snapshot, §9(g)) and the freshly derived states + last-key records now,
--- returns two id lists: items that ended up accepted (in the index) with
--- no `accept` key record ("accepted by accident" — a `git add -A`), and
--- items that are gone from both index and worktree with no `decline` key
--- record ("resolved without a key").
function M.classify_transitions(prev_pending_ids, states, last_key)
	local accepted_by_accident, resolved_without_key = {}, {}
	for _, id in ipairs(prev_pending_ids) do
		local state = states[id]
		local key = last_key[id]
		if state == "accepted" and not (key and key.action == "accept") then
			table.insert(accepted_by_accident, id)
		elseif state == "declined" and not (key and key.action == "decline") then
			table.insert(resolved_without_key, id)
		end
	end
	return accepted_by_accident, resolved_without_key
end

--- The ledger reduced to what a writer (the runner) needs to decide what's
--- still queued or postponed, without deriving full per-item states (which
--- needs head/index/worktree content the writer may not have to hand for
--- every file at once): `items` (id -> item record), `laid_in` (a plain
--- array of every id a `laid_in` record has ever named), `last_key` (id ->
--- its most recent `key` record).
function M.state_summary(repo_dir)
	local records = M.read(repo_dir)
	local items = M.items_by_id(records)
	local laid_in, last_key = M.laid_in_and_keys(records)
	local laid_in_ids = {}
	for id in pairs(laid_in) do
		laid_in_ids[#laid_in_ids + 1] = id
	end
	table.sort(laid_in_ids)
	return { items = items, laid_in = laid_in_ids, last_key = last_key }
end

--- The base directory desk's own state files live under ($DESK_STATE_DIR
--- — claude/desk-lib/common.sh's own default), overridable the same way
--- every other desk path is.
local function state_dir()
	local override = vim.env.DESK_STATE_DIR
	return vim.fn.expand((override and override ~= "") and override or "~/.local/state/desk")
end

--- The pending-set snapshot path (§9(g)) for (repo_dir, file): one file
--- per (repo, file) pair, named by a hash of both so two files — in the
--- same repo, or in two different repos — never collide.
function M.pending_snapshot_path(repo_dir, file)
	return state_dir() .. "/pending-" .. vim.fn.sha256(repo_dir .. "\30" .. file) .. ".json"
end

--- Reads the pending-set snapshot (§9(g)) from `path`, or nil if it doesn't
--- exist / isn't valid JSON.
function M.read_pending_snapshot(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local data = fd:read("*a")
	fd:close()
	local ok, parsed = pcall(vim.json.decode, data)
	if not ok then
		return nil
	end
	return parsed
end

--- Writes the pending-set snapshot atomically (temp file + rename), so a
--- reader never sees a half-written one. Creates the snapshot's parent
--- directory (design.md's own state dir may not exist yet on a from-
--- scratch machine, or in a from-scratch test fixture) rather than erroring.
function M.write_pending_snapshot(path, head_sha, pending_ids)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local tmp = string.format("%s.tmp.%d", path, vim.uv.getpid())
	local fd = assert(io.open(tmp, "w"))
	fd:write(vim.json.encode({ at = os.time(), head = head_sha, items = pending_ids }))
	fd:close()
	local ok, err = os.rename(tmp, path)
	if not ok then
		os.remove(tmp)
		error("write_pending_snapshot: rename failed: " .. tostring(err))
	end
end

--- Items declined, or resolved without a key, within the last `days` (by
--- their last key record's time, or — for resolved-without-a-key, which
--- has no key record — the item's own `proposed_at`). Each is returned as
--- {item = <item record>, reason = "declined" | "resolved_without_key"},
--- restorable as a pending suggestion again (design.md §2, "A 'declined
--- recently' listing").
function M.declined_recently(repo_dir, head_lines, index_lines, worktree_lines, days)
	local cutoff = os.time() - days * 86400
	local states, items, last_key = M.derive_all(repo_dir, head_lines, index_lines, worktree_lines)
	local out = {}
	for id, item in pairs(items) do
		local state = states[id]
		local key = last_key[id]
		if state == "declined" and key and key.action == "decline" and (key.at or 0) >= cutoff then
			table.insert(out, { item = item, reason = "declined" })
		elseif state == "declined" and not (key and key.action == "decline") and (item.proposed_at or 0) >= cutoff then
			table.insert(out, { item = item, reason = "resolved_without_key" })
		end
	end
	return out
end

return M
