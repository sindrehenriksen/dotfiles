-- The apply function: turns a validated proposal into
-- file text (desk.proposal applies it onto the user's HEAD). Each item's `target` is the pinned wire-format anchor
-- (`"top"` | `{under=...}` | `{after=...}` | `{at=...}`, or — for
-- `merge`/`move` — a two-element list of these), parsed via
-- desk.block.parse_target. For `edit`, `remove`, and a move/merge's
-- leaving side, that anchor is `{at=...}` quoting the first line of the
-- item's own `before` — "an edit or removal anchors on its own before".
--
-- An item whose `before` doesn't actually sit where its anchor resolved
-- (occurrence-aware, never a bare substring) is deferred: left out of the
-- applied text and counted: the proposal carries it flagged deferred, with
-- no hunk to take. That's a genuine content conflict (the user's edits sit at that
-- spot), retried against the user's text at the next pass.
--
-- An anchor that doesn't resolve AT ALL — its quote is simply gone — is a
-- different failure: there's no longer anywhere specific to identify a
-- conflict against, so rather than defer it forever (a dead end nothing
-- ever surfaces again), it lands at the top of the file instead, same as a
-- plain "top"-anchored item, and is counted as applied. See desk.block.find_after_anchor, which the insertion-
-- shaped half of every kind below goes through for this; a before-shaped
-- leave/removal anchor keeps its own distinct nil (bad anchor vs. content
-- conflict) via resolve_leave, below. A move or merge whose leaving side is
-- gone is deferred instead: its text is what the user deleted or reworded.
-- An item whose anchor is only in the user's uncommitted text never gets
-- here: desk.proposal holds it back until that line is committed.
local block = require("desk.block")
local snippet = require("desk.snippet")

local M = {}

-- Kinds whose content is a pure insertion at one anchor: `after` goes in,
-- nothing is removed.
local INSERT_KINDS = { new = true, add = true, link = true }

local function is_blank(line)
	return line ~= nil and line:match("^%s*$") ~= nil
end

-- Blank lines between sections. `insert` lands between committed lines
-- `prev` and `nxt` (nil at the file's edges). A blank line at either edge
-- of it is kept, one at most, only where it separates it from text on
-- that side; any other is dropped, so an `after` never doubles a blank
-- line or leaves one at the file's start or end. With `section` (a move
-- of a block that stood between blank lines), a landing spot that is a
-- section boundary (blank or the file's edge on one side) also gets a
-- blank line on each side that meets text. An all-blank `insert` is left
-- as it is.
local function fit_edges(insert, prev, nxt, section)
	local first, last = 1, #insert
	while first <= last and is_blank(insert[first]) do
		first = first + 1
	end
	while last >= first and is_blank(insert[last]) do
		last = last - 1
	end
	if first > last then
		return insert
	end
	local boundary = section and (prev == nil or is_blank(prev) or nxt == nil or is_blank(nxt))
	local out = {}
	if prev ~= nil and not is_blank(prev) and (first > 1 or boundary) then
		out[#out + 1] = ""
	end
	for i = first, last do
		out[#out + 1] = insert[i]
	end
	if nxt ~= nil and not is_blank(nxt) and (last < #insert or boundary) then
		out[#out + 1] = ""
	end
	return out
end

-- The blank line a move of committed lines `first`..`last` takes along: when
-- they stand between blank lines (or a blank line and the file's edge),
-- one of those, so the gap they leave is a single blank line. The one
-- below, unless that is the file's end. nil when they don't.
local function bounding_blank(lines, first, last)
	local above = first > 1 and is_blank(lines[first - 1])
	local below = last < #lines and is_blank(lines[last + 1])
	if below and (above or first == 1) then
		return last + 1
	end
	if above and last == #lines then
		return first - 1
	end
	return nil
end
M.bounding_blank = bounding_blank

--- Resolves a before-shaped (leave/removal) anchor against `lines`,
--- distinguishing "the anchor's own quote is gone entirely" (`"bad_anchor"`
--- — nothing left to identify a specific edit location against) from "the
--- quote's there, but what follows it doesn't match `before`" (the user's edits
--- sit at that spot: `"content_mismatch"`, a genuine conflict). A missing
--- anchor (nil — malformed data) is always the latter: inventing a landing
--- spot for something with no anchor at all isn't this function's call.
local function resolve_leave(lines, anchor, before_lines)
	if not anchor then
		return nil, "content_mismatch"
	end
	local pos = block.find_anchor(lines, anchor, before_lines)
	if pos == nil then
		return nil, "bad_anchor"
	end
	if #before_lines > 0 and not snippet.lines_match_at(lines, pos + 1, before_lines) then
		return nil, "content_mismatch"
	end
	return pos, "resolved"
end

--- Where `item` lands in committed `lines`, as the lines its text goes in
--- between (nil at a file edge), and whether it moves a whole section:
--- true, prev, next, section. Nothing when it doesn't resolve, and its
--- text then goes in as it is.
local function landing(lines, item)
	local leave_anchor, land_anchor = block.parse_target(item.target)
	local before_lines = snippet.split_lines(item.before)
	if INSERT_KINDS[item.kind] then
		local pos = block.find_after_anchor(lines, land_anchor)
		if pos then
			return true, lines[pos], lines[pos + 1], false
		end
	elseif item.kind == "edit" then
		local pos, status = resolve_leave(lines, leave_anchor, before_lines)
		if status == "resolved" then
			return true, lines[pos], lines[pos + #before_lines + 1], false
		end
	elseif item.kind == "merge" or item.kind == "move" then
		local leave_pos, leave_status = resolve_leave(lines, leave_anchor, before_lines)
		local land_pos = leave_status ~= "content_mismatch" and block.find_after_anchor(lines, land_anchor) or nil
		if land_pos then
			local section = item.kind == "move"
				and leave_status == "resolved"
				and bounding_blank(lines, leave_pos + 1, leave_pos + #before_lines) ~= nil
			return true, lines[land_pos], lines[land_pos + 1], section
		end
	end
end

--- `item`'s `after` as it lands in committed `lines`: blank lines at its
--- edges fitted to where it lands (fit_edges). The text itself, unchanged,
--- when nothing about the edges changes or the item doesn't resolve.
function M.fitted_after(lines, item)
	local resolved, prev, nxt, section = landing(lines, item)
	if not resolved then
		return item.after
	end
	local after = snippet.split_lines(item.after)
	local fitted = fit_edges(after, prev, nxt, section)
	if vim.deep_equal(fitted, after) then
		return item.after
	end
	-- A last blank line needs its own newline: one alone ends the text.
	return snippet.join_lines(fitted, fitted[#fitted] == "")
end

--- One target file's committed lines (array of strings) + the items that
--- target it -> new lines, a results table item.id -> "applied" |
--- "deferred", and a set item.id -> true of every id that landed at the top
--- only because its anchor didn't resolve (never one legitimately
--- targeting "top") — a caller uses that set purely for its own reporting,
--- never to change how the edit itself applied.
---
--- Every item resolves against the committed `lines` only, and the result
--- is composed in one walk over them, never spliced into a buffer that
--- earlier items already changed. So a removal (an edit's, a remove's, a
--- move's leaving side) drops exactly its own committed lines, by index,
--- and can never take a line some insertion put at the same spot. What
--- goes in sits in the gap before a committed line: insertions first, in
--- input order ("ties at one anchor are laid in input order"), then an
--- edit's replacement, which stays where its own lines were. Two items
--- claiming the same committed line can't both act: the first in input
--- order does, and the other is deferred, a conflict like any other.
function M.apply_file(lines, items)
	local pieces = {} -- gap (0..#lines) -> list of { insert, seq, in_place }
	local claimed = {} -- committed line index -> true once an item removes it
	local results = {}
	local landed_on_top = {}

	local function free(first, count)
		for i = first, first + count - 1 do
			if claimed[i] then
				return false
			end
		end
		return true
	end
	local function claim(first, count)
		for i = first, first + count - 1 do
			claimed[i] = true
		end
	end

	for item_index, item in ipairs(items) do
		local leave_anchor, land_anchor = block.parse_target(item.target)
		local after_lines = snippet.split_lines(M.fitted_after(lines, item))
		local function put(gap, insert, in_place)
			if #insert > 0 then
				pieces[gap] = pieces[gap] or {}
				table.insert(pieces[gap], { insert = insert, seq = item_index, in_place = in_place })
			end
		end
		if INSERT_KINDS[item.kind] then
			local pos, fell_back = block.find_after_anchor(lines, land_anchor)
			if pos == nil then
				results[item.id] = "deferred" -- no anchor at all: malformed, nothing to do
			else
				put(pos, after_lines, false)
				results[item.id] = "applied"
				if fell_back then
					landed_on_top[item.id] = true
				end
			end
		elseif item.kind == "edit" or item.kind == "remove" then
			local before_lines = snippet.split_lines(item.before)
			local pos, status = resolve_leave(lines, leave_anchor, before_lines)
			if status == "bad_anchor" then
				-- Nowhere left to edit in place: land like a plain
				-- insertion at the top instead (nothing for remove,
				-- whose `after` is always empty anyway).
				put(0, item.kind == "edit" and snippet.split_lines(item.after) or {}, false)
				results[item.id] = "applied"
				landed_on_top[item.id] = true
			elseif status == "content_mismatch" or not free(pos + 1, #before_lines) then
				results[item.id] = "deferred"
			else
				claim(pos + 1, #before_lines)
				put(pos, item.kind == "edit" and after_lines or {}, true)
				results[item.id] = "applied"
			end
		elseif item.kind == "merge" or item.kind == "move" then
			local before_lines = snippet.split_lines(item.before)
			local leave_pos, leave_status = resolve_leave(lines, leave_anchor, before_lines)
			local land_pos, land_fell_back
			if leave_status == "resolved" then
				land_pos, land_fell_back = block.find_after_anchor(lines, land_anchor)
			end
			-- A before that is gone from the notes was deleted or reworded
			-- by the user: landing it would put back text they took out.
			if
				leave_status ~= "resolved"
				or land_pos == nil
				or not free(leave_pos + 1, #before_lines)
			then
				results[item.id] = "deferred"
			else
				claim(leave_pos + 1, #before_lines)
				-- A whole section takes one of the blank lines around it
				-- along, so its old place keeps a single one.
				local extra = item.kind == "move" and bounding_blank(lines, leave_pos + 1, leave_pos + #before_lines)
				if extra and free(extra, 1) then
					claim(extra, 1)
				end
				put(land_pos, after_lines, false)
				results[item.id] = "applied"
				if land_fell_back then
					landed_on_top[item.id] = true
				end
			end
		else
			results[item.id] = "deferred"
		end
	end

	local new_lines = {}
	for gap = 0, #lines do
		local here = pieces[gap]
		if here then
			table.sort(here, function(a, b)
				if a.in_place ~= b.in_place then
					return not a.in_place
				end
				return a.seq < b.seq
			end)
			for _, piece in ipairs(here) do
				vim.list_extend(new_lines, piece.insert)
			end
		end
		if gap < #lines and not claimed[gap + 1] then
			new_lines[#new_lines + 1] = lines[gap + 1]
		end
	end

	return new_lines, results, landed_on_top
end

return M
