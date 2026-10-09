-- The disk merge (nvim/lua/diskmerge.lua), headless against temp files: a
-- file changed on disk under unsaved edits opens the disk version in a
-- read-only diff split above, the buffer keeping its edits; taking a hunk
-- and saving; closing; and the cases left to nvim or deferred.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/diskmerge-test.lua
-- The real autocmds, so the checktime hooks and the reload notice are the
-- ones nvim runs.
require("autocmds")
local diskmerge = require("diskmerge")

local pass, fail = 0, 0
local function assert_eq(desc, expected, actual)
	local e, a = vim.json.encode(expected), vim.json.encode(actual)
	if e == a then
		pass = pass + 1
		print("ok   - " .. desc)
	else
		fail = fail + 1
		print(string.format("FAIL - %s (expected %s, got %s)", desc, e, a))
	end
end

-- A prompt nothing can answer ends a headless nvim with status 0, which would
-- read as a pass: leaving before the summary is a failure.
local finished = false
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		if not finished then
			print("\nFAIL - nvim exited before the end, likely at a prompt")
			os.exit(1)
		end
	end,
})

local said = {}
vim.notify = function(msg)
	said[#said + 1] = msg
end

local bump = 0
-- Writes `lines` to `path` with an mtime later than anything before, so
-- checktime sees a change whatever the filesystem's timestamp resolution.
local function write(path, lines)
	vim.fn.writefile(lines, path)
	bump = bump + 10
	local t = os.time() + bump
	vim.uv.fs_utime(path, t, t)
end

local function lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function settle()
	vim.wait(50, function()
		return false
	end)
end

local function fresh(content)
	vim.cmd("silent! %bwipeout!")
	local path = vim.fn.tempname() .. ".txt"
	write(path, content)
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	return path, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

local function nwins()
	return #vim.api.nvim_tabpage_list_wins(0)
end

-- --- the merge opens -------------------------------------------------------

local function reloaded()
	for _, m in ipairs(said) do
		if m:find("was reloaded", 1, true) then
			return true
		end
	end
	return false
end

local path, buf, win = fresh({ "one", "two", "three" })
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "ONE mine" })
write(path, { "one", "two", "three", "four theirs" })
said = {}
vim.cmd("checktime")
settle()

local scratch = diskmerge.scratch_for(buf)
assert_eq("a split opens", 2, nwins())
assert_eq("it holds the disk version", { "one", "two", "three", "four theirs" }, scratch and lines(scratch))
assert_eq("the buffer keeps its edits", { "ONE mine", "two", "three" }, lines(buf))
assert_eq("still unsaved", true, vim.bo[buf].modified)
assert_eq("the cursor stays in the buffer", win, vim.api.nvim_get_current_win())
local swin = scratch and vim.fn.bufwinid(scratch)
assert_eq("the split is above", true, swin and vim.fn.win_screenpos(swin)[1] < vim.fn.win_screenpos(win)[1])
assert_eq("it can't be edited", false, scratch and vim.bo[scratch].modifiable)
assert_eq("both windows diff", { true, true }, { vim.wo[win].diff, swin and vim.wo[swin].diff })
assert_eq("no notice says it was reloaded", false, reloaded())
assert_eq("its bar names the keys", true, swin and vim.wo[swin].winbar:find("do take theirs", 1, true) ~= nil)

-- --- n moves, do takes, :w saves --------------------------------------------

vim.api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd("normal n")
assert_eq("n goes to the next difference", 3, vim.api.nvim_win_get_cursor(win)[1])
vim.cmd("normal do")
assert_eq("do takes theirs into the buffer", { "ONE mine", "two", "three", "four theirs" }, lines(buf))
vim.cmd("silent write")
assert_eq("saving writes mine merged, with no changed-since-reading stop", { "ONE mine", "two", "three", "four theirs" }, vim.fn.readfile(path))

-- --- q closes ---------------------------------------------------------------

vim.cmd("normal q")
settle()
assert_eq("q closes the split", 1, nwins())
assert_eq("the buffer leaves diff mode", false, vim.wo[win].diff)
assert_eq("and keeps the merge", { "ONE mine", "two", "three", "four theirs" }, lines(buf))
assert_eq("n is the search's again", "", vim.fn.maparg("n", "n"))

-- --- unmodified: the silent reload -------------------------------------------

path, buf = fresh({ "a" })
write(path, { "a", "b" })
said = {}
vim.cmd("checktime")
settle()
assert_eq("an unmodified buffer reloads", { "a", "b" }, lines(buf))
assert_eq("and says so", true, reloaded())
assert_eq("with no split", 1, nwins())

-- --- the same content under a new timestamp --------------------------------

path, buf = fresh({ "a" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
write(path, { "a" })
vim.cmd("checktime")
settle()
assert_eq("a touch opens nothing", 1, nwins())
assert_eq("and keeps the edits", { "mine" }, lines(buf))

-- --- deleted: nvim's own handling --------------------------------------------

path, buf = fresh({ "a" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
os.remove(path)
pcall(vim.cmd, "checktime")
settle()
assert_eq("a deleted file opens nothing", 1, nwins())
assert_eq("and keeps the edits", { "mine" }, lines(buf))

-- --- a desk review open: the merge waits for it -------------------------------

path, buf, win = fresh({ "a" })
local review_buf = vim.api.nvim_create_buf(false, true)
package.loaded["desk.review"] = {
	open_review_buf = function(b)
		return b == buf and vim.api.nvim_buf_is_valid(review_buf) and review_buf or nil
	end,
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
write(path, { "theirs" })
said = {}
vim.cmd("checktime")
settle()
assert_eq("under a desk review nothing opens", 1, nwins())
assert_eq("it says the merge waits", true, (said[#said] or ""):find("desk review ends", 1, true) ~= nil)
vim.api.nvim_buf_delete(review_buf, { force = true })
settle()
assert_eq("the review gone, the merge opens", { "theirs" }, diskmerge.scratch_for(buf) and lines(diskmerge.scratch_for(buf)))
package.loaded["desk.review"] = nil

-- --- a hidden buffer: the merge waits until it shows --------------------------

path, buf = fresh({ "a" })
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
vim.cmd("hide enew")
write(path, { "theirs" })
vim.cmd("checktime")
settle()
assert_eq("a hidden buffer opens nothing", 1, nwins())
vim.cmd("buffer " .. buf)
settle()
assert_eq("shown, its merge opens", { "theirs" }, diskmerge.scratch_for(buf) and lines(diskmerge.scratch_for(buf)))

finished = true
print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
