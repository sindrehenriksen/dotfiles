-- The ledger: one append-only JSON-lines blob on `refs/desk/ledger` in the
-- notes repo. It holds what he DECIDED — never a copy of what was proposed
-- (that is the proposal commit, desk.proposal): `decline` / `restore` /
-- `restore_applied` records for the decline ledger, keyed by item id and by
-- source URL, and `taken` records, the provenance of suggestions whose text
-- first reached his HEAD, by content hash (the weekly's agent-text
-- exclusion). This module reads it and appends to it through the
-- compare-and-swap-with-retry helper.
local git = require("desk.git")

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

--- Rewrites each of `items`' own (model-assigned) `id` into a
--- ledger-unique one, `<pass>-<scheduled_date>-<seq>-<model id>`: the
--- model only ever promises its own id is unique *within* one reply, never
--- across passes or days, so used directly, Tuesday's "j1" would inherit
--- Monday's decision, and two same-pass captures that both call themselves
--- "c1" would collide with each other. `seq` is assigned in `items`' own
--- order, 1-based, and bumped past every id already in the ledger or in
--- `extra_used_ids` (the ids of items being carried over from the last
--- proposal) or produced earlier in this same batch, so the result is
--- unique across all of them — also for a retried pass reusing the same
--- (pass, date). Returns a new list, same order, everything but `id`
--- untouched.
function M.namespace_ids(repo_dir, pass, scheduled_date, items, extra_used_ids)
	local used = {}
	for _, rec in ipairs(M.read(repo_dir)) do
		if rec.id then
			used[rec.id] = true
		end
	end
	for _, id in ipairs(extra_used_ids or {}) do
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

-- ---------------------------------------------------------------------------
-- Decisions (stateless diff review): the ledger now holds only what he
-- decided, never a copy of what was proposed. `decline` records carry the
-- whole item so a restore can put it back; `restore` records (his undo from
-- the declined-recently list) hand an item back to the next pass, which
-- notes it with `restore_applied` once it has re-proposed it; `taken`
-- records are provenance for the weekly's agent-text exclusion (the item's
-- `after` — or, for a removal, its `before` — by content hash, plus the
-- lines themselves).
-- ---------------------------------------------------------------------------

--- sha256 of an item's agent-owned text: its `after`, or its `before` for a
--- removal (which has no `after`).
function M.content_hash(item)
	local text = item.after
	if text == nil or text == "" then
		text = item.before or ""
	end
	return vim.fn.sha256(text)
end

--- Per id, the latest decision among decline / restore / restore_applied
--- (append order is chronological, last wins). Returns id -> record.
function M.decisions(records)
	local out = {}
	for _, rec in ipairs(records) do
		if rec.id and (rec.type == "decline" or rec.type == "restore" or rec.type == "restore_applied") then
			out[rec.id] = rec
		end
	end
	return out
end

--- Only a URL source stands for one story, so only a URL source can block
--- other items: `notes`, `ticket:KEY` and `session:<id>` each cover many
--- unrelated items and are declined by item id alone.
function M.is_url_source(source)
	return type(source) == "string" and (source:match("^https?://") ~= nil)
end

--- Every URL an item or ledger record stands for: its `source` plus any
--- `also_sources` (one story arriving from several fetchers), URLs only.
function M.item_urls(rec)
	local out = {}
	if M.is_url_source(rec.source) then
		out[#out + 1] = rec.source
	end
	if type(rec.also_sources) == "table" then
		for _, u in ipairs(rec.also_sources) do
			if M.is_url_source(u) then
				out[#out + 1] = u
			end
		end
	end
	return out
end

--- Whether any URL of `item` is in `set` (url -> true).
function M.any_url_in(set, item)
	for _, u in ipairs(M.item_urls(item)) do
		if set[u] then
			return true
		end
	end
	return false
end

--- Currently declined: { ids = {id -> record}, sources = {source -> true},
--- list = ordered records }.
function M.declined(records)
	local ids, sources, list = {}, {}, {}
	for id, rec in pairs(M.decisions(records)) do
		if rec.type == "decline" then
			ids[id] = rec
			for _, u in ipairs(M.item_urls(rec)) do
				sources[u] = true
			end
		end
	end
	for _, rec in ipairs(records) do
		if rec.type == "decline" and ids[rec.id] == rec then
			list[#list + 1] = rec
		end
	end
	return { ids = ids, sources = sources, list = list }
end

--- Items he restored that no pass has re-proposed yet.
function M.restored(records)
	local out = {}
	local latest = M.decisions(records)
	for _, rec in ipairs(records) do
		if rec.type == "restore" and latest[rec.id] == rec then
			out[#out + 1] = rec.item
		end
	end
	return out
end

--- id -> `taken` record, for every item ever recorded as taken.
function M.taken_by_id(records)
	local out = {}
	for _, rec in ipairs(records) do
		if rec.type == "taken" and rec.id then
			out[rec.id] = rec
		end
	end
	return out
end

--- The URL sources of everything ever taken: a story he has already taken
--- is not offered again under a new id.
function M.taken_sources(records)
	local out = {}
	for _, rec in ipairs(records) do
		if rec.type == "taken" then
			for _, u in ipairs(M.item_urls(rec)) do
				out[u] = true
			end
		end
	end
	return out
end

--- Records `items` as declined. Items already declined are skipped.
function M.record_declines(repo_dir, items)
	local declined = M.declined(M.read(repo_dir)).ids
	local records = {}
	for _, item in ipairs(items) do
		if not declined[item.id] then
			records[#records + 1] = {
				type = "decline",
				id = item.id,
				file = item.file,
				source = item.source,
				also_sources = item.also_sources,
				headline = item.headline,
				at = os.time(),
				item = item,
			}
		end
	end
	if #records == 0 then
		return true
	end
	return M.append_many(repo_dir, records) ~= nil
end

--- Restores the declined item `id`: it leaves the declined set (so its
--- source is no longer blocked) and the next pass proposes it again.
function M.restore_declined(repo_dir, id)
	local rec = M.declined(M.read(repo_dir)).ids[id]
	if not rec then
		return false, "not declined"
	end
	return M.append(repo_dir, { type = "restore", id = id, at = os.time(), item = rec.item }) ~= nil
end

--- Records `items` as taken (skipping any already recorded).
function M.record_taken(repo_dir, items)
	local have = M.taken_by_id(M.read(repo_dir))
	local records = {}
	for _, item in ipairs(items) do
		if not have[item.id] then
			records[#records + 1] = {
				type = "taken",
				id = item.id,
				file = item.file,
				kind = item.kind,
				hash = M.content_hash(item),
				before = item.before,
				after = item.after,
				source = item.source,
				also_sources = item.also_sources,
				headline = item.headline,
				session_id = item.session_id,
				capture_kind = item.capture_kind,
				at = os.time(),
			}
		end
	end
	if #records == 0 then
		return true
	end
	return M.append_many(repo_dir, records) ~= nil
end

return M
