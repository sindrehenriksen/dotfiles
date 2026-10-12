-- Auto-save for the notes files (desk.autosave), headless against throwaway
-- repos, never the user's real notes, through the real wiring: desk.setup()
-- decides which buffers are notes files (the marker and the configured
-- names), and autocmds.lua's checktime and disk merge run as they do in the
-- editor. Covers the three events, the scope, a change on disk under the
-- user's edits, and the pause while a review is open.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-autosave-test.lua
vim.env.DESK_CONFIG = nil
vim.env.DESK_STATE_DIR = vim.fn.tempname()
vim.env.DESK_STATUS_FILE = vim.fn.tempname()
vim.o.hidden = true

require("autocmds")
require("desk").setup()
local autosave = require("desk.autosave")
local diskmerge = require("diskmerge")
local review = require("desk.review")
local proposal = require("desk.proposal")
local git = require("desk.git")
local snippet = require("desk.snippet")
local git_safety = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".") .. "/../../tests/lib/git-safety.lua")

-- The overview is not opened here, but nothing may reach Hammerspoon.
require("desk.window").run = function(_, cb)
	cb(true, "none")
end

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
local function assert_true(desc, v)
	assert_eq(desc, true, v and true or false)
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
local function said_matching(pat)
	return #vim.tbl_filter(function(m)
		return m:match(pat) ~= nil
	end, said)
end

local bump = 0
-- Writes `lines` to `path` with an mtime later than anything before, so
-- checktime sees a change whatever the filesystem's timestamp resolution.
local function write_disk(path, lines)
	vim.fn.writefile(lines, path)
	bump = bump + 10
	local t = os.time() + bump
	vim.uv.fs_utime(path, t, t)
end

local function settle()
	vim.wait(50, function()
		return false
	end)
end

local BASE = { "Section A", "  existing", "Section B", "  other" }

local function new_repo(marker)
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	git_safety.assert_repo_under_tmp(repo)
	assert(git.run(repo, { "init", "-q" }))
	for _, f in ipairs({ "notes.md", "reading.md", "other.md" }) do
		local fd = assert(io.open(repo .. "/" .. f, "w"))
		fd:write(snippet.join_lines(f == "notes.md" and BASE or { "- a line" }, true))
		fd:close()
	end
	if marker ~= false then
		io.open(repo .. "/" .. review.MARKER, "w"):close()
	end
	assert(git.run(repo, { "add", "-A" }))
	assert(git.run(repo, { "commit", "-q", "-m", "initial" }))
	return repo
end

local function open(path)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	return vim.api.nvim_get_current_buf()
end

local function edit(buf, text)
	vim.api.nvim_buf_set_lines(buf, 1, 2, false, { text })
end

local function event(name, buf)
	vim.api.nvim_exec_autocmds(name, buf and { buffer = buf } or {})
	settle()
end

print("=== a notes file is saved on InsertLeave, BufLeave and FocusLost ===")
do
	local r = new_repo()
	local nb = open(r .. "/notes.md")
	assert_true("the notes buffer is a notes file", autosave.is_notes(nb))

	edit(nb, "  typed")
	event("InsertLeave", nb)
	assert_eq("InsertLeave writes it", { "Section A", "  typed", "Section B", "  other" }, vim.fn.readfile(r .. "/notes.md"))
	assert_eq("and the buffer is saved", false, vim.bo[nb].modified)

	edit(nb, "  then left")
	vim.cmd("split " .. vim.fn.fnameescape(r .. "/other.md"))
	settle()
	assert_true("BufLeave, moving to another window, writes it", vim.tbl_contains(vim.fn.readfile(r .. "/notes.md"), "  then left"))

	local rd = vim.fn.bufadd(r .. "/reading.md")
	vim.cmd("buffer " .. rd)
	settle()
	vim.api.nvim_buf_set_lines(rd, 0, -1, false, { "- a paper" })
	vim.cmd("wincmd j")
	edit(nb, "  before focus went")
	event("FocusLost")
	assert_eq("FocusLost writes every notes file with edits, shown or not", { "- a paper" }, vim.fn.readfile(r .. "/reading.md"))
	assert_true("the one in the current window too", vim.tbl_contains(vim.fn.readfile(r .. "/notes.md"), "  before focus went"))
end

print("\n=== only the notes files ===")
do
	local r = new_repo()
	local ob = open(r .. "/other.md")
	assert_true("another file in the notes repo is no notes file", not autosave.is_notes(ob))
	vim.api.nvim_buf_set_lines(ob, 0, -1, false, { "- edited" })
	event("InsertLeave", ob)
	event("FocusLost")
	assert_eq("and is never auto-saved", { "- a line" }, vim.fn.readfile(r .. "/other.md"))
	assert_true("its edit stays unsaved", vim.bo[ob].modified)

	local elsewhere = new_repo(false)
	local nb = open(elsewhere .. "/notes.md")
	assert_true("a notes.md outside a repo with the marker is no notes file", not autosave.is_notes(nb))
	edit(nb, "  not mine to save")
	event("InsertLeave", nb)
	event("FocusLost")
	assert_eq("and is never auto-saved", BASE, vim.fn.readfile(elsewhere .. "/notes.md"))
	vim.bo[nb].modified = false
end

print("\n=== never over a change on disk ===")
do
	local r = new_repo()
	local path = r .. "/notes.md"
	local nb = open(path)
	local theirs = { "Section A", "  existing", "Section B", "  theirs" }
	write_disk(path, theirs)
	edit(nb, "  mine")
	said = {}
	event("InsertLeave", nb)
	assert_eq("a change on disk under the user's edits is not written over", theirs, vim.fn.readfile(path))
	assert_true("the edit stays in the buffer, unsaved", vim.bo[nb].modified)
	assert_true("checktime ran first: the disk merge is open", diskmerge.conflict(nb) and diskmerge.scratch_for(nb) ~= nil)
	assert_eq("it says why once", 1, said_matching("^desk: notes%.md changed on disk: not saved"))
	event("InsertLeave", nb)
	event("FocusLost")
	assert_eq("and not again at every event", 1, said_matching("^desk: notes%.md changed on disk: not saved"))
	assert_eq("still not written", theirs, vim.fn.readfile(path))

	-- The user takes theirs and closes the merge: the buffer is the merge
	-- now, and goes over the disk at the next event.
	vim.api.nvim_buf_set_lines(nb, 3, 4, false, { "  theirs" })
	diskmerge.close(nb)
	event("InsertLeave", nb)
	assert_eq("once merged, it is saved", { "Section A", "  mine", "Section B", "  theirs" }, vim.fn.readfile(path))
	assert_eq("and the buffer is saved", false, vim.bo[nb].modified)

	-- Deleted under the user's edits: never recreated.
	edit(nb, "  orphan")
	os.remove(path)
	said = {}
	event("InsertLeave", nb)
	assert_eq("a notes file gone from disk is not recreated", 0, vim.fn.filereadable(path))
	vim.bo[nb].modified = false
end

print("\n=== paused while a review is open on the file ===")
do
	local r = new_repo()
	assert(proposal.build(r, "morning", "2026-10-01", {
		{ id = "n1", file = "notes.md", kind = "new", target = "top", before = "", after = "NEWS n1", source = "https://example.invalid/n1", headline = "headline n1" },
	}, { "notes.md", "reading.md" }))
	local nb = open(r .. "/notes.md")
	assert_true("review opens", review.open_review(nb))
	edit(nb, "  during review")
	event("InsertLeave", nb)
	event("FocusLost")
	assert_eq("no auto-save while it is open, so no take is recorded behind the review", BASE, vim.fn.readfile(r .. "/notes.md"))
	vim.api.nvim_set_current_win(vim.fn.bufwinid(nb))
	vim.api.nvim_feedkeys(vim.keycode("<leader>gq"), "x", false)
	settle()
	assert_true("the review's own close saves it", vim.tbl_contains(vim.fn.readfile(r .. "/notes.md"), "  during review"))
end

finished = true
print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
