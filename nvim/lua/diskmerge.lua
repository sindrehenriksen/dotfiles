-- A file that changed on disk while its buffer has unsaved edits opens as a
-- merge rather than nvim's W12 prompt, which offers only keeping the buffer
-- or loading the file and so loses one side either way. The disk version
-- goes in a read-only scratch split above the buffer, both in diff mode,
-- the cursor staying in the buffer: `do` there or `dp` from above takes a
-- hunk of theirs, `:w` saves the result, and closing the split leaves the
-- buffer as merged.
--
-- Hooked on FileChangedShell, so checktime (autocmds.lua) still decides
-- when to look. Everything but a content change under unsaved edits gets
-- nvim's own handling back through v:fcs_choice "ask": a deleted file, a
-- mode change, and an unmodified buffer, which 'autoread' reloads without
-- calling this at all.
local M = {}

M.BAR = "n/N next · do take theirs (in your buffer) · dp from above · :w save mine merged · q close"

local KEYS = { "n", "N", "q" }

local merges = {} -- user bufnr -> { scratch, win, maps }
local pending = {} -- user bufnr -> { said = nil | "review" | "window" }

local function hash(lines)
	return vim.fn.sha256(table.concat(lines, "\n"))
end

--- The file's lines as the buffer would read them, or nil when it is gone.
function M.read_disk(buf)
	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" or vim.fn.filereadable(path) == 0 then
		return nil
	end
	local lines = vim.fn.readfile(path)
	if vim.bo[buf].fileformat == "dos" then
		for i, l in ipairs(lines) do
			lines[i] = l:gsub("\r$", "")
		end
	end
	return lines
end

local function name(buf)
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

-- Whether `lnum` of the current window is where diff motion lands on a
-- change: a changed line, below a filler, or the last line over a filler.
local function at_change(lnum)
	if vim.fn.diff_hlID(lnum, 1) ~= 0 or vim.fn.diff_filler(lnum) > 0 then
		return true
	end
	return lnum == vim.api.nvim_buf_line_count(0) and vim.fn.diff_filler(lnum + 1) > 0
end

--- `]c` (`forward`) or `[c`, wrapping around at either end. From an end of
--- the buffer one step and one back lands on the first (last) change even
--- when it starts on that very line, which plain `]c` from line 1 skips.
function M.next_hunk(forward)
	local win = vim.api.nvim_get_current_win()
	local before = vim.api.nvim_win_get_cursor(win)
	local there, back = forward and "]c" or "[c", forward and "[c" or "]c"
	pcall(vim.cmd, "normal! " .. vim.v.count1 .. there)
	if not vim.deep_equal(before, vim.api.nvim_win_get_cursor(win)) then
		return
	end
	vim.api.nvim_win_set_cursor(win, { forward and 1 or vim.api.nvim_buf_line_count(0), 0 })
	pcall(vim.cmd, "normal! " .. there)
	pcall(vim.cmd, "normal! " .. back)
	if not at_change(vim.api.nvim_win_get_cursor(win)[1]) then
		vim.api.nvim_win_set_cursor(win, before)
		vim.notify("no differences left", vim.log.levels.INFO)
		return
	end
	vim.notify(forward and "wrapped to the first difference" or "wrapped to the last difference", vim.log.levels.INFO)
end

-- `n`/`N` stay the search's own while a search is highlighted.
local function map_keys(buf, user_buf)
	for lhs, forward in pairs({ n = true, N = false }) do
		vim.keymap.set("n", lhs, function()
			if vim.o.hlsearch and vim.v.hlsearch == 1 and vim.fn.getreg("/") ~= "" then
				return lhs
			end
			return string.format("<Cmd>lua require('diskmerge').next_hunk(%s)<CR>", tostring(forward))
		end, { buffer = buf, expr = true, desc = "Disk merge: next/previous difference" })
	end
	vim.keymap.set("n", "q", function()
		M.close(user_buf)
	end, { buffer = buf, desc = "Disk merge: close, keeping the buffer as merged" })
end

-- The user's own buffer-local mappings of KEYS, to put back on close.
local function save_maps(buf)
	return vim.api.nvim_buf_call(buf, function()
		local saved = {}
		for _, lhs in ipairs(KEYS) do
			local m = vim.fn.maparg(lhs, "n", false, true)
			if m.buffer == 1 then
				saved[#saved + 1] = m
			end
		end
		return saved
	end)
end

local function restore_maps(buf, saved)
	for _, lhs in ipairs(KEYS) do
		pcall(vim.keymap.del, "n", lhs, { buffer = buf })
	end
	vim.api.nvim_buf_call(buf, function()
		for _, m in ipairs(saved) do
			vim.fn.mapset("n", false, m)
		end
	end)
end

--- Closes the merge on `buf`: the scratch split goes, the buffer's window
--- leaves diff mode, and the buffer keeps whatever was taken into it.
function M.close(buf)
	local m = merges[buf]
	if not m then
		return
	end
	merges[buf] = nil
	if vim.api.nvim_buf_is_valid(buf) then
		restore_maps(buf, m.maps)
	end
	if vim.api.nvim_win_is_valid(m.win) and vim.api.nvim_win_get_buf(m.win) == buf then
		vim.api.nvim_win_call(m.win, function()
			vim.cmd("diffoff")
		end)
	end
	if vim.api.nvim_buf_is_valid(m.scratch) then
		pcall(vim.api.nvim_buf_delete, m.scratch, { force = true })
	end
end

--- The scratch split's buffer while a merge is open on `buf`, else nil.
function M.scratch_for(buf)
	local m = merges[buf]
	return m and vim.api.nvim_buf_is_valid(m.scratch) and m.scratch or nil
end

local function set_scratch_lines(scratch, lines)
	vim.bo[scratch].modifiable = true
	vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
	vim.bo[scratch].modifiable = false
	vim.bo[scratch].modified = false
end

-- Without this the first `:w` after a merge stops on "changed since reading
-- it": nvim keeps the read time apart from the timestamp the event updates,
-- and nothing short of reloading the file moves it. So that one write runs
-- as `:w!`, the merge having shown what is on disk. Once, then ordinary
-- writes again, nested so the usual write autocommands still run.
local function write_past_mtime_check(buf)
	local group = vim.api.nvim_create_augroup("diskmerge_write_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		nested = true,
		callback = function(args)
			vim.api.nvim_clear_autocmds({ group = group })
			if vim.bo[buf].readonly and vim.v.cmdbang == 0 then
				vim.notify("E45: 'readonly' option is set (add ! to override)", vim.log.levels.ERROR)
				write_past_mtime_check(buf)
				return
			end
			local function full(f)
				return vim.fn.resolve(vim.fn.fnamemodify(f, ":p"))
			end
			local own = full(args.file) == full(vim.api.nvim_buf_get_name(buf))
			vim.api.nvim_buf_call(buf, function()
				if own then
					vim.cmd("write!")
				else
					vim.cmd((vim.v.cmdbang == 1 and "write! " or "write ") .. vim.fn.fnameescape(args.file))
					write_past_mtime_check(buf)
				end
			end)
		end,
	})
end

local function open(buf, win, disk)
	local scratch = vim.api.nvim_create_buf(false, true)
	vim.bo[scratch].buftype = "nofile"
	vim.bo[scratch].bufhidden = "wipe"
	vim.bo[scratch].swapfile = false
	vim.bo[scratch].modeline = false
	pcall(vim.api.nvim_buf_set_name, scratch, "disk://" .. vim.api.nvim_buf_get_name(buf))
	vim.bo[scratch].filetype = vim.bo[buf].filetype
	set_scratch_lines(scratch, disk)
	vim.bo[scratch].readonly = true

	vim.api.nvim_set_current_win(win)
	vim.cmd("aboveleft split")
	local swin = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(swin, scratch)
	local function bar_text(t)
		return (t:gsub("%%", "%%%%"))
	end
	vim.wo[swin].winbar = bar_text(M.BAR) .. "%=" .. bar_text("on disk: " .. name(buf))
	vim.api.nvim_win_call(swin, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_set_current_win(win)

	local m = { scratch = scratch, win = win, maps = save_maps(buf) }
	merges[buf] = m
	map_keys(buf, buf)
	map_keys(scratch, buf)
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = scratch,
		once = true,
		callback = function()
			vim.schedule(function()
				if merges[buf] == m then
					M.close(buf)
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			vim.schedule(function()
				if merges[buf] == m then
					M.close(buf)
				end
			end)
		end,
	})
end

local function window_for(buf)
	if vim.api.nvim_get_current_buf() == buf then
		return vim.api.nvim_get_current_win()
	end
	local win = vim.fn.bufwinid(buf)
	return win ~= -1 and win or nil
end

local function wait(buf, why, msg)
	if pending[buf].said ~= why then
		pending[buf].said = why
		vim.notify(name(buf) .. " changed on disk under your edits: " .. msg, vim.log.levels.INFO)
	end
end

--- Opens the merge for a pending `buf` once it can: after a desk review
--- open on it ends, since a third diff window would leave `do` with two
--- buffers to take from, and once the buffer shows in a window here.
function M.try_open(buf)
	if not pending[buf] then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		pending[buf] = nil
		return
	end
	local ok, review = pcall(require, "desk.review")
	local review_buf = ok and review.open_review_buf and review.open_review_buf(buf)
	if review_buf then
		if pending[buf].said ~= "review" then
			vim.api.nvim_create_autocmd("BufWipeout", {
				buffer = review_buf,
				once = true,
				callback = function()
					vim.schedule(function()
						M.try_open(buf)
					end)
				end,
			})
		end
		wait(buf, "review", "the merge opens when the desk review ends")
		return
	end
	local win = window_for(buf)
	if not win then
		wait(buf, "window", "the merge opens when you show it")
		return
	end
	pending[buf] = nil
	local disk = M.read_disk(buf)
	if not disk then
		vim.notify(name(buf) .. " is gone from disk; nothing to merge", vim.log.levels.WARN)
		return
	end
	vim.b[buf].diskmerge_seen = hash(disk)
	write_past_mtime_check(buf)
	local scratch = M.scratch_for(buf)
	if scratch then
		set_scratch_lines(scratch, disk)
		vim.api.nvim_win_call(win, function()
			vim.cmd("diffupdate")
		end)
		vim.notify(name(buf) .. " changed on disk again: the split above shows it now", vim.log.levels.INFO)
		return
	end
	open(buf, win, disk)
	vim.notify(name(buf) .. " changed on disk under your edits: theirs is in the split above", vim.log.levels.INFO)
end

function M.on_changed(buf)
	if vim.v.fcs_reason ~= "conflict" then
		vim.v.fcs_choice = "ask"
		return
	end
	local disk = M.read_disk(buf)
	if not disk then
		vim.v.fcs_choice = "ask"
		return
	end
	if vim.deep_equal(disk, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
		vim.v.fcs_choice = "reload"
		return
	end
	vim.v.fcs_choice = ""
	-- "conflict" is also a timestamp or mode change: with the content as
	-- last read, theirs is the buffer's own past and there is nothing to take.
	if hash(disk) == vim.b[buf].diskmerge_seen then
		return
	end
	pending[buf] = pending[buf] or {}
	-- The event may not change windows or buffers.
	vim.schedule(function()
		M.try_open(buf)
	end)
end

function M.setup()
	local group = vim.api.nvim_create_augroup("diskmerge", { clear = true })
	vim.api.nvim_create_autocmd("FileChangedShell", {
		group = group,
		callback = function(args)
			M.on_changed(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		callback = function(args)
			if vim.bo[args.buf].buftype == "" then
				vim.b[args.buf].diskmerge_seen = hash(vim.api.nvim_buf_get_lines(args.buf, 0, -1, false))
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = group,
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if pending[buf] then
				vim.schedule(function()
					M.try_open(buf)
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			local buf = args.buf
			pending[buf] = nil
			if merges[buf] then
				vim.schedule(function()
					M.close(buf)
				end)
			end
		end,
	})
end

return M
