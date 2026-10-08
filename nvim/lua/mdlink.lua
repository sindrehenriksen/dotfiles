-- `gx` for markdown: acts on the whole link under the cursor rather than
-- the word, which is what nvim's own gx sees in `[How it works](#how-it-works)`
-- ("works", handed to the system opener). A `#anchor` jumps to the heading
-- with that GitHub-style slug in this buffer, a relative path opens the
-- file (and its `#anchor`), anything with a scheme goes to vim.ui.open.
-- Outside a link it does what gx does, except that a bare word with neither
-- a scheme nor a dot is reported instead of opened.
local M = {}

--- Whether `target` is something for the system opener: it has a scheme,
--- or a dot as a host or file name does.
function M.openable(target)
	if target == nil or target == "" or target:match("%s") then
		return false
	end
	return target:match("^%a[%w+.-]*:") ~= nil or target:find(".", 1, true) ~= nil
end

--- The target of the link whose text contains 0-indexed byte column `col`
--- of `line`: an inline `[label](target "title")`, an autolink `<url>`, or
--- a bare `http(s)://` URL. nil when the cursor is on none.
function M.link_at(line, col)
	local pos = col + 1
	local init = 1
	while true do
		local s, e, target = line:find("%b[]%(([^)]*)%)", init)
		if not s then
			break
		end
		if pos >= s and pos <= e then
			target = vim.trim(target):gsub('%s+".*"$', ""):gsub("^<(.*)>$", "%1")
			return target
		end
		init = e + 1
	end
	for _, pat in ipairs({ "<(%a[%w+.-]*:[^>%s]+)>", "(https?://[^%s%)%]>]+)" }) do
		init = 1
		while true do
			local s, e, url = line:find(pat, init)
			if not s then
				break
			end
			if pos >= s and pos <= e then
				return (url:gsub("[.,;:!?]+$", "")) -- the sentence's, not the URL's
			end
			init = e + 1
		end
	end
end

--- A heading's anchor as GitHub writes it: lowercased, links reduced to
--- their text, everything but letters, digits, spaces, `-` and `_`
--- dropped, spaces turned into `-`.
function M.slug(text)
	local t = text:gsub("%[([^%]]*)%]%b()", "%1")
	t = vim.fn.tolower(t)
	t = t:gsub("[^%w%s_%-\128-\255]", "")
	return (vim.trim(t):gsub("%s", "-"))
end

--- The 1-indexed line of the heading in `lines` whose slug is `anchor`,
--- counting repeats as GitHub does (`name`, `name-1`, …) and skipping
--- fenced code. nil when there is none.
function M.find_heading(lines, anchor)
	anchor = vim.fn.tolower(anchor)
	local seen, fenced = {}, false
	for i, l in ipairs(lines) do
		if l:match("^%s*```") or l:match("^%s*~~~") then
			fenced = not fenced
		elseif not fenced then
			local text = l:match("^#+%s+(.-)%s*#*%s*$")
			if text then
				local slug = M.slug(text)
				local n = seen[slug]
				seen[slug] = (n or -1) + 1
				local key = n and (slug .. "-" .. (n + 1)) or slug
				if key == anchor then
					return i
				end
			end
		end
	end
end

local function jump_to(win, line)
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! m'")
	end)
	vim.api.nvim_win_set_cursor(win, { line, 0 })
end

-- The default actions, replaceable in a test.
M.deps = {
	open = function(target)
		return vim.ui.open(target)
	end,
	edit = function(path)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
	end,
	notify = function(msg)
		vim.notify(msg, vim.log.levels.WARN)
	end,
}

--- Follows link `target` from buffer `bufnr` shown in window `win`.
function M.follow(target, bufnr, win)
	local d = M.deps
	if target == "" then
		return d.notify("empty link")
	end
	local anchor = target:match("^#(.+)$")
	if anchor then
		local line = M.find_heading(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), anchor)
		if not line then
			return d.notify("no heading #" .. anchor .. " here")
		end
		return jump_to(win, line)
	end
	if target:match("^%a[%w+.-]*:") then
		return d.open(target)
	end
	local path, frag = target:match("^([^#]*)#(.*)$")
	path = path or target
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
	local full = path:sub(1, 1) == "/" and path or vim.fs.normalize(dir .. "/" .. path)
	if not vim.uv.fs_stat(full) then
		return d.notify("no file " .. path)
	end
	d.edit(full)
	if frag and frag ~= "" then
		local cur = vim.api.nvim_get_current_buf()
		local line = M.find_heading(vim.api.nvim_buf_get_lines(cur, 0, -1, false), frag)
		if line then
			jump_to(vim.api.nvim_get_current_win(), line)
		else
			d.notify("no heading #" .. frag .. " in " .. path)
		end
	end
end

--- Follows the link under the cursor of `win`; false when there is none.
function M.follow_at(bufnr, win)
	local row, col = unpack(vim.api.nvim_win_get_cursor(win))
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local target = M.link_at(line, col)
	if not target then
		return false
	end
	M.follow(target, bufnr, win)
	return true
end

--- `gx`: the link under the cursor, else what nvim's gx finds there,
--- never a bare word.
function M.gx()
	local bufnr, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	if M.follow_at(bufnr, win) then
		return
	end
	local ok, urls = pcall(vim.ui._get_urls)
	if not ok or type(urls) ~= "table" then
		urls = { vim.fn.expand("<cfile>") }
	end
	for _, url in ipairs(urls) do
		if M.openable(url) then
			M.deps.open(url)
		else
			M.deps.notify("'" .. url .. "' is not a link")
		end
	end
end

function M.attach(bufnr)
	vim.keymap.set("n", "gx", M.gx, { buffer = bufnr, desc = "Open the markdown link under the cursor" })
end

return M
