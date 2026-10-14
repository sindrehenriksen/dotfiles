-- The review's one-window view: the merged text (the user's notes with
-- every open suggestion in place) in a single window, against the notes
-- buffer that stays loaded behind it. Each line a hunk of (notes -> review)
-- brings in is highlighted, and the lines a suggestion removes or rewrites
-- are drawn as virtual lines, dimmed and struck through: an edit's directly
-- above its own new line, a removal's hanging where it takes them with its
-- headline. Which suggestion owns which lines is desk.review's to say
-- (render_inline); this draws what it is given, with extmarks only, from
-- scratch on every refresh, so nothing here is state a take or decline has
-- to keep in step.
local snippet = require("desk.snippet")

local M = {}

M.NS = vim.api.nvim_create_namespace("desk_review_inline")

--- The hunks of (`notes` -> `review`) as vim.diff's indices:
--- { notes_start, notes_count, review_start, review_count }, a zero count's
--- start being the line before the change (0 at the top).
function M.hunks(notes, review)
	return vim.diff(snippet.join_lines(notes, true), snippet.join_lines(review, true), { result_type = "indices" })
end

--- The review row a hunk is acted on from: its first new line, or for a
--- removal alone the line its removed lines hang under (1 at the top).
function M.row(h)
	if h[4] > 0 then
		return h[3]
	end
	return math.max(h[3], 1)
end

--- The hunk the cursor on review row `line` names: one whose new lines hold
--- it, else a removal alone hanging between `line` and the row above, else
--- one hanging under `line` itself. nil when none.
function M.hunk_at(hunks, line)
	for _, h in ipairs(hunks) do
		if h[4] > 0 and line >= h[3] and line <= h[3] + h[4] - 1 then
			return h
		end
	end
	for _, h in ipairs(hunks) do
		if h[4] == 0 and h[3] + 1 == line then
			return h
		end
	end
	for _, h in ipairs(hunks) do
		if h[4] == 0 and h[3] == line then
			return h
		end
	end
end

--- The hunks with any line in review rows `first`..`last`, removals alone
--- hanging inside or at the edges of that range included.
function M.hunks_in(hunks, first, last)
	local out = {}
	for _, h in ipairs(hunks) do
		if h[4] > 0 then
			if h[3] <= last and h[3] + h[4] - 1 >= first then
				out[#out + 1] = h
			end
		elseif h[3] >= first - 1 and h[3] <= last then
			out[#out + 1] = h
		end
	end
	return out
end

-- `text` cut into pieces of at most `width` display cells, at a space where
-- one is in the second half of a piece, so a long removed line reads whole
-- under a wrapped window rather than running off its edge (virtual lines
-- never wrap). One pass over the characters.
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

--- Draws the view on `review_buf` (`total` lines) from `view`:
--- `new_rows` { row, changed } for each line a hunk brings in, `blocks`
--- { row, above, lines, label } for each run of removed or rewritten lines
--- (drawn above `row`, or hanging under it, struck, `label` on the first),
--- `labels` row -> headline beside a suggestion's first new line, and
--- `width` the window's text width that removed lines wrap to.
function M.render(review_buf, total, view)
	vim.api.nvim_buf_clear_namespace(review_buf, M.NS, 0, -1)
	for _, n in ipairs(view.new_rows) do
		if n.row >= 1 and n.row <= total then
			vim.api.nvim_buf_set_extmark(review_buf, M.NS, n.row - 1, 0, {
				line_hl_group = "DeskInlineNew",
				sign_text = n.changed and "~" or "+",
				sign_hl_group = "DeskInlineSign",
				priority = 100,
			})
		end
	end
	for _, b in ipairs(view.blocks) do
		local virt = {}
		for _, line in ipairs(b.lines) do
			for _, piece in ipairs(M.wrap(line, view.width)) do
				virt[#virt + 1] = { { piece, "DeskInlineOld" } }
			end
		end
		if #virt > 0 then
			if b.label then
				table.insert(virt[1], { "  « " .. b.label, "DeskInlineLabel" })
			end
			vim.api.nvim_buf_set_extmark(review_buf, M.NS, b.row - 1, 0, { virt_lines = virt, virt_lines_above = b.above })
		end
	end
	for row, label in pairs(view.labels) do
		if row >= 1 and row <= total then
			vim.api.nvim_buf_set_extmark(review_buf, M.NS, row - 1, 0, {
				virt_text = { { "  « " .. label, "DeskInlineLabel" } },
				virt_text_pos = "eol",
			})
		end
	end
end

function M.clear(review_buf)
	if vim.api.nvim_buf_is_valid(review_buf) then
		vim.api.nvim_buf_clear_namespace(review_buf, M.NS, 0, -1)
	end
end

return M
