-- The proposal (stateless diff review): `refs/desk/proposal` is ONE commit
-- per pass whose parent is his HEAD at pass time and whose tree holds the
-- configured files (notes.md, reading.md) with every suggestion applied,
-- plus `proposal.json` listing the items. Nothing in it ever enters his
-- notes unless he takes a hunk, and nothing about it is tracked by position:
-- an item is *taken* when its `after` text is present in his HEAD, and
-- *declined* when the decline ledger (desk.ledger) says so, by id or by
-- source URL. The next pass builds from his newest HEAD plus the previous
-- proposal's untaken, undeclined items plus the new ones — an untaken item
-- coming back is "not now".
local apply = require("desk.apply")
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

--- Whether `item`'s proposed change is present in `lines`: its `after` is
--- there, or — for a removal — its `before` is gone.
function M.proposed_in(item, lines)
	local after = snippet.split_lines(item.after)
	if #after > 0 then
		return M.contains(lines, after)
	end
	local before = snippet.split_lines(item.before)
	if #before > 0 then
		return not M.contains(lines, before)
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

local function head_sha(repo)
	local ok, out = git.run(repo, { "rev-parse", "--verify", "--quiet", "HEAD" })
	return ok and vim.trim(out) or nil
end

--- Records as taken every item of the tip proposal whose change is now in
--- his HEAD and not yet recorded. Returns the items newly recorded.
function M.sync_taken(repo)
	local p = M.read(repo)
	if not p then
		return {}
	end
	local have = ledger.taken_by_id(ledger.read(repo))
	local head_cache, new = {}, {}
	for _, item in ipairs(p.items) do
		if not item.deferred and not have[item.id] then
			head_cache[item.file] = head_cache[item.file] or M.lines_at(repo, "HEAD", item.file)
			if M.proposed_in(item, head_cache[item.file]) then
				new[#new + 1] = item
			end
		end
	end
	if #new > 0 then
		ledger.record_taken(repo, new)
	end
	return new
end

--- The tip proposal's items still waiting on him: not deferred, not taken,
--- not declined.
function M.open_items(repo)
	local p = M.read(repo)
	if not p then
		return {}
	end
	local records = ledger.read(repo)
	local declined = ledger.declined(records)
	local have = ledger.taken_by_id(records)
	local head_cache, out = {}, {}
	for _, item in ipairs(p.items) do
		if not item.deferred and not have[item.id] and not declined.ids[item.id] then
			head_cache[item.file] = head_cache[item.file] or M.lines_at(repo, "HEAD", item.file)
			if not M.proposed_in(item, head_cache[item.file]) then
				out[#out + 1] = item
			end
		end
	end
	return out
end

-- Sorted-key JSON, so two targets built in a different key order compare equal.
local function canon(v)
	if type(v) ~= "table" then
		return vim.json.encode(v)
	end
	if vim.islist(v) then
		local parts = {}
		for _, x in ipairs(v) do
			parts[#parts + 1] = canon(x)
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = vim.tbl_keys(v)
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = vim.json.encode(k) .. ":" .. canon(v[k])
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Whether new item `n` replaces carried item `e`: it names it
--- (`supersedes`), shares its source, or targets the same place with the
--- same kind (never "top": every news item lands there).
local function supersedes(n, e)
	if n.supersedes ~= nil and n.supersedes == e.id then
		return true
	end
	if (n.source or "") ~= "" and n.source == e.source then
		return true
	end
	if e.target ~= nil and canon(e.target) ~= canon("top") and n.kind == e.kind and canon(n.target) == canon(e.target) then
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

	local stats = {}
	local sha, err = git.cas_retry(repo, M.REF, function(old_sha)
		local prev = old_sha and M.read(repo, old_sha) or { items = {} }
		local head_lines = {}
		for _, f in ipairs(files) do
			head_lines[f] = M.lines_at(repo, head, f)
		end

		-- Carried: last proposal's items that are neither taken nor declined,
		-- then items he restored that no pass has re-proposed yet.
		local carried, carried_ids = {}, {}
		local function carry(item)
			if carried_ids[item.id] or taken[item.id] or declined.ids[item.id] then
				return
			end
			if (item.source or "") ~= "" and declined.sources[item.source] then
				return
			end
			if item.file and head_lines[item.file] and not item.deferred and M.proposed_in(item, head_lines[item.file]) then
				return -- taken since the last sync
			end
			item = vim.deepcopy(item)
			item.deferred = nil
			carried_ids[item.id] = true
			carried[#carried + 1] = item
		end
		local restored_ids = {}
		for _, item in ipairs(prev.items) do
			carry(item)
		end
		for _, item in ipairs(ledger.restored(records)) do
			if not carried_ids[item.id] then
				restored_ids[#restored_ids + 1] = item.id
			end
			carry(item)
		end

		-- New: namespaced, minus anything he declined (by source) or that is
		-- already in his text, and replacing any carried item it supersedes.
		local used = {}
		for id in pairs(carried_ids) do
			used[#used + 1] = id
		end
		local named = ledger.namespace_ids(repo, pass, scheduled_date, new_items, used)
		local fresh = {}
		for _, item in ipairs(named) do
			local blocked = (item.source or "") ~= "" and declined.sources[item.source]
			local known = item.file and head_lines[item.file] and M.proposed_in(item, head_lines[item.file])
			if not blocked and not known then
				fresh[#fresh + 1] = item
			end
		end
		local kept = {}
		for _, e in ipairs(carried) do
			local replaced = false
			for _, n in ipairs(fresh) do
				if supersedes(n, e) then
					replaced = true
					break
				end
			end
			if not replaced then
				kept[#kept + 1] = e
			end
		end

		local items = {}
		for _, n in ipairs(fresh) do
			items[#items + 1] = n
		end
		for _, e in ipairs(kept) do
			items[#items + 1] = e
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
		stats = { new = #fresh, carried = #kept, applied = applied_n, deferred = deferred_n, restored = restored_ids }
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
