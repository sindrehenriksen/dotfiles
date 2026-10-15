-- The review's one window: the notes buffer itself, decorated. A
-- suggestion's new lines are drawn as virtual lines, tinted, with its
-- headline on the first; the lines it would remove or replace stay real
-- lines, tinted red ("struck" in the code, a name kept from when they were
-- struck through). Where an edit replaces a line, the words that change
-- are marked more strongly in both the old line and the new one. Which suggestion owns which lines is desk.review's to say
-- (view_draw); this draws what it is given, with extmarks only, from
-- scratch on every change of the notes.
local snippet = require("desk.snippet")

local M = {}

M.NS = vim.api.nvim_create_namespace("desk_review_inline")

--- The hunks of (`a` -> `b`) as vim.diff's indices:
--- { a_start, a_count, b_start, b_count }, a zero count's start being the
--- line before the change (0 at the top).
function M.hunks(a, b)
	return vim.diff(snippet.join_lines(a, true), snippet.join_lines(b, true), { result_type = "indices" })
end

-- `text` cut into pieces of at most `width` display cells, at a space where
-- one is in the second half of a piece, so a long new line reads whole
-- (virtual lines never wrap). One pass over the characters.
function M.wrap(text, width)
	if width < 10 or vim.fn.strdisplaywidth(text) <= width then
		return { text }
	end
	local out, piece, cells, space = {}, {}, 0, nil
	for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
		local w = vim.fn.strdisplaywidth(ch)
		if cells + w > width and #piece > 0 then
			local cut = (space and space > #piece / 2) and space or #piece
			out[#out + 1] = table.concat(piece, "", 1, cut)
			piece = { unpack(piece, cut + 1) }
			cells = vim.fn.strdisplaywidth(table.concat(piece))
			space = nil
			for i, c in ipairs(piece) do
				if c:match("^%s$") then
					space = i
				end
			end
		end
		piece[#piece + 1] = ch
		cells = cells + w
		if ch:match("^%s$") then
			space = #piece
		end
	end
	out[#out + 1] = table.concat(piece)
	return out
end

-- A line cut into words, runs of spaces and single other characters, each
-- with its byte offset. Bytes past ASCII count as word characters, so a
-- word with letters such as æ, ø or å stays one word.
local function tokens(line)
	local out, i = {}, 1
	while i <= #line do
		local _, e = line:find("^[%w_\128-\255]+", i)
		if not e then
			_, e = line:find("^%s+", i)
		end
		e = e or i
		out[#out + 1] = { text = line:sub(i, e), from = i - 1 }
		i = e + 1
	end
	return out
end

--- Which lines of `new` replace which of `old`, as { old index, new index }
--- pairs: lines the diff of the two (with linematch, so similar lines
--- line up) changes in one hunk, paired in order. A line only added or
--- only removed has no pair.
function M.pair_lines(old, new)
	local pairs_ = {}
	local hunks = vim.diff(snippet.join_lines(old, true), snippet.join_lines(new, true), { result_type = "indices", linematch = 40 })
	for _, h in ipairs(hunks) do
		for k = 0, math.min(h[2], h[4]) - 1 do
			pairs_[#pairs_ + 1] = { h[1] + k, h[3] + k }
		end
	end
	return pairs_
end

--- The parts of `a` and `b` that differ, word by word, as lists of
--- { from, to } byte ranges (0-based, `to` exclusive), adjacent ones joined;
--- nil when the two have no word in common, since marking every word of a
--- rewritten line says nothing the tint does not.
function M.word_changes(a, b)
	local ta, tb = tokens(a), tokens(b)
	local function texts(t)
		local out = {}
		for i, tok in ipairs(t) do
			out[i] = tok.text
		end
		return out
	end
	local hunks = vim.diff(snippet.join_lines(texts(ta), true), snippet.join_lines(texts(tb), true), { result_type = "indices" })
	local changed_a, changed_b = {}, {}
	for _, h in ipairs(hunks) do
		for k = h[1], h[1] + h[2] - 1 do
			changed_a[k] = true
		end
		for k = h[3], h[3] + h[4] - 1 do
			changed_b[k] = true
		end
	end
	local common = false
	for i, tok in ipairs(ta) do
		if not changed_a[i] and tok.text:match("%S") then
			common = true
			break
		end
	end
	if not common then
		return nil
	end
	local function ranges(t, changed)
		local out = {}
		for i, tok in ipairs(t) do
			if changed[i] then
				local last = out[#out]
				if last and last[2] == tok.from then
					last[2] = tok.from + #tok.text
				else
					out[#out + 1] = { tok.from, tok.from + #tok.text }
				end
			end
		end
		return out
	end
	return ranges(ta, changed_a), ranges(tb, changed_b)
end

-- The virtual-text chunks of `piece`, the part of a new line from byte
-- `offset` on, its changed `ranges` in the stronger tint.
local function chunks(piece, offset, ranges)
	local out, at = {}, 0
	for _, r in ipairs(ranges or {}) do
		local from, to = math.max(r[1] - offset, at), math.min(r[2] - offset, #piece)
		if from < to then
			if from > at then
				out[#out + 1] = { piece:sub(at + 1, from), "DeskInlineNew" }
			end
			out[#out + 1] = { piece:sub(from + 1, to), "DeskInlineNewText" }
			at = to
		end
	end
	if at < #piece or #out == 0 then
		out[#out + 1] = { piece:sub(at + 1), "DeskInlineNew" }
	end
	return out
end

--- Draws `view` over `buf`: `blocks` { row, above, lines, labels } of new
--- lines, drawn under `row` (above it with `above`), `labels` line index ->
--- the headline of the suggestion whose lines start there, `struck` { first,
--- last, label } runs of real lines a suggestion would remove, and `width`
--- the window's text width the new lines wrap to. `old_words` (row ->
--- ranges) and a block's `words` (line index -> ranges) are the changed
--- parts of the lines an edit replaces and of its new lines
--- (M.word_changes).
function M.draw(buf, view)
	vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
	local total = vim.api.nvim_buf_line_count(buf)
	for _, run in ipairs(view.struck) do
		for row = run.first, math.min(run.last, total) do
			local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
			vim.api.nvim_buf_set_extmark(buf, M.NS, row - 1, 0, {
				end_col = #line,
				hl_group = "DeskInlineOld",
				line_hl_group = "DeskInlineOldLine",
				priority = 200,
			})
			for _, r in ipairs((view.old_words or {})[row] or {}) do
				if r[2] <= #line then
					vim.api.nvim_buf_set_extmark(buf, M.NS, row - 1, r[1], { end_col = r[2], hl_group = "DeskInlineOldText", priority = 210 })
				end
			end
		end
		if run.label and run.first <= total then
			vim.api.nvim_buf_set_extmark(buf, M.NS, run.first - 1, 0, {
				virt_text = { { "  « " .. run.label, "DeskInlineLabel" } },
				virt_text_pos = "eol",
			})
		end
	end
	for _, b in ipairs(view.blocks) do
		local virt = {}
		for i, line in ipairs(b.lines) do
			local offset = 0
			for j, piece in ipairs(M.wrap(line, view.width)) do
				virt[#virt + 1] = chunks(piece, offset, b.words and b.words[i])
				offset = offset + #piece
				local label = j == 1 and b.labels and b.labels[i]
				if label then
					table.insert(virt[#virt], { "  « " .. label, "DeskInlineLabel" })
				end
			end
		end
		if #virt > 0 then
			local row = math.max(1, math.min(b.row, total))
			vim.api.nvim_buf_set_extmark(buf, M.NS, row - 1, 0, { virt_lines = virt, virt_lines_above = b.above })
		end
	end
end

function M.clear(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
	end
end

return M
