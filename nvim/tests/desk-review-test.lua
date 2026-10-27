-- What the review (desk.review) does beside the drawing, which
-- desk-inline-test.lua covers: restoring from the declined-recently list, the
-- commit key, and the counts. Headless, against throwaway repos, never the
-- user's real notes.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-review-test.lua
local review = require("desk.review")
local proposal = require("desk.proposal")
local ledger = require("desk.ledger")
local git = require("desk.git")
local snippet = require("desk.snippet")
local git_safety = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".") .. "/../../tests/lib/git-safety.lua")

-- The overview stretches the editor's window through desk.window: a stub
-- here, so no test reaches Hammerspoon or ps. Its own section below swaps
-- in other answers.
local window = require("desk.window")
local window_calls = {}
local function window_stub(args, cb, sync)
	window_calls[#window_calls + 1] = table.concat(args, " ") .. (sync and " (sync)" or "")
	cb(true, args[1] == "tall" and "tall" or "")
end
window.run = window_stub
window.owner_fn = function()
	return { tty = "ttys009", pid = "4242" }
end

vim.env.DESK_STATE_DIR = vim.fn.tempname()
vim.env.DESK_STATUS_FILE = vim.fn.tempname()

local pass, fail = 0, 0
local function ok(desc)
	pass = pass + 1
	print("ok   - " .. desc)
end
local function bad(desc)
	fail = fail + 1
	print("FAIL - " .. desc)
end
local function assert_eq(desc, expected, actual)
	local e, a = vim.json.encode(expected), vim.json.encode(actual)
	if e == a then
		ok(desc)
	else
		bad(string.format("%s (expected %s, got %s)", desc, e, a))
	end
end
local function assert_true(desc, v)
	assert_eq(desc, true, v and true or false)
end

local FILES = { "notes.md", "reading.md" }

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local function write(repo, file, lines)
	local fd = assert(io.open(repo .. "/" .. file, "w"))
	fd:write(snippet.join_lines(lines, true))
	fd:close()
end

local function new_repo(notes)
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	git_safety.assert_repo_under_tmp(repo)
	assert(git.run(repo, { "init", "-q" }))
	write(repo, "notes.md", notes)
	write(repo, "reading.md", {})
	write(repo, review.MARKER, {})
	assert(git.run(repo, { "add", "-A" }))
	assert(git.run(repo, { "commit", "-q", "-m", "initial" }))
	return repo
end

local function item(id, over)
	return vim.tbl_extend("force", {
		id = id,
		file = "notes.md",
		kind = "new",
		target = "top",
		before = "",
		after = "NEWS " .. id,
		source = "https://example.invalid/" .. id,
		headline = "headline " .. id,
	}, over or {})
end

local function build(repo, date, items)
	local sha = assert(proposal.build(repo, "morning", date, items, FILES))
	return sha
end

local function open_notes(repo)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/notes.md"))
	return vim.api.nvim_get_current_buf()
end

local function lines_of(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function line_of(buf, text)
	for i, l in ipairs(lines_of(buf)) do
		if l == text then
			return i
		end
	end
end

local function declined_ids(repo)
	local ids = vim.tbl_keys(ledger.declined(ledger.read(repo)).ids)
	table.sort(ids)
	return ids
end

local function head_lines(repo)
	return proposal.lines_at(repo, "HEAD", "notes.md")
end

local BASE = { "Section A", "  existing", "Section B", "  other" }

-- The open suggestion of review `s` with `headline`.
local function open_item(s, headline)
	for _, it in ipairs(s.view_open or {}) do
		if it.headline == headline then
			return it
		end
	end
end

print("=== restore from declined recently: it leaves the ledger and is proposed again ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", { item("n1"), item("n2") })
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("open", review.open_review(nb))
	local s = review.session_of(nb)
	review.view_decline(s, open_item(s, "headline n1"))
	assert_true("Q ends it", review.close_review(s))
	assert_eq("one declined", 1, #declined_ids(r))
	assert_eq("it is listed as declined recently", 1, #review.declined_recently(r, 14))
	review.list_declined_recently(nb)
	assert_eq("a quickfix list with that entry", { review.DECLINED_TITLE, 1 }, { vim.fn.getqflist({ title = 0 }).title, #vim.fn.getqflist() })
	vim.cmd("1")
	review.qf_restore()
	assert_eq("restoring removes it from the ledger", {}, declined_ids(r))
	build(r, "2026-10-02", {})
	local back = false
	for _, it in ipairs(proposal.read_items(r)) do
		back = back or it.after == "NEWS n1"
	end
	assert_true("the next pass proposes it again", back)
	vim.bo[nb].modified = false
end

print("\n=== the commit key commits every notes file with changes, saving both first ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("n2"),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "reading.md: read paper" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local s = review.session_of(nb)
	review.view_take(s, { open_item(s, "headline n1") })
	local rd = vim.fn.bufadd(r .. "/reading.md")
	vim.fn.bufload(rd)
	vim.api.nvim_buf_set_lines(rd, 0, -1, false, { "READ paper", "my own line" })
	assert_true("commit", (review.commit(nb)))
	assert_eq("both files are in the commit", { "notes.md", "reading.md" }, vim.split(vim.trim(select(2, git.run(r, { "show", "--name-only", "--format=", "HEAD" }))), "\n"))
	assert_eq("both buffers are saved", { false, false }, { vim.bo[nb].modified, vim.bo[rd].modified })
	assert_eq("nothing is left over", "", vim.trim(select(2, git.run(r, { "status", "--porcelain", "--", "notes.md", "reading.md" }))))
	local taken = vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.taken_by_id(ledger.read(r))))
	table.sort(taken)
	assert_eq("the takes in both files are recorded", { "headline n1", "reading.md: read paper" }, taken)
	vim.cmd("silent! %bwipeout!")
end

print("\n=== the status line counts the suggestions deferred to a later pass ===")
do
	local r = new_repo({ "Section A", "  keep" })
	build(r, "2026-10-01", {
		item("e1", { kind = "edit", target = { at = "  keep" }, before = "  keep", after = "  kept", source = "notes" }),
		item("e2", { kind = "edit", target = { at = "  keep" }, before = "  keep", after = "  changed", source = "notes" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("with no review open", review.status_line(nb):match("1 deferred") ~= nil)
	assert_true("review opens", review.open_review(nb))
	assert_true("and with one", review.status_line(nb):match("1 left %(1 saved%) · 1 deferred") ~= nil)
	vim.cmd("silent! %bwipeout!")
end

print("\n=== a suggestion waiting on an uncommitted line is reviewable once <leader>gc commits it ===")
do
	local r = new_repo({ "Section A", "- a1" })
	write(r, "notes.md", { "Section A", "- a1", "- a2 draft" })
	local nb = open_notes(r)
	review.attach(nb)
	build(r, "2026-10-01", {
		item("late", { kind = "add", target = { after = "- a2 draft" }, after = "- a3", source = "" }),
	})
	assert_eq("it waits, so nothing is open", 0, #proposal.open_items(r))
	assert_true("commit succeeds", (review.commit(nb)))
	assert_eq("it is open without another pass", { "headline late" }, vim.tbl_map(function(it)
		return it.headline
	end, proposal.open_items(r)))
	vim.cmd("silent! %bwipeout!")
end

print("\n=== a line of the user's that reads like a conflict separator stays the user's text ===")
do
	local sep = string.rep("=", 40)
	local r = new_repo({ "S", "- A", "- B", "- C" })
	build(r, "2026-10-01", { item("ed", { kind = "edit", target = { at = "- B" }, before = "- B", after = "- B2", source = "", headline = "edit B" }) })
	write(r, "notes.md", { "S", "- A", "- B", sep })
	assert(git.run(r, { "commit", "-qam", "hand edit" }))
	local res = proposal.reviewable(r, proposal.read(r), "notes.md", head_lines(r))
	assert_eq("merged as the user's line beside the edit", { "S", "- A", "- B2", sep }, res and res.merged)
end

print("\n=== the overview makes the editor's window full height while it is open, and puts it back ===")
do
	local function tick()
		vim.wait(20, function()
			return false
		end)
	end
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", { item("n1"), item("n2") })
		local nb = open_notes(r)
		review.attach(nb)
		return nb
	end
	local function fresh()
		window.reset()
		window.run = window_stub
		window_calls = {}
	end
	local function in_list(keys)
		vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
		vim.cmd("normal " .. keys)
		tick()
	end
	local TALL, BACK = "tall ttys009 4242", "restore ttys009 4242"

	fresh()
	local nb = setup()
	assert_true("overview opens", review.overview(nb))
	assert_eq("opening it asks Hammerspoon to stretch this nvim's terminal", { TALL }, window_calls)
	assert_true("reopened over itself", review.overview(nb))
	tick()
	assert_eq("reopening it in place neither puts it back nor stretches it again", { TALL }, window_calls)
	in_list("q")
	assert_eq("q asks for it back", { TALL, BACK }, window_calls)

	for _, close in ipairs({ "Q", "cclose" }) do
		fresh()
		nb = setup()
		assert_true("overview opens", review.overview(nb))
		if close == "Q" then
			in_list("Q")
		else
			vim.cmd("cclose")
			tick()
		end
		assert_eq(close .. " asks for it back too", { TALL, BACK }, window_calls)
	end

	-- A queue of one: a call starts only once the last came back.
	local later = {}
	fresh()
	window.run = function(args, cb)
		window_calls[#window_calls + 1] = table.concat(args, " ")
		later[#later + 1] = cb
	end
	nb = setup()
	assert_true("overview opens", review.overview(nb))
	in_list("q")
	assert_eq("closed before the stretch came back: the restore waits for it", { TALL }, window_calls)
	table.remove(later, 1)(true, "tall")
	assert_eq("and goes as soon as it does", { TALL, BACK }, window_calls)
	table.remove(later, 1)(true, "")
	fresh()
end

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
