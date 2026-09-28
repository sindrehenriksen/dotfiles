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
-- module's internal anchor pair; only desk.apply and desk.round still
-- resolve it (at lay-in, and via desk.round.remap_ranges on carry-forward)
-- — a laid-in item's ONGOING state is never re-resolved from its anchor,
-- per design.md's "Review rounds" section, below.
local git = require("desk.git")
local round = require("desk.round")
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
--- pass — by CONTENT, via desk.round, never by re-resolving an anchor
--- against `head_lines` (design.md's "Review rounds" section, which
--- replaced the positional approach this function used to take: his own
--- editing elsewhere in the file could shift an anchor's resolved position
--- without moving the item itself, misreading the result).
---
--- `file` selects which of the ledger's round records (desk.round.latest)
--- to derive laid-in items against — a round is per file, never global.
--- `index_lines` and `worktree_lines` are the current (possibly mutated)
--- content; desk.round.derive maps each laid-in item's own round-recorded
--- range into both independently via a content diff against the round's
--- own snapshot text.
---
--- A resolved (frozen — desk.round.resolved_states, written at commit by
--- desk.review.commit_his_text) item's state is trusted outright, never
--- re-derived against content that may since have moved past what its
--- round entry quotes.
---
--- Returns id -> state, plus the items and last-key tables (so a caller
--- doesn't have to re-read the ledger for those), plus id -> a list of
--- { line, count, role } worktree ranges (1-indexed; count 0 for a removal
--- or a move's leaving side — a gap, not a line) for every "pending" item
--- only — the ones a review key's whole-item action (accept/decline/
--- not-now) can actually land on. A move/merge's list has two entries.
function M.derive_all(repo_dir, file, index_lines, worktree_lines)
	local records = M.read(repo_dir)
	local items = M.items_by_id(records)
	local laid_in, last_key = M.laid_in_and_keys(records)
	local resolved = round.resolved_states(records)
	local current_round = round.latest(records, file)

	local states = {}
	for id in pairs(items) do
		if not laid_in[id] then
			states[id] = "queued" -- never laid in, whatever any key record says
		end
	end

	local content_states, ranges = round.derive(items, current_round, resolved, index_lines, worktree_lines)
	for id, state in pairs(content_states) do
		-- design.md §2 gives "postponed" no content signature of its own —
		-- a "not now" resets an item's lines exactly like a decline does,
		-- so the two are content-identical and only the key record (kept
		-- for exactly this) tells them apart. A content-derived "declined"
		-- is the only bucket a not_now key can override; pending/accepted
		-- never consult it.
		local bucket = state
		if bucket == "declined" and last_key[id] and last_key[id].action == "not_now" then
			bucket = "postponed"
		end
		states[id] = bucket
	end

	-- A laid-in item with no round entry at all (a from-scratch ledger
	-- predating this module, or one the round otherwise dropped) is treated
	-- the same conservative way an unresolvable anchor used to be: still
	-- needs review, never silently dropped.
	for id in pairs(laid_in) do
		if states[id] == nil then
			states[id] = "pending"
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
function M.declined_recently(repo_dir, file, index_lines, worktree_lines, days)
	local cutoff = os.time() - days * 86400
	local states, items, last_key = M.derive_all(repo_dir, file, index_lines, worktree_lines)
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
