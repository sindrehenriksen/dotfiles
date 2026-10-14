-- Auto-save for the notes files only: a notes buffer with unsaved edits is
-- written on InsertLeave, on BufLeave and when nvim loses focus. Never over
-- a change on disk: each save first runs checktime, so the disk merge
-- (diskmerge.lua) gets its say, and writes only when the file on disk is
-- still what this buffer last read or wrote, and no merge is pending or
-- open. A desk pass or session that wrote the file meanwhile is merged with,
-- never overwritten.
--
-- It pauses while a desk review in two windows is open on the buffer: a
-- save there records the review's takes (review.lua, flush_taken), and a
-- take undone after that would stay recorded. The review's own close keys
-- save instead. The one-window review, where the user types in the notes
-- themselves, does not pause it; its saves hold the takes until it ends.
local M = {}

local function hash(lines)
	return vim.fn.sha256(table.concat(lines, "\n"))
end

local function name(buf)
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

local function read_disk(buf)
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

local function diskmerge()
	local ok, dm = pcall(require, "diskmerge")
	return ok and dm or nil
end

local function remember_disk(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.b[buf].desk_autosave_disk = hash(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end
end

--- True for a buffer desk treats as a notes file (review.attach marked it).
function M.is_notes(buf)
	return vim.api.nvim_buf_is_valid(buf) and vim.b[buf].desk_attached == true and vim.bo[buf].buftype == ""
end

--- Whether notes buffer `buf` may be written now: true when it may (or has
--- nothing to write), else false and why, in a line. Runs checktime first,
--- so a change on disk is seen before it is judged. `opts.known`: the caller
--- knows it is a notes file (the review loads the other one without showing
--- it, so it may not be attached yet).
function M.check(buf, opts)
	local notes = opts and opts.known and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" or M.is_notes(buf)
	if not (notes and vim.api.nvim_buf_is_loaded(buf)) then
		return false, "not a notes file"
	end
	if not vim.bo[buf].modified then
		return true
	end
	if vim.bo[buf].readonly or not vim.bo[buf].modifiable then
		return false, name(buf) .. " is read-only"
	end
	pcall(vim.cmd, "checktime " .. buf)
	if not vim.bo[buf].modified then
		return true
	end
	local dm = diskmerge()
	if dm and dm.conflict and dm.conflict(buf) then
		return false, name(buf) .. " changed on disk: not saved until it is merged (in the merge split, :w saves the merge and q ends it)"
	end
	local disk = read_disk(buf)
	if not disk then
		return false, name(buf) .. " is gone from disk: not saved"
	end
	-- The disk merge's own record counts too: once it has shown theirs,
	-- the buffer is the merged result and may go over it.
	local known = vim.b[buf].desk_autosave_disk
	local h = hash(disk)
	if known and h ~= known and h ~= vim.b[buf].diskmerge_seen then
		return false, name(buf) .. " changed on disk: not saved until it is merged"
	end
	return true
end

--- Saves notes buffer `buf` when that is safe (M.check). Returns true when
--- it was written or had nothing to write, else false and why, in a line.
function M.save(buf, opts)
	local ok, why = M.check(buf, opts)
	if not ok or not vim.bo[buf].modified then
		return ok, why
	end
	-- `write!`: the file is what this buffer last saw, so a changed
	-- timestamp alone is no reason to stop on nvim's changed-since-reading
	-- prompt.
	local wrote, err = pcall(vim.api.nvim_buf_call, buf, function()
		vim.cmd("silent write!")
	end)
	if not wrote then
		return false, string.format("couldn't save %s: %s", name(buf), (tostring(err):gsub("^Vim:", "")))
	end
	return true
end

--- Saves every notes buffer with unsaved edits, as M.save does. Returns
--- the names it wrote and the reasons it left any.
function M.save_all(except)
	local wrote, left = {}, {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if not (except and except[b]) and M.is_notes(b) and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
			local ok, why = M.save(b)
			if ok then
				wrote[#wrote + 1] = name(b)
			else
				left[#left + 1] = why
			end
		end
	end
	table.sort(wrote)
	return wrote, left
end

-- A review in two windows pauses auto-save; the one window, where the notes
-- are what the user types in, does not (its takes wait for its end).
local function reviewing(buf)
	local ok, review = pcall(require, "desk.review")
	if not (ok and review.open_review_buf and review.open_review_buf(buf) ~= nil) then
		return false
	end
	local s = review.session_of and review.session_of(buf)
	return not (s and s.inline)
end

--- One automatic save of `buf`. A save it holds back is said once until the
--- reason changes, since the events come often.
function M.auto(buf)
	if not M.is_notes(buf) or not vim.bo[buf].modified or reviewing(buf) then
		return
	end
	local ok, why = M.save(buf)
	if ok then
		vim.b[buf].desk_autosave_said = nil
	elseif vim.b[buf].desk_autosave_said ~= why then
		vim.b[buf].desk_autosave_said = why
		vim.notify("desk: " .. why, vim.log.levels.WARN)
	end
end

local focus_installed = false

--- Records what each file named like a notes file held when it was read or
--- written, before any buffer is attached: one the review loads unseen and
--- takes into is modified by the time it is shown and attached, and its
--- read is the only moment its disk content was known. Safe to call again.
function M.setup(patterns)
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "FileChangedShellPost" }, {
		group = vim.api.nvim_create_augroup("desk_autosave_disk", { clear = true }),
		pattern = patterns,
		callback = function(args)
			if vim.bo[args.buf].buftype == "" then
				remember_disk(args.buf)
			end
		end,
	})
end

--- Turns auto-save on for notes buffer `buf`. Safe to call again.
function M.attach(buf)
	if vim.b[buf].desk_autosave then
		return
	end
	vim.b[buf].desk_autosave = true
	-- A buffer read before M.setup's autocmds existed has no record of
	-- what it read; unmodified, it still holds it.
	if vim.b[buf].desk_autosave_disk == nil and not vim.bo[buf].modified then
		remember_disk(buf)
	end
	local group = vim.api.nvim_create_augroup("desk_autosave_" .. buf, { clear = true })
	-- After the event: a save inside it would run the write's own autocmds
	-- unnested, and BufLeave fires in the middle of window changes.
	vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			vim.schedule(function()
				M.auto(buf)
			end)
		end,
	})
	if not focus_installed then
		focus_installed = true
		vim.api.nvim_create_autocmd("FocusLost", {
			group = vim.api.nvim_create_augroup("desk_autosave_focus", { clear = true }),
			callback = function()
				vim.schedule(function()
					for _, b in ipairs(vim.api.nvim_list_bufs()) do
						if vim.b[b].desk_autosave then
							M.auto(b)
						end
					end
				end)
			end,
		})
	end
end

return M
