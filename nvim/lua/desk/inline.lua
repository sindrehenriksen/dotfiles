-- The review's one window: the notes buffer itself, decorated. A
-- suggestion's new lines are drawn as virtual lines, tinted, with its
-- headline on the first; the lines it would remove or replace stay real
-- lines, highlighted and struck through. Which suggestion owns which lines
-- is desk.review's to say (view_draw); this draws what it is given, with
-- extmarks only, from scratch on every change of the notes.
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

--- Draws `view` over `buf`: `blocks` { row, above, lines, labels } of new
--- lines, drawn under `row` (above it with `above`), `labels` line index ->
--- the headline of the suggestion whose lines start there, `struck` { first,
--- last, label } runs of real lines a suggestion would remove, and `width`
--- the window's text width the new lines wrap to.
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
			for j, piece in ipairs(M.wrap(line, view.width)) do
				virt[#virt + 1] = { { piece, "DeskInlineNew" } }
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
