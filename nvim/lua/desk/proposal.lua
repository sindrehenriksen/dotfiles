-- The proposal (stateless diff review): `refs/desk/proposal` is ONE commit
-- per pass whose parent is the user's HEAD at pass time and whose tree holds the
-- configured files (notes.md, reading.md) with every suggestion applied,
-- plus `proposal.json` listing the items. Nothing in it ever enters the user's
-- notes unless the user takes a hunk, and nothing about it is tracked by position:
-- an item is *taken* when its `after` text is present in the user's HEAD, and
-- *declined* when the decline ledger (desk.ledger) says so, by id or by
-- source URL. The next pass builds from the user's newest HEAD plus the previous
-- proposal's untaken, undeclined items plus the new ones — an untaken item
-- coming back is "not now".
local apply = require("desk.apply")
local block = require("desk.block")
local git = require("desk.git")
local ledger = require("desk.ledger")
local snippet = require("desk.snippet")

local M = {}

M.REF = "refs/desk/proposal"

--- `rev:file` split into lines; {} if the blob doesn't exist.
function M.lines_at(repo, rev, file)
	local ok, out = git.run(repo, { "show", rev .. ":" .. file })
	if not ok then
		return {}
	end
	return (snippet.split_lines(out))
end

--- True if `block` (a list of lines) appears contiguously in `lines`.
function M.contains(lines, block)
	if #block == 0 then
		return false
	end
	for pos = 1, #lines - #block + 1 do
		if snippet.lines_match_at(lines, pos, block) then
			return true
		end
	end
	return false
end

-- The candidate start positions for an insertion's `after` lines under a
-- landing anchor, in `lines`: where apply would put them, widened to the
-- whole block they extend. nil when the anchor says nothing (then the whole
-- file is the region).
local function landing_window(lines, anchor)
	if anchor == nil then
		return nil
	end
	if anchor.kind == "at" then
		return nil
	end
	local first_blank = #lines + 1
	if anchor.kind ~= "top" then
		local idx = block.find_line(lines, anchor.quote)
		if idx then
			local e = anchor.kind == "under" and block.block_end(lines, idx) or select(2, block.block_containing(lines, idx))
			return idx + 1, e + 1
		end
	end
	-- "top", or an anchor whose quote is gone (apply lands it on top too).
	for i, l in ipairs(lines) do
		if l:match("^%s*$") then
			first_blank = i
			break
		end
	end
	return 1, math.max(1, first_blank)
end

local function contains_within(lines, block_lines, first, last)
	for pos = first, last do
		if snippet.lines_match_at(lines, pos, block_lines) then
			return true
		end
	end
	return false
end

-- Whether the removal `item` is done in `lines`. With `base` (the user's text when
-- the proposal was built) the anchored occurrence is the one whose base
-- lines the user's edits since then deleted — so removing the other copy of a
-- repeated line doesn't count, and removing this one does even though a
-- copy remains. Without it, the occurrence the anchor resolves to must no
-- longer hold `before`.
local function removal_done(item, lines, base, before)
	local leave = block.parse_target(item.target)
	if base and leave and leave.kind == "at" then
		local at = block.find_anchor(base, leave)
		if at and snippet.lines_match_at(base, at + 1, before) then
			local hunks = vim.diff(
				snippet.join_lines(base, true),
				snippet.join_lines(lines, true),
				{ result_type = "indices" }
			)
			for l = at + 1, at + #before do
				local covered = false
				for _, h in ipairs(hunks) do
					if h[2] > 0 and l >= h[1] and l <= h[1] + h[2] - 1 then
						covered = true
						break
					end
				end
				if not covered then
					return false
				end
			end
			return true
		end
	end
	if leave and leave.kind == "at" then
		local at = block.find_anchor(lines, leave)
		if at == nil then
			return true
		end
		if snippet.lines_match_at(lines, at + 1, before) then
			return false
		end
	end
	return not M.contains(lines, before)
end

--- Whether `item`'s proposed change is present in `lines`, judged at the
--- place it applies to rather than anywhere in the file: an insertion's `after` within the block of its landing
--- anchor (a move or merge at its landing side, not where its `before`
--- sits), a removal's anchored occurrence of `before` gone (`base`, the user's text
--- at the proposal's pass time, pins which occurrence), an edit's `after`
--- present.
function M.proposed_in(item, lines, base)
	local after = snippet.split_lines(item.after)
	if #after > 0 then
		if item.kind == "edit" then
			return M.contains(lines, after)
		end
		local _, land = block.parse_target(item.target)
		local first, last = landing_window(lines, land)
		if first == nil then
			return M.contains(lines, after)
		end
		return contains_within(lines, after, first, last)
	end
	local before = snippet.split_lines(item.before)
	if #before > 0 then
		return removal_done(item, lines, base, before)
	end
	return false
end

--- Reads the proposal at `sha` (default: the ref's tip), or nil if there is
--- none. Returns { sha, parent, items }.
function M.read(repo, sha)
	sha = sha or git.ref_sha(repo, M.REF)
	if not sha then
		return nil
	end
	local ok, out = git.run(repo, { "show", sha .. ":proposal.json" })
	if not ok then
		return nil
	end
	local decoded_ok, parsed = pcall(vim.json.decode, out)
	if not decoded_ok or type(parsed) ~= "table" then
		return nil
	end
	local parent_ok, parent = git.run(repo, { "rev-parse", "--verify", "--quiet", sha .. "^" })
	return { sha = sha, parent = parent_ok and vim.trim(parent) or nil, items = parsed.items or {} }
end

--- The items of the tip proposal (or {}), for callers that only list them.
function M.read_items(repo)
	local p = M.read(repo)
	return p and p.items or {}
end

--- The text of `file` the proposal `p` was built on (the user's HEAD at pass time).
function M.base_lines(repo, p, file)
	return p.parent and M.lines_at(repo, p.parent, file) or nil
end

local function head_sha(repo)
	local ok, out = git.run(repo, { "rev-parse", "--verify", "--quiet", "HEAD" })
	return ok and vim.trim(out) or nil
end

--- Records as taken every item of the tip proposal whose change is now in
--- the user's HEAD and not yet recorded. Returns the items newly recorded.
function M.sync_taken(repo)
	local p = M.read(repo)
	if not p then
		return {}
	end
	local have = ledger.taken_by_id(ledger.read(repo))
	-- Taken is a decision made at some point: the change was in the user's text at
	-- the anchored place in HEAD or in any commit since the proposal's
	-- parent (the user may have moved the line afterwards).
	local revs = { "HEAD" }
	if p.parent then
		local ok, out = git.run(repo, { "rev-list", p.parent .. "..HEAD" })
		if ok then
			for sha in out:gmatch("%S+") do
				revs[#revs + 1] = sha
			end
		end
	end
	local cache, new = {}, {}
	local function at(rev, file)
		cache[rev .. file] = cache[rev .. file] or M.lines_at(repo, rev, file)
		return cache[rev .. file]
	end
	for _, item in ipairs(p.items) do
		if not item.deferred and not have[item.id] then
			local base = M.base_lines(repo, p, item.file)
			for _, rev in ipairs(revs) do
				if M.proposed_in(item, at(rev, item.file), base) then
					new[#new + 1] = item
					break
				end
			end
		end
	end
	if #new > 0 then
		ledger.record_taken(repo, new)
	end
	return new
end

--- `git merge-file` of `ours` (the user's current text) with the proposal: base is
--- the proposal's parent version, theirs the proposal's version. Returns
--- the `--ours` merge (the user's text winning any conflict), the `--union` merge
--- (both sides kept where they conflict), or nil, err.
function M.merged_lines(repo, p, file, ours_lines)
	local base = p.parent and M.lines_at(repo, p.parent, file) or {}
	local theirs = M.lines_at(repo, p.sha, file)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local function put(name, lines)
		local path = dir .. "/" .. name
		local fd = assert(io.open(path, "w"))
		fd:write(snippet.join_lines(lines, true))
		fd:close()
		return path
	end
	local ours_path, base_path, theirs_path = put("ours", ours_lines), put("base", base), put("theirs", theirs)
	local out = {}
	for _, mode in ipairs({ "--ours", "--union" }) do
		local ok, text, err = git.run(repo, { "merge-file", "-p", mode, ours_path, base_path, theirs_path })
		if not ok then
			vim.fn.delete(dir, "rf")
			return nil, "git merge-file failed: " .. err
		end
		out[#out + 1] = (snippet.split_lines(text))
	end
	vim.fn.delete(dir, "rf")
	return out[1], out[2]
end

--- The suggestions of `file` a review can actually show against `ours`
--- (the user's text): not deferred, not taken or declined, in the merged view but
--- not yet in the user's text. A suggestion the user's own edit conflicts with is still
--- shown, in the union view, and listed in `conflicts` with the line of the user's
--- text it sits next to. Returns { shown = id -> item, conflicts = id ->
--- line, merged = lines }, or nil, err.
function M.reviewable(repo, p, file, ours)
	local clean, merged = M.merged_lines(repo, p, file, ours)
	if not clean then
		return nil, merged
	end
	local base = M.base_lines(repo, p, file)
	local records = ledger.read(repo)
	local declined = ledger.declined(records)
	local taken = ledger.taken_by_id(records)
	local hunks
	local shown, conflicts = {}, {}
	for _, item in ipairs(p.items) do
		if
			item.file == file
			and not item.deferred
			and not taken[item.id]
			and not declined.ids[item.id]
			and M.proposed_in(item, merged, base)
			and not M.proposed_in(item, ours, base)
		then
			shown[item.id] = item
			if not M.proposed_in(item, clean, base) then
				hunks = hunks or vim.diff(snippet.join_lines(ours, true), snippet.join_lines(merged, true), { result_type = "indices" })
				local after = snippet.split_lines(item.after)
				local line = 1
				for _, pos in ipairs(M.positions(merged, after)) do
					for _, h in ipairs(hunks) do
						if pos >= h[3] and pos <= h[3] + math.max(h[4], 1) - 1 then
							line = h[2] > 0 and h[1] or h[1] + 1
						end
					end
				end
				conflicts[item.id] = math.max(1, math.min(line, math.max(#ours, 1)))
			end
		end
	end
	return { shown = shown, conflicts = conflicts, merged = merged }
end

--- Every 1-indexed position at which `block_lines` occurs in `lines`.
function M.positions(lines, block_lines)
	local out = {}
	for pos = 1, #lines - #block_lines + 1 do
		if #block_lines > 0 and snippet.lines_match_at(lines, pos, block_lines) then
			out[#out + 1] = pos
		end
	end
	return out
end

--- The tip proposal's items still waiting on the user: exactly the ones a review
--- of the user's HEAD would show.
function M.open_items(repo)
	local p = M.read(repo)
	if not p then
		return {}
	end
	local by_file, files = {}, {}
	for _, item in ipairs(p.items) do
		if item.file and not by_file[item.file] then
			by_file[item.file] = true
			files[#files + 1] = item.file
		end
	end
	local out = {}
	for _, f in ipairs(files) do
		local r = M.reviewable(repo, p, f, M.lines_at(repo, "HEAD", f))
		if r then
			for _, item in ipairs(p.items) do
				if r.shown[item.id] then
					out[#out + 1] = item
				end
			end
		end
	end
	return out
end

local canon = ledger.canon

local in_place_kind = { edit = true, remove = true, move = true, merge = true }

--- Whether `target` anchors on an existing line (`{at = line}`, or the
--- `at` first element of a move/merge pair). An insertion under a shared
--- heading or at the top never makes two items the same suggestion.
local function at_anchored(target)
	if type(target) ~= "table" then
		return false
	end
	if target.at ~= nil then
		return true
	end
	return vim.islist(target) and type(target[1]) == "table" and target[1].at ~= nil
end

--- Whether new item `n` replaces carried item `e`: it names it
--- (`supersedes`), shares its URL source (one story, one item; `notes`,
--- tickets and sessions each cover many unrelated items), or is an in-place
--- edit/remove/move/merge of the same existing line (never an insertion: two
--- `add`s under one heading are two suggestions).
local function supersedes(n, e)
	if n.supersedes ~= nil and n.supersedes == e.id then
		return true
	end
	local have = {}
	for _, u in ipairs(ledger.item_urls(e)) do
		have[u] = true
	end
	if ledger.any_url_in(have, n) then
		return true
	end
	if in_place_kind[e.kind] and n.kind == e.kind and at_anchored(e.target) and canon(n.target) == canon(e.target) then
		return true
	end
	return false
end

--- Builds the pass's proposal commit and moves refs/desk/proposal to it.
--- `new_items` are validated, un-namespaced items from this pass; `files`
--- the configured files. Returns the new sha and a stats table, or nil, err.
function M.build(repo, pass, scheduled_date, new_items, files)
	local head = head_sha(repo)
	if not head then
		return nil, "the notes repo has no HEAD"
	end
	M.sync_taken(repo)
	local records = ledger.read(repo)
	local declined = ledger.declined(records)
	local taken = ledger.taken_by_id(records)
	local taken_sources = ledger.taken_sources(records)

	local stats = {}
	local sha, err = git.cas_retry(repo, M.REF, function(old_sha)
		local prev = old_sha and M.read(repo, old_sha) or { items = {} }
		local head_lines = {}
		for _, f in ipairs(files) do
			head_lines[f] = M.lines_at(repo, head, f)
		end

		-- An item's `after` with the blank lines at its edges fitted to where
		-- it lands in HEAD (desk.apply.fitted_after), so what is checked
		-- against the user's text, stored and applied is the same text.
		local function fitted(item)
			local lines = item.file and head_lines[item.file]
			if not lines then
				return item
			end
			local after = apply.fitted_after(lines, item)
			if after == item.after then
				return item
			end
			item = vim.deepcopy(item)
			item.after = after
			return item
		end

		-- Carried: last proposal's items that are neither taken nor declined,
		-- then items the user restored that no pass has re-proposed yet.
		local carried, carried_ids = {}, {}
		local function carry(item, base)
			item = fitted(item)
			if carried_ids[item.id] or taken[item.id] or declined.ids[item.id] or declined.keys[ledger.content_key(item)] then
				return
			end
			if ledger.any_url_in(declined.sources, item) or ledger.any_url_in(taken_sources, item) then
				return
			end
			if item.file and head_lines[item.file] and not item.deferred and M.proposed_in(item, head_lines[item.file], base) then
				return -- taken since the last sync
			end
			item = vim.deepcopy(item)
			item.deferred = nil
			carried_ids[item.id] = true
			carried[#carried + 1] = item
		end
		local restored_ids = {}
		for _, item in ipairs(prev.items) do
			carry(item, prev.parent and M.base_lines(repo, prev, item.file))
		end
		for _, item in ipairs(ledger.restored(records)) do
			if not carried_ids[item.id] then
				restored_ids[#restored_ids + 1] = item.id
			end
			carry(item)
		end

		-- New: namespaced, minus anything the user declined (by source) or that is
		-- already in the user's text, and replacing any carried item it supersedes.
		local used = {}
		for id in pairs(carried_ids) do
			used[#used + 1] = id
		end
		local named = ledger.namespace_ids(repo, pass, scheduled_date, new_items, used)
		local fresh = {}
		for _, item in ipairs(named) do
			item = fitted(item)
			local blocked = ledger.any_url_in(declined.sources, item)
				or ledger.any_url_in(taken_sources, item)
				or declined.keys[ledger.content_key(item)]
			local known = item.file and head_lines[item.file] and M.proposed_in(item, head_lines[item.file])
			if not blocked and not known then
				fresh[#fresh + 1] = item
			end
		end
		local kept, superseded = {}, 0
		for _, e in ipairs(carried) do
			local replaced = false
			for _, n in ipairs(fresh) do
				if supersedes(n, e) then
					replaced = true
					break
				end
			end
			if replaced then
				superseded = superseded + 1
			else
				kept[#kept + 1] = e
			end
		end

		-- Order, which is also the order items sharing an anchor land in: this
		-- run's items above everything carried from earlier runs, and within
		-- this run in the order its steps staged them. A pass stages once per
		-- step that suggests anything, so an earlier step's items (the judge's
		-- news) are already carried when a later step (retention, close)
		-- builds; the step order in the config decides which reads first.
		local run_prefix = "^" .. vim.pesc(pass .. "-" .. scheduled_date .. "-")
		local this_run, older = {}, {}
		for _, e in ipairs(kept) do
			if tostring(e.id):match(run_prefix) then
				this_run[#this_run + 1] = e
			else
				older[#older + 1] = e
			end
		end
		local items = {}
		for _, list in ipairs({ this_run, fresh, older }) do
			for _, item in ipairs(list) do
				items[#items + 1] = item
			end
		end

		-- Apply per file onto HEAD.
		local blobs = {}
		local by_file = {}
		for _, item in ipairs(items) do
			by_file[item.file] = by_file[item.file] or {}
			table.insert(by_file[item.file], item)
		end
		local applied_n, deferred_n = 0, 0
		for _, f in ipairs(files) do
			local new_lines, results = apply.apply_file(head_lines[f], by_file[f] or {})
			for _, item in ipairs(by_file[f] or {}) do
				if results[item.id] == "applied" then
					applied_n = applied_n + 1
				else
					item.deferred = true
					deferred_n = deferred_n + 1
				end
			end
			local blob = git.hash_object_write(repo, snippet.join_lines(new_lines, true))
			if not blob then
				return nil, "could not write " .. f
			end
			blobs[#blobs + 1] = { name = f, sha = blob }
		end
		for _, item in ipairs(items) do
			if not vim.tbl_contains(files, item.file) then
				item.deferred = true
				deferred_n = deferred_n + 1
			end
		end

		local json_blob = git.hash_object_write(repo, vim.json.encode({ items = items, head = head, pass = pass }))
		if not json_blob then
			return nil, "could not write proposal.json"
		end
		blobs[#blobs + 1] = { name = "proposal.json", sha = json_blob }
		table.sort(blobs, function(a, b)
			return a.name < b.name
		end)
		local lines = {}
		for _, b in ipairs(blobs) do
			lines[#lines + 1] = string.format("100644 blob %s\t%s", b.sha, b.name)
		end
		local mk_ok, tree = git.run(repo, { "mktree" }, table.concat(lines, "\n") .. "\n")
		if not mk_ok then
			return nil, "mktree failed"
		end
		local c_ok, commit = git.run(repo, { "commit-tree", vim.trim(tree), "-p", head, "-m", "proposal" })
		if not c_ok then
			return nil, "commit-tree failed"
		end
		stats = { new = #fresh, carried = #kept, applied = applied_n, deferred = deferred_n, restored = restored_ids, superseded = superseded, skipped = #named - #fresh }
		return vim.trim(commit)
	end)
	if not sha then
		return nil, err
	end
	if #stats.restored > 0 then
		local marks = {}
		for _, id in ipairs(stats.restored) do
			marks[#marks + 1] = { type = "restore_applied", id = id, at = os.time() }
		end
		ledger.append_many(repo, marks)
	end
	return sha, stats
end

return M
