-- The block rule and anchor resolution.
-- One shared reader for where a block starts and ends, used to place a
-- proposal item at an anchor and to re-resolve a pending item's position
-- fresh each run (so drift from the user's own edits elsewhere in the file doesn't
-- go stale).
--
-- What this module deliberately does NOT implement: recognizing a block as
-- a *section* by a session-name token. That recognition belongs with the annotations/hotkey
-- piece, which owns the token table; it isn't needed to resolve an anchor,
-- since every anchor already carries which kind it is (`under`, `after`,
-- `top`, or `at` for an edit/removal/move's own `before`).
local snippet = require("desk.snippet")

local M = {}

local MIN_QUOTE_LEN = 3

local function is_blank(line)
	return line:match("^%s*$") ~= nil
end

-- Column 0: the line's first character is not whitespace. An empty line is
-- not column-0 (it's blank, handled separately).
local function is_col0(line)
	return line ~= "" and line:match("^%S") ~= nil
end

-- No letters or digits anywhere on the line: a separator like the user's "———".
local function is_separator(line)
	return line:match("[%a%d]") == nil
end

-- A column-0 line whose content (after only whitespace) opens with a list
-- dash (a block whose head isn't a dash line is followed by column-0 `- ` lines).
local function is_dash_line(line)
	return line:match("^%-%s") ~= nil or line:match("^%-$") ~= nil
end

--- The 1-indexed inclusive end line of the block that starts at `start_idx`
--- (which the caller already knows is a block start).
function M.block_end(lines, start_idx)
	local n = #lines
	local head_is_dash = is_dash_line(lines[start_idx])
	local i = start_idx + 1
	while i <= n do
		local line = lines[i]
		if is_blank(line) then
			return i - 1
		end
		if is_col0(line) then
			if is_separator(line) then
				return i - 1
			end
			if (not head_is_dash) and is_dash_line(line) then
				i = i + 1 -- still part of the block: a following dash line
			else
				return i - 1
			end
		else
			i = i + 1 -- more-indented: still part of the block
		end
	end
	return n
end

--- The 1-indexed inclusive (start, end) of the block containing `idx`,
--- whether or not `idx` is itself the block's first line.
function M.block_containing(lines, idx)
	local start = idx
	while start > 1 and not is_col0(lines[start]) do
		start = start - 1
	end
	return start, M.block_end(lines, start)
end

--- Whether line `i` of `lines` heads a section: a column-0 line that is not
--- a bullet, or is one with indented lines under it (a session's section).
--- A column-0 bullet with nothing under it belongs to the heading above it.
function M.is_heading(lines, i)
	local l = lines[i]
	if not (l and l:match("^%S")) then
		return false
	end
	local bullet = l:match("^[-*+]%s") or l:match("^%d+[.)]%s")
	return not bullet or (lines[i + 1] ~= nil and lines[i + 1]:match("^%s+%S") ~= nil)
end

--- The first line index (1-indexed) whose content equals `quote` exactly
--- (plain comparison, never a pattern), or nil if it's too short to trust
--- or doesn't appear. Ambiguity (more than one exact match) resolves to the
--- first — a genuinely repeated heading-less line is rare.
function M.find_line(lines, quote)
	if not quote or #quote < MIN_QUOTE_LEN then
		return nil
	end
	for i, line in ipairs(lines) do
		if line == quote then
			return i
		end
	end
	return nil
end

--- Parses one wire-shape anchor — the string `"top"`, or a single-key table `{under=...}` |
--- `{after=...}` | `{at=...}` — into this module's internal `{kind=...,
--- quote=...}` shape. Returns nil for anything else (an invalid anchor).
function M.parse_anchor(t)
	if t == "top" then
		return { kind = "top" }
	end
	if type(t) ~= "table" then
		return nil
	end
	if t.under ~= nil then
		return { kind = "under", quote = t.under }
	end
	if t.after ~= nil then
		return { kind = "after", quote = t.after }
	end
	if t.at ~= nil then
		return { kind = "at", quote = t.at }
	end
	return nil
end

--- Parses a proposal item's `target` field (or a ledger item's `anchor`,
--- which carries the same shape): a single anchor for most kinds, or —
--- for `merge`/`move` — a two-element list `[{"at": "<before's first
--- line>"}, <where after lands>]`.
--- Returns leave_anchor, land_anchor; for a single (non-list) target both
--- are the same parsed anchor, since there is only one location.
function M.parse_target(target)
	if type(target) == "table" and target[1] ~= nil and target[2] ~= nil then
		return M.parse_anchor(target[1]), M.parse_anchor(target[2])
	end
	local anchor = M.parse_anchor(target)
	return anchor, anchor
end

--- Resolves an anchor { kind = "top" | "under" | "after" | "at", quote =
--- string|nil } against `lines` (the committed/index text) to a 0-indexed
--- insertion line (nvim buffer convention: new content goes in starting at
--- this line, pushing whatever was there down). `kind = "at"` is for an
--- edit, removal, or a move's leaving side, whose anchor is its own
--- `before`'s first line — the return is the start of that line itself,
--- not the end of its block.
---
--- Returns nil when the anchor can't be resolved (a bad quote, or one that
--- doesn't appear) — the caller puts the item on top
--- and counts it.
---
--- `before` (an `at` anchor's own lines) stands in for a quote too short or
--- blank to search on, such as a line `ok`: the first place those lines sit
--- together, nil when they don't.
function M.find_anchor(lines, anchor, before)
	if not anchor or anchor.kind == "top" then
		return 0
	end
	if anchor.kind == "at" and before and #before > 0 then
		local q = anchor.quote
		if type(q) ~= "string" or #q < MIN_QUOTE_LEN or is_blank(q) then
			for pos = 1, #lines - #before + 1 do
				if snippet.lines_match_at(lines, pos, before) then
					return pos - 1
				end
			end
			return nil
		end
	end
	local idx = M.find_line(lines, anchor.quote)
	if not idx then
		return nil
	end
	if anchor.kind == "at" then
		return idx - 1
	end
	if anchor.kind == "under" then
		local _, e = idx, M.block_end(lines, idx)
		return e
	end
	if anchor.kind == "after" then
		local _, e = M.block_containing(lines, idx)
		return e
	end
	return nil
end

--- Resolves an after-shaped anchor — a plain single-location item's own
--- (add/edit/new/link), or a move/merge's landing side — against `lines`,
--- falling back to the top of the file (position 0, "fell_back" true) when
--- the anchor is present but can't be resolved at all (its quote is gone).
--- Never for a before-shaped leave/removal anchor: its absence is a
--- genuine content conflict (the user's edits sit where the suggestion expected
--- to find its own `before`), which a caller keeps deferred instead —
--- that distinction is the caller's own to make, not this function's.
---
--- A missing anchor entirely (nil — malformed data, not "unresolvable")
--- still returns nil, fell_back=false: inventing a landing spot for
--- something with no anchor at all would paper over a real data problem
--- rather than the "the quote used to be there, now it isn't" case this
--- exists for.
function M.find_after_anchor(lines, anchor)
	if not anchor then
		return nil, false
	end
	local pos = M.find_anchor(lines, anchor)
	if pos == nil then
		return 0, true
	end
	return pos, false
end

return M
