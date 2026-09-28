-- The apply function (design.md §9(e)): turns a validated proposal into
-- buffer text. Each item's `target` is the pinned wire-format anchor
-- (`"top"` | `{under=...}` | `{after=...}` | `{at=...}`, or — for
-- `merge`/`move` — a two-element list of these), parsed via
-- desk.block.parse_target. For `edit`, `remove`, and a move/merge's
-- leaving side, that anchor is `{at=...}` quoting the first line of the
-- item's own `before` — "an edit or removal anchors on its own before".
--
-- An item whose `before` doesn't actually sit where its anchor resolved
-- (occurrence-aware, never a bare substring) is deferred: left out of the
-- applied text, stays queued, and is counted — design.md §2, "An item that
-- doesn't apply cleanly at key press is deferred." That's a genuine
-- content conflict (his edits sit at that spot) and stays deferred
-- forever, on purpose.
--
-- An anchor that doesn't resolve AT ALL — its quote is simply gone — is a
-- different failure: there's no longer anywhere specific to identify a
-- conflict against, so rather than defer it forever (a dead end nothing
-- ever surfaces again), it lands at the top of the file instead, same as a
-- plain "top"-anchored item, and is counted as applied — never left
-- silently queued. See desk.block.find_after_anchor, which the insertion-
-- shaped half of every kind below goes through for this; a before-shaped
-- leave/removal anchor keeps its own distinct nil (bad anchor vs. content
-- conflict) via resolve_leave, below.
local block = require("desk.block")
local snippet = require("desk.snippet")

local M = {}

-- Kinds whose content is a pure insertion at one anchor: `after` goes in,
-- nothing is removed.
local INSERT_KINDS = { new = true, add = true, link = true }

--- Resolves a before-shaped (leave/removal) anchor against `lines`,
--- distinguishing "the anchor's own quote is gone entirely" (`"bad_anchor"`
--- — nothing left to identify a specific edit location against) from "the
--- quote's there, but what follows it doesn't match `before`" (his edits
--- sit at that spot: `"content_mismatch"`, a genuine conflict). A missing
--- anchor (nil — malformed data) is always the latter: inventing a landing
--- spot for something with no anchor at all isn't this function's call.
local function resolve_leave(lines, anchor, before_lines)
	if not anchor then
		return nil, "content_mismatch"
	end
	local pos = block.find_anchor(lines, anchor)
	if pos == nil then
		return nil, "bad_anchor"
	end
	if #before_lines > 0 and not snippet.lines_match_at(lines, pos + 1, before_lines) then
		return nil, "content_mismatch"
	end
	return pos, "resolved"
end

--- One target file's committed lines (array of strings) + the items that
--- target it -> new lines, a results table item.id -> "applied" |
--- "deferred", a set item.id -> true of every id that landed at the top
--- only because its anchor didn't resolve (never one legitimately
--- targeting "top") — a caller uses that set purely for its own reporting
--- (e.g. desk.review's stats), never to change how the edit itself
--- applied — and (desk.round's own input, design.md's "Review rounds")
--- item.id -> a list of { line, count, role } giving each applied item's
--- exact final range(s) in `new_lines` (1-indexed; two entries for
--- merge/move, in "leave"/"land" order; one "removal"-role entry for a
--- remove; one "edit"-role entry for everything else). `role` distinguishes
--- content-shaped ranges ("edit", "land") from gap-shaped ones ("leave",
--- "removal", always count 0 — nothing sits there, only where it would go
--- back).
---
--- Edits are collected as (position, remove-count, insert-lines) against
--- the *original* `lines`, tagged with the item id, role and the item's own
--- index in `items` (its lay-in-order tie-break — design.md: "ties at one
--- anchor are laid in input order"). They're applied bottom-of-file-up (by
--- descending original position, ties broken by *descending* input index —
--- so of two items sharing an anchor, the later one is inserted first and
--- the earlier one, inserted afterward at the same spot, pushes it down,
--- landing above it — input order top to bottom), so an earlier (lower)
--- edit's line-count change never shifts a later (higher) one out from
--- under it. Final ranges are then computed in a *second*, ascending pass
--- over the same edits with a running offset — the position each edit was
--- collected at only survives unchanged past every edit that lands below
--- it; one above it (processed later in the descending mutation pass) can
--- still shift it once inserted.
function M.apply_file(lines, items)
	local edits = {}
	local results = {}
	local landed_on_top = {}

	for item_index, item in ipairs(items) do
		local leave_anchor, land_anchor = block.parse_target(item.target)
		local function push(pos, remove, insert, role)
			edits[#edits + 1] =
				{ pos = pos, remove = remove, insert = insert, item_id = item.id, role = role, seq = item_index }
		end
		if INSERT_KINDS[item.kind] then
			local pos, fell_back = block.find_after_anchor(lines, land_anchor)
			if pos == nil then
				results[item.id] = "deferred" -- no anchor at all: malformed, nothing to do
			else
				push(pos, 0, snippet.split_lines(item.after), "edit")
				results[item.id] = "applied"
				if fell_back then
					landed_on_top[item.id] = true
				end
			end
		elseif item.kind == "edit" or item.kind == "remove" then
			local before_lines = snippet.split_lines(item.before)
			local role = item.kind == "remove" and "removal" or "edit"
			local pos, status = resolve_leave(lines, leave_anchor, before_lines)
			if status == "bad_anchor" then
				-- Nowhere left to edit in place: land like a plain
				-- insertion at the top instead (empty insert for remove,
				-- whose `after` is always empty anyway).
				push(0, 0, item.kind == "edit" and snippet.split_lines(item.after) or {}, role)
				results[item.id] = "applied"
				landed_on_top[item.id] = true
			elseif status == "content_mismatch" then
				results[item.id] = "deferred"
			else
				push(pos, #before_lines, item.kind == "edit" and snippet.split_lines(item.after) or {}, role)
				results[item.id] = "applied"
			end
		elseif item.kind == "merge" or item.kind == "move" then
			local before_lines = snippet.split_lines(item.before)
			local leave_pos, leave_status = resolve_leave(lines, leave_anchor, before_lines)
			if leave_status == "content_mismatch" then
				results[item.id] = "deferred"
			else
				local land_pos, land_fell_back = block.find_after_anchor(lines, land_anchor)
				if land_pos == nil then
					results[item.id] = "deferred"
				else
					if leave_status == "resolved" then
						push(leave_pos, #before_lines, {}, "leave")
					end
					push(land_pos, 0, snippet.split_lines(item.after), "land")
					results[item.id] = "applied"
					if leave_status == "bad_anchor" or land_fell_back then
						landed_on_top[item.id] = true
					end
				end
			end
		else
			results[item.id] = "deferred"
		end
	end

	-- Final ranges: ascending by original position (ties by ascending
	-- input order — the earlier item's edit is visited, and thus placed,
	-- first at a shared spot, exactly matching where the mutation pass
	-- below actually leaves it), accumulating the net line-count change of
	-- every edit already visited.
	local ascending = vim.deepcopy(edits)
	table.sort(ascending, function(a, b)
		if a.pos ~= b.pos then
			return a.pos < b.pos
		end
		return a.seq < b.seq
	end)
	local ranges = {}
	local offset = 0
	for _, e in ipairs(ascending) do
		local final_pos = e.pos + offset
		ranges[e.item_id] = ranges[e.item_id] or {}
		table.insert(ranges[e.item_id], { line = final_pos + 1, count = #e.insert, role = e.role })
		offset = offset + (#e.insert - e.remove)
	end

	-- Mutation: descending by original position, ties by *descending*
	-- input order (the later item's insertion happens first at a shared
	-- spot, so the earlier item's insertion afterward pushes it down —
	-- landing the earlier item first, top to bottom, matching the ranges
	-- computed above).
	table.sort(edits, function(a, b)
		if a.pos ~= b.pos then
			return a.pos > b.pos
		end
		return a.seq > b.seq
	end)

	local new_lines = vim.deepcopy(lines)
	for _, e in ipairs(edits) do
		for _ = 1, e.remove do
			table.remove(new_lines, e.pos + 1)
		end
		for i = #e.insert, 1, -1 do
			table.insert(new_lines, e.pos + 1, e.insert[i])
		end
	end

	return new_lines, results, landed_on_top, ranges
end

--- Groups `items` by their `file` field and applies each group against
--- `lines_by_file[file]` (every target file the proposal touches must have
--- an entry, even if empty). Returns new_lines_by_file, results (item.id ->
--- "applied" | "deferred", across every file).
function M.apply(lines_by_file, items)
	local by_file = {}
	for _, item in ipairs(items) do
		by_file[item.file] = by_file[item.file] or {}
		table.insert(by_file[item.file], item)
	end

	local new_lines_by_file = {}
	local results = {}
	for file, file_lines in pairs(lines_by_file) do
		local new_lines, file_results = M.apply_file(file_lines, by_file[file] or {})
		new_lines_by_file[file] = new_lines
		for id, r in pairs(file_results) do
			results[id] = r
		end
	end
	return new_lines_by_file, results
end

return M
