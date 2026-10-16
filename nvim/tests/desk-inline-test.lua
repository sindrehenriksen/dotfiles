-- The review's one window (desk.inline, desk.review with view "inline"):
-- the notes buffer itself, decorated. Headless against throwaway repos: what
-- it draws over the notes, that typing edits the notes, and that take,
-- decline, n/N, undo, the overview, the view key and every way out work.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-inline-test.lua
local review = require("desk.review")
local inline = require("desk.inline")
local proposal = require("desk.proposal")
local ledger = require("desk.ledger")
local git = require("desk.git")
local snippet = require("desk.snippet")
local git_safety = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".") .. "/../../tests/lib/git-safety.lua")

require("desk.window").run = function(_, cb)
	cb(true, "none")
end
require("desk.window").owner_fn = function()
	return nil
end
vim.env.DESK_STATE_DIR = vim.fn.tempname()
vim.env.DESK_STATUS_FILE = vim.fn.tempname()
vim.notify = function() end
-- `n`/`N` are the search's own while a search is highlighted.
vim.o.hlsearch = false

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

local FILES = { "notes.md", "reading.md" }

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
		kind = "add",
		target = "top",
		before = "",
		after = "NEWS " .. id,
		source = "notes",
		headline = "headline " .. id,
	}, over or {})
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

local BASE = { "Section A", "- keep one", "- old line", "", "Section B", "- b1", "- stale", "- b3" }
local ITEMS = {
	item("ed", { kind = "edit", target = { at = "- old line" }, before = "- old line", after = "- new line", headline = "rewrite the old line" }),
	item("ad", { kind = "add", target = { under = "Section B" }, after = "- b4 added", headline = "add b4" }),
	item("rm", { kind = "remove", target = { at = "- stale" }, before = "- stale", after = "", headline = "drop the stale line" }),
}

-- A repo with the three suggestions, its notes open and reviewed in one
-- window. Returns repo, notes buffer, review buffer.

-- The notes open and reviewed in one window over `notes` and `items`.
-- Returns repo, notes buffer, review session.
local function setup(notes, items)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	local r = new_repo(notes or BASE)
	assert(proposal.build(r, "morning", "2026-10-01", items or ITEMS, FILES))
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	review.view = "inline"
	assert(review.open_review(nb))
	return r, nb, review.session_of(nb)
end

local function changed(nb)
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = nb })
end

-- The decorations on `buf`: struck rows, and virtual blocks as
-- { row, above, lines (with any label) }.
local function decor(buf)
	local out = { struck = {}, blocks = {}, labels = {}, old_words = {}, new_words = {} }
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, inline.NS, 0, -1, { details = true })) do
		local d = m[4]
		if d.hl_group == "DeskInlineOld" then
			out.struck[#out.struck + 1] = m[2] + 1
		end
		if d.hl_group == "DeskInlineOldText" then
			local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
			out.old_words[#out.old_words + 1] = line:sub(m[3] + 1, d.end_col)
		end
		if d.virt_lines then
			local lines = {}
			for _, vl in ipairs(d.virt_lines) do
				local t = {}
				for _, c in ipairs(vl) do
					t[#t + 1] = c[1]
					if c[2] == "DeskInlineNewText" then
						out.new_words[#out.new_words + 1] = c[1]
					end
				end
				lines[#lines + 1] = table.concat(t)
			end
			out.blocks[#out.blocks + 1] = { row = m[2] + 1, above = d.virt_lines_above or false, lines = lines }
		end
		if d.virt_text then
			out.labels[m[2] + 1] = d.virt_text[1][1]
		end
	end
	table.sort(out.struck)
	return out
end

local function block_with(buf, text)
	for _, b in ipairs(decor(buf).blocks) do
		for _, l in ipairs(b.lines) do
			if l:find(text, 1, true) then
				return b
			end
		end
	end
end

local function spot_row(s, headline)
	for _, spot in ipairs(s.view_spots) do
		if spot.item.headline == headline then
			return spot.row
		end
	end
end

local function settle()
	vim.wait(20, function()
		return false
	end)
end

print("=== one window is the default; the split is the view key away ===")
assert_eq("a review opens in one window", "inline", review.view)

print("\n=== one window: the notes themselves, suggestions drawn over them ===")
do
	local _, nb = setup()
	assert_eq("one window", "leaf", vim.fn.winlayout()[1])
	assert_eq("showing the notes", nb, vim.api.nvim_get_current_buf())
	assert_eq("the notes as they were", BASE, lines_of(nb))
	assert_true("not in diff mode", not vim.wo.diff)
	local d = decor(nb)
	assert_eq("the lines a suggestion removes or replaces are struck, as real lines", { line_of(nb, "- old line"), line_of(nb, "- stale") }, d.struck)
	local edit = block_with(nb, "- new line")
	assert_eq("an edit's new line is drawn, tinted, just above the line it replaces, its headline on it", { line_of(nb, "- old line"), true, { "- new line  « rewrite the old line" } }, { edit and edit.row, edit and edit.above, edit and edit.lines })
	local add = block_with(nb, "- b4 added")
	assert_eq("an added line is drawn where it would go", { line_of(nb, "- b3"), false }, { add and add.row, add and add.above })
	assert_true("a removal's headline sits beside its struck line", (d.labels[line_of(nb, "- stale")] or ""):match("drop the stale line"))
	assert_true("the bar names the keys", vim.wo.winbar:match("^" .. vim.pesc(review.INLINE_KEY_HINT)))
end

print("\n=== what an edit changes within a line is marked more strongly ===")
do
	assert_eq("the changed word, in the old line and the new", { { { 2, 5 } }, { { 2, 5 } } }, { inline.word_changes("- old line", "- new line") })
	assert_eq("a word with letters past ASCII is one word", { { { 8, 11 } }, { { 8, 14 } } }, { inline.word_changes("møte i dag", "møte i morgen") })
	assert_eq("an added word is marked only in the new line", { {}, { { 6, 10 } } }, { inline.word_changes("- buy milk", "- buy oat milk") })
	assert_eq("lines with no word in common: no marks, the tint alone", nil, inline.word_changes("- alpha beta", "* gamma"))
	assert_eq("lines pair where a hunk replaces them, an added one unpaired", { { 1, 1 }, { 2, 3 } }, inline.pair_lines({ "- one", "- two", "- keep" }, { "- one!", "- inserted", "- two!", "- keep" }))

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- an old line here" })
	inline.draw(buf, {
		struck = { { first = 1, last = 1 } },
		old_words = { [1] = { { 5, 8 } } },
		blocks = { { row = 1, above = true, lines = { "- an new line here, changed" }, words = { { { 5, 8 }, { 18, 27 } } } } },
		width = 12,
	})
	local d = decor(buf)
	assert_eq("the old line's changed word is marked", { "old" }, d.old_words)
	assert_eq("the new line's, across the pieces it wraps into", { "new", ", ", "changed" }, d.new_words)
	assert_eq("and the wrapped line still reads whole", "- an new line here, changed", table.concat(d.blocks[1].lines))
	vim.api.nvim_buf_delete(buf, { force = true })

	local _, nb = setup()
	d = decor(nb)
	assert_eq("in the review, the edit's old word", { "old" }, d.old_words)
	assert_eq("and its new one; the removal and the addition have none", { "new" }, d.new_words)

	local tgc = vim.o.termguicolors
	vim.o.termguicolors = true
	review.define_highlights()
	local old = vim.api.nvim_get_hl(0, { name = "DeskInlineOld" })
	assert_true("the lines going away are not struck through", not old.strikethrough)
	assert_true("they are tinted red instead, their words that change stronger", vim.api.nvim_get_hl(0, { name = "DeskInlineOldLine" }).bg ~= nil and vim.api.nvim_get_hl(0, { name = "DeskInlineOldText" }).bg ~= vim.api.nvim_get_hl(0, { name = "DeskInlineOldLine" }).bg)
	assert_true("the new lines' changed words stronger than their tint", vim.api.nvim_get_hl(0, { name = "DeskInlineNewText" }).bg ~= vim.api.nvim_get_hl(0, { name = "DeskInlineNew" }).bg)
	vim.o.termguicolors = tgc
	review.define_highlights()
end

print("\n=== typing edits the notes, and the decorations follow ===")
do
	local r, nb, s = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- b1"), 0 })
	vim.api.nvim_feedkeys("O- typed above a pending removal\27", "xt", false)
	changed(nb)
	assert_true("what is typed is in the notes", line_of(nb, "- typed above a pending removal") ~= nil)
	assert_eq("the removal is still struck, on its own line", { line_of(nb, "- old line"), line_of(nb, "- stale") }, decor(nb).struck)
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.cmd("normal dp")
	assert_true("taking it removes that line and no other", not line_of(nb, "- stale") and line_of(nb, "- typed above a pending removal") and line_of(nb, "- b1") and line_of(nb, "- b3"))
	vim.cmd("normal u")
	assert_true("u takes the take back as one change", line_of(nb, "- stale") ~= nil)
	-- A struck line deleted by hand: that removal is taken.
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.cmd("normal! dd")
	changed(nb)
	assert_true("deleting a struck line by hand leaves it taken, not shown", spot_row(s, "drop the stale line") == nil)
	vim.cmd("silent write")
	review.commit(nb)
	assert_true("and the commit records it taken", #vim.tbl_filter(function(rec)
		return rec.headline == "drop the stale line"
	end, vim.tbl_values(ledger.taken_by_id(ledger.read(r)))) == 1)
	-- The line a suggestion hangs on deleted: its business for the next pass.
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- b3"), 0 })
	vim.cmd("normal! dd")
	changed(nb)
	assert_true("deleting the line an addition hangs on is the user's edit, kept", not line_of(nb, "- b3"))
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "Section B"), 0 })
	vim.cmd("normal! dd")
	changed(nb)
	assert_true("with its anchor gone the addition waits for the next pass, never on top", block_with(nb, "- b4 added") == nil)
end

print("\n=== take, decline, n/N and undo ===")
do
	local _, nb, s = setup()
	local win = vim.api.nvim_get_current_win()
	assert_eq("the cursor starts on the first suggestion", spot_row(s, "rewrite the old line"), vim.api.nvim_win_get_cursor(win)[1])
	vim.cmd("normal n")
	assert_eq("n goes to the next", spot_row(s, "drop the stale line"), vim.api.nvim_win_get_cursor(win)[1])
	vim.cmd("normal n")
	vim.cmd("normal n")
	assert_eq("and wraps round", spot_row(s, "rewrite the old line"), vim.api.nvim_win_get_cursor(win)[1])
	vim.cmd("normal N")
	assert_eq("N goes back, wrapping", spot_row(s, "add b4"), vim.api.nvim_win_get_cursor(win)[1])
	vim.api.nvim_win_set_cursor(win, { spot_row(s, "add b4"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_true("␣gA takes the suggestion on the line", line_of(nb, "- b4 added") ~= nil)
	vim.api.nvim_win_set_cursor(win, { line_of(nb, "- old line"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_true("an edit taken replaces its line", line_of(nb, "- new line") and not line_of(nb, "- old line"))
	vim.cmd("normal u")
	assert_true("u takes the whole take back at once", line_of(nb, "- old line") and not line_of(nb, "- new line") and line_of(nb, "- b4 added"))
	vim.api.nvim_win_set_cursor(win, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	assert_true("␣gD declines it: its decoration goes", not vim.tbl_contains(decor(nb).struck, line_of(nb, "- stale")) and line_of(nb, "- stale"))
	vim.cmd("normal u")
	assert_true("u brings it back", vim.tbl_contains(decor(nb).struck, line_of(nb, "- stale")))
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	assert_true("the count leaves out what was declined", review.status_line(nb):match("1 left") ~= nil)
end

print("\n=== Q, ␣gq and :q end the review in one step, saying what went ===")
do
	for _, way in ipairs({ "Q", "gq", ":q" }) do
		local r, nb, s = setup()
		local said = {}
		vim.notify = function(m)
			said[#said + 1] = m
		end
		vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
		vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
		vim.api.nvim_win_set_cursor(0, { spot_row(s, "add b4"), 0 })
		vim.cmd("normal dp")
		local rb = s.review_buf
		if way == ":q" then
			vim.cmd("botright new")
			vim.api.nvim_set_current_win(vim.fn.bufwinid(nb))
			vim.cmd("q")
		else
			vim.api.nvim_feedkeys(way == "Q" and "Q" or vim.keycode("<leader>gq"), "x", false)
		end
		settle()
		local declined = vim.tbl_map(function(rec)
			return rec.headline
		end, vim.tbl_values(ledger.declined(ledger.read(r)).ids))
		assert_true(way .. ": the review is over", not vim.api.nvim_buf_is_valid(rb) and review.open_review_buf(nb) == nil)
		assert_eq(way .. ": the decline is recorded", { "drop the stale line" }, declined)
		assert_true(way .. ": the take stays in the notes", line_of(nb, "- b4 added") ~= nil)
		if way ~= ":q" then
			assert_true(way .. ": recorded taken as the notes are saved", #vim.tbl_filter(function(rec)
				return rec.headline == "add b4"
			end, vim.tbl_values(ledger.taken_by_id(ledger.read(r)))) == 1)
		end
		assert_true(way .. ": and it says so, by name", #vim.tbl_filter(function(m)
			return m:match("^desk: review closed: .*1 declined %(drop the stale line%)") ~= nil
		end, said) == 1)
		assert_eq(way .. ": no decoration is left", 0, #vim.api.nvim_buf_get_extmarks(nb, inline.NS, 0, -1, {}))
		vim.notify = function() end
		vim.bo[nb].modified = false
	end
end

print("\n=== the overview previews, acts and jumps in one window ===")
do
	local _, nb, s = setup()
	local nw = vim.api.nvim_get_current_win()
	assert_true("the overview opens", review.overview(nb))
	local qw = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(qw, { 3, 0 })
	review.qf_preview()
	assert_eq("moving in the list shows the entry's line in the notes", spot_row(s, "add b4"), vim.api.nvim_win_get_cursor(nw)[1])
	review.qf_jump()
	assert_eq("<CR> jumps there", nw, vim.api.nvim_get_current_win())
	vim.api.nvim_set_current_win(qw)
	vim.api.nvim_win_set_cursor(qw, { 1, 0 })
	vim.cmd("normal t")
	assert_true("t takes the entry", line_of(nb, "- new line") ~= nil and not line_of(nb, "- old line"))
	vim.cmd("normal x")
	assert_true("x declines the next", spot_row(s, "drop the stale line") == nil)
	vim.cmd("normal q")
	settle()
	assert_true("q ends the review and closes the list", vim.fn.getqflist({ winid = 0 }).winid == 0 and review.open_review_buf(nb) == nil)
	assert_true("with the notes saved", not vim.bo[nb].modified)
end

print("\n=== a take from the overview redraws the notes ===")
do
	-- An edit of one line whose `before` carries the sub-bullet under it,
	-- which the edit leaves as it is.
	local notes = { "Section A", "- parent line here", "  - a sub-bullet under it", "- after", "", "Section B", "- b1" }
	local _, nb, s = setup(notes, {
		item("ed", { kind = "edit", target = { at = "- parent line here" }, before = "- parent line here\n  - a sub-bullet under it", after = "- parent line changed\n  - a sub-bullet under it", headline = "change the parent" }),
		item("ad", { kind = "add", target = { under = "Section B" }, after = "- b2 added", headline = "add b2" }),
	})
	assert_true("the overview opens", review.overview(nb))
	local qw = vim.api.nvim_get_current_win()
	for i, e in ipairs(vim.fn.getqflist()) do
		if e.text == "change the parent" then
			vim.api.nvim_win_set_cursor(qw, { i, 0 })
		end
	end
	vim.cmd("normal t")
	assert_true("t takes the edit", line_of(nb, "- parent line changed") ~= nil and not line_of(nb, "- parent line here"))
	local d = decor(nb)
	assert_eq("no line is drawn as going away any more, the sub-bullet included", {}, d.struck)
	assert_true("and the taken text is not drawn again", block_with(nb, "- parent line changed") == nil)
	assert_true("the other suggestion still drawn where it goes", block_with(nb, "- b2 added") ~= nil)
	assert_eq("and it is the one left to step to", { "add b2" }, vim.tbl_map(function(spot)
		return spot.item.headline
	end, s.view_spots))
	vim.cmd("cclose")
	vim.bo[nb].modified = false
end

print("\n=== the last suggestion taken or declined ends the review ===")
do
	for _, way in ipairs({ "t", "x", "dp", "gA", "gD" }) do
		local r, nb, s = setup({ "Section A", "- keep one", "- old line", "", "Section B", "- b1" }, {
			item("ed", { kind = "edit", target = { at = "- old line" }, before = "- old line", after = "- new line", headline = "rewrite the old line" }),
			item("ad", { kind = "add", target = { under = "Section B" }, after = "- b2 added", headline = "add b2" }),
		})
		local said = {}
		vim.notify = function(m)
			said[#said + 1] = m
		end
		local rb = s.review_buf
		local nw = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_cursor(nw, { spot_row(s, "add b2"), 0 })
		vim.cmd("normal dp")
		assert_true(way .. ": one taken, one left: the review stays", review.open_review_buf(nb) ~= nil)
		if way == "t" or way == "x" then
			assert_true(way .. ": the overview opens", review.overview(nb))
			vim.cmd("normal " .. way)
		else
			vim.api.nvim_win_set_cursor(nw, { line_of(nb, "- old line"), 0 })
			if way == "dp" then
				vim.cmd("normal dp")
			else
				vim.api.nvim_feedkeys(vim.keycode(way == "gA" and "<leader>gA" or "<leader>gD"), "x", false)
			end
		end
		settle()
		local taking = way == "t" or way == "dp" or way == "gA"
		assert_true(way .. ": the review is over", not vim.api.nvim_buf_is_valid(rb) and review.open_review_buf(nb) == nil)
		assert_true(way .. ": the overview is closed", vim.fn.getqflist({ winid = 0 }).winid == 0)
		assert_eq(way .. ": no decoration is left", 0, #vim.api.nvim_buf_get_extmarks(nb, inline.NS, 0, -1, {}))
		assert_true(way .. ": the notes are saved", not vim.bo[nb].modified)
		local taken = vim.tbl_map(function(rec)
			return rec.headline
		end, vim.tbl_values(ledger.taken_by_id(ledger.read(r))))
		table.sort(taken)
		local declined = vim.tbl_map(function(rec)
			return rec.headline
		end, vim.tbl_values(ledger.declined(ledger.read(r)).ids))
		assert_eq(way .. ": the takes recorded", taking and { "add b2", "rewrite the old line" } or { "add b2" }, taken)
		assert_eq(way .. ": and the declines", taking and {} or { "rewrite the old line" }, declined)
		local want = taking and "^desk: review closed: 2 taken; saved notes%.md with your takes$" or "^desk: review closed: 1 taken, 1 declined %(rewrite the old line%); saved notes%.md with your takes$"
		assert_true(way .. ": and it says so as Q does", #vim.tbl_filter(function(m)
			return m:match(want) ~= nil
		end, said) == 1)
		vim.notify = function() end
	end
end

print("\n=== an end that cannot record leaves the list and the bar current ===")
do
	local r, nb, s = setup({ "Section A", "- keep one", "- old line", "", "Section B", "- b1" }, {
		item("ed", { kind = "edit", target = { at = "- old line" }, before = "- old line", after = "- new line", headline = "rewrite the old line" }),
		item("ad", { kind = "add", target = { under = "Section B" }, after = "- b2 added", headline = "add b2" }),
	})
	vim.api.nvim_win_set_cursor(0, { spot_row(s, "add b2"), 0 })
	vim.cmd("normal dp")
	assert_true("the overview opens", review.overview(nb))
	local record = ledger.record_declines
	ledger.record_declines = function()
		return false
	end
	vim.cmd("normal x")
	ledger.record_declines = record
	settle()
	assert_true("the review stays open, its end refused", review.open_review_buf(nb) ~= nil)
	assert_eq("the overview no longer lists the declined one", {}, vim.tbl_map(function(e)
		return e.text
	end, vim.fn.getqflist()))
	-- The decline is still waiting to be recorded: an edit of the notes
	-- does not bring it back, and the next end records it.
	vim.api.nvim_set_current_win(vim.fn.bufwinid(nb))
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- keep one"), 0 })
	vim.api.nvim_feedkeys("o- typed after the refused end\27", "xt", false)
	changed(nb)
	assert_true("after an edit the declined one stays declined, nothing left", review.status_line(nb):match("^0 left") ~= nil and spot_row(s, "rewrite the old line") == nil)
	local said = {}
	vim.notify = function(m)
		said[#said + 1] = m
	end
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	vim.notify = function() end
	assert_true("Q then ends the review", review.open_review_buf(nb) == nil)
	assert_eq("and records the decline the refused end could not", { "rewrite the old line" }, vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids)))
	assert_true("saying so as it closes", #vim.tbl_filter(function(m)
		return m:match("^desk: review closed: .*1 declined %(rewrite the old line%)") ~= nil
	end, said) == 1)
	vim.cmd("cclose")
	vim.bo[nb].modified = false
end

print("\n=== a commit's own rebuild is adopted in the one window ===")
do
	local r = new_repo(BASE)
	local draft = vim.deepcopy(BASE)
	table.insert(draft, 6, "- b1 draft")
	write(r, "notes.md", draft)
	assert(proposal.build(r, "morning", "2026-10-01", {
		ITEMS[1],
		ITEMS[2],
		ITEMS[3],
		item("late", { kind = "add", target = { after = "- b1 draft" }, after = "- late line", headline = "add late" }),
	}, FILES))
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	review.view = "inline"
	assert(review.open_review(nb))
	local s = review.session_of(nb)
	local said = {}
	vim.notify = function(m)
		said[#said + 1] = m
	end
	assert_true("the waiting suggestion is not shown yet", spot_row(s, "add late") == nil)
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- old line"), 0 })
	vim.cmd("normal dp")
	assert_true("take", line_of(nb, "- new line") ~= nil)
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	assert_true("decline", spot_row(s, "drop the stale line") == nil)
	assert_true("commit", (review.commit(nb)))
	settle()
	assert_eq("the review adopted the rebuilt proposal", git.ref_sha(r, review.PROPOSAL_REF), s.sha)
	assert_true("the waiting suggestion is drawn", spot_row(s, "add late") ~= nil or line_of(nb, "- late line") ~= nil)
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- b1 draft"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_true("it can be taken at once", line_of(nb, "- late line") ~= nil)
	assert_eq("with nothing refused or reloaded", {}, vim.tbl_filter(function(m)
		return m:match("proposal changed") ~= nil
	end, said))
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	vim.notify = function() end
	assert_eq("the decline is recorded as the review ends", { "drop the stale line" }, vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids)))
	vim.cmd("cclose")
	vim.bo[nb].modified = false
end

print("\n=== the view key: to the split and back, the declines carried ===")
do
	local r, nb, s = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	assert_eq("two windows", "col", vim.fn.winlayout()[1])
	local rb = s.review_buf
	assert_true("the split in diff mode", vim.wo[vim.fn.bufwinid(rb)].diff and vim.wo[vim.fn.bufwinid(nb)].diff)
	assert_true("the declined removal not proposed there: its line stays", line_of(rb, "- stale") ~= nil)
	assert_eq("no decoration in the split", 0, #vim.api.nvim_buf_get_extmarks(nb, inline.NS, 0, -1, {}))
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	assert_eq("back to one window", "leaf", vim.fn.winlayout()[1])
	assert_eq("on the notes", nb, vim.api.nvim_get_current_buf())
	local closed = false
	for l = 1, vim.api.nvim_buf_line_count(nb) do
		closed = closed or vim.fn.foldclosed(l) ~= -1
	end
	assert_true("out of diff mode, nothing folded or bound", not vim.wo.diff and not closed and not vim.wo.scrollbind)
	assert_true("drawn again, the decline still out", #decor(nb).blocks > 0 and not vim.tbl_contains(decor(nb).struck, line_of(nb, "- stale")))
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_eq("the decline is recorded as it ends", 1, #vim.tbl_keys(ledger.declined(ledger.read(r)).ids))
end

print("\n=== the top and the end of the file, and an empty one ===")
do
	local _, nb = setup({ "- first", "- middle", "- last" }, {
		item("top", { kind = "new", target = "top", after = "- on top" }),
		item("end", { kind = "add", target = { after = "- last" }, after = "- at the end" }),
		item("rm", { kind = "remove", target = { at = "- last" }, before = "- last", after = "" }),
	})
	local top = block_with(nb, "- on top")
	assert_eq("a line for the top is drawn above line 1", { 1, true }, { top and top.row, top and top.above })
	assert_true("the last line struck", vim.tbl_contains(decor(nb).struck, 3))
	local bottom = block_with(nb, "- at the end")
	assert_true("and a line for the end drawn after it", bottom and bottom.row == 3 and not bottom.above)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal dp")
	assert_eq("dp on line 1 takes the line for the top", "- on top", lines_of(nb)[1])
	local _, nb2 = setup({}, { item("n1", { kind = "new", target = "top", after = "NEWS n1" }) })
	local b = block_with(nb2, "NEWS n1")
	assert_true("an empty file shows its suggestion above its one line", b and b.row == 1 and b.above)
	vim.cmd("normal dp")
	assert_eq("and dp leaves just it", { "NEWS n1" }, lines_of(nb2))
end

print("\n=== new lines wrap to the window, unicode and all ===")
do
	local long = string.rep("æøå ", 40) .. "slutt"
	local pieces = inline.wrap(long, 30)
	local fits = true
	for _, p in ipairs(pieces) do
		fits = fits and vim.fn.strdisplaywidth(p) <= 30
	end
	assert_true("into pieces that fit", #pieces > 1 and fits)
	assert_eq("and lose nothing", long, table.concat(pieces))
	local _, nb = setup({ "A", "- short" }, {
		item("e", { kind = "edit", target = { at = "- short" }, before = "- short", after = "- " .. long }),
	})
	local b = block_with(nb, "æøå")
	assert_true("a long new line is drawn on several lines", b and #b.lines > 1)
end

print("\n=== more ways the keys find a suggestion ===")
do
	-- A count on dp; an edit's own block under its own line; the struck
	-- first line of a longer edit; a move taken from either place.
	local _, nb, s = setup({ "A", "- a1", "- a2", "- a3", "", "B", "- b1", "- b2", "- b3", "", "C", "- c1" }, {
		item("x", { kind = "add", target = { after = "- a1" }, after = "- x", headline = "x" }),
		item("ed", { kind = "edit", target = { at = "- b1" }, before = "- b1\n- b2", after = "- b1 and b2", headline = "join b" }),
		item("rm", { kind = "remove", target = { at = "- b3" }, before = "- b3", after = "", headline = "drop b3" }),
		item("mv", { kind = "move", target = { { at = "- a3" }, { after = "- c1" } }, before = "- a3", after = "- a3", headline = "move a3" }),
	})
	local edit = block_with(nb, "- b1 and b2")
	assert_eq("an edit's new line is drawn at its own old lines, not after the removal beside them", { line_of(nb, "- b1"), true }, { edit and edit.row, edit and edit.above })
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- b1"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_true("␣gA on the first of an edit's struck lines takes it", line_of(nb, "- b1 and b2") and not line_of(nb, "- b2"))
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- c1"), 0 })
	vim.cmd("normal dp")
	assert_true("dp on a move's landing takes both its places", line_of(nb, "- a3") == line_of(nb, "- c1") + 1)
	vim.api.nvim_win_set_cursor(0, { spot_row(s, "x"), 0 })
	vim.cmd("normal 2dp")
	assert_true("2dp takes two changes from the cursor down", line_of(nb, "- x") and not line_of(nb, "- b3"))
end

print("\n=== the overview shows an addition on the line it hangs on ===")
do
	local _, nb, s = setup({ "A", "- a1", "- a2", "- a3" }, { item("x", { kind = "add", target = { after = "- a1" }, after = "- x" }) })
	local nw = vim.api.nvim_get_current_win()
	assert_true("the overview opens", review.overview(nb))
	review.qf_preview()
	assert_eq("on its line", spot_row(s, "headline x"), vim.api.nvim_win_get_cursor(nw)[1])
end

print("\n=== declines made in the split carry to the one window ===")
do
	local r, nb = setup()
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	local s = review.session_of(nb)
	local rb = s.review_buf
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b4 added"), 0 })
	assert_true("declined in the split", review.decline(rb))
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	assert_true("not drawn in the one window", block_with(nb, "- b4 added") == nil)
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_eq("recorded as it ends", { "add b4" }, vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids)))
end

print("\n=== a new proposal under the open window is drawn ===")
do
	local r, nb = setup()
	assert(proposal.build(r, "morning", "2026-10-02", { item("new", { kind = "new", target = "top", after = "- brand new" }) }, FILES))
	vim.api.nvim_exec_autocmds("FocusGained", { buffer = nb })
	assert_true("its suggestion appears", block_with(nb, "- brand new") ~= nil)
end

print("\n=== duplicate lines: the drawing and the take agree on which one ===")
do
	local _, nb, s = setup({ "A", "- dup", "B", "- dup" }, {
		item("ed", { kind = "edit", target = { at = "- dup" }, before = "- dup", after = "- changed", headline = "change dup" }),
	})
	assert_eq("the first is struck", { 2 }, decor(nb).struck)
	vim.api.nvim_win_set_cursor(0, { 2, 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_eq("and the take changes that one", { "A", "- changed", "B", "- dup" }, lines_of(nb))
	_ = s
end

print("\n=== suggestions at one place are drawn in the order a take puts them ===")
do
	local _, nb, s = setup({ "A", "- a1", "- a2" }, {
		item("x", { kind = "add", target = { after = "- a1" }, after = "- x" }),
		item("y", { kind = "add", target = { after = "- a1" }, after = "- y" }),
	})
	local b = block_with(nb, "- x")
	local drawn = vim.tbl_map(function(l)
		return (l:gsub("  « .*$", ""))
	end, b and b.lines or {})
	vim.api.nvim_win_set_cursor(0, { spot_row(s, "headline x"), 0 })
	vim.cmd("normal dp")
	assert_eq("drawn as taken", vim.list_slice(lines_of(nb), 3, 4), drawn)
	local _, nb2, s2 = setup({ "A" }, {
		item("p", { kind = "new", target = "top", after = "- p" }),
		item("q", { kind = "new", target = "top", after = "- q" }),
	})
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_eq("of two on line 1, ␣gA takes the first drawn", "- p", lines_of(nb2)[1])
	_ = s2
end

print("\n=== in the split, typing in the notes is no edit of the review's ===")
do
	review.view = "split"
	local r = new_repo(BASE)
	assert(proposal.build(r, "morning", "2026-10-01", ITEMS, FILES))
	vim.cmd("silent! %bwipeout!")
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	assert(review.open_review(nb))
	local rb = review.open_review_buf(nb)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b4 added"), 0 })
	assert_true("declined", review.decline(rb))
	vim.api.nvim_set_current_win(vim.fn.bufwinid(nb))
	vim.api.nvim_feedkeys("Go- typed in the notes\27", "xt", false)
	local said = {}
	vim.notify = function(m)
		said[#said + 1] = m
	end
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_true("Q closes cleanly", review.open_review_buf(nb) == nil and not vim.tbl_contains(said, "desk: " .. review.HAND_EDITS))
	assert_eq("recording the decline", { "add b4" }, vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids)))
	assert_true("and the typing is in the notes", line_of(nb, "- typed in the notes") ~= nil)
	vim.notify = function() end
	review.view = "inline"
end

print("\n=== declines are recorded however the one window ends ===")
do
	local function declined(r)
		return vim.tbl_map(function(rec)
			return rec.headline
		end, vim.tbl_values(ledger.declined(ledger.read(r)).ids))
	end
	-- The review key over a proposal that moved on.
	local r, nb = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	assert(proposal.build(r, "morning", "2026-10-02", { item("new", { kind = "new", target = "top", after = "- brand new" }) }, FILES))
	assert_true("␣gR reopens", review.open_review(nb))
	assert_eq("␣gR records the decline first", { "drop the stale line" }, declined(r))
	-- The notes window shown another buffer.
	r, nb = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	vim.cmd("enew")
	settle()
	assert_true("another buffer in the window ends the review", review.open_review_buf(nb) == nil)
	assert_eq("recording the decline", { "drop the stale line" }, declined(r))
	-- nvim quitting.
	r, nb = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	vim.api.nvim_exec_autocmds("VimLeavePre", {})
	assert_eq("quitting nvim records it", { "drop the stale line" }, declined(r))
end

print("\n=== the keys act on the notes as they are, reported or not ===")
do
	local _, nb = setup()
	-- A change no TextChanged has reported yet.
	vim.api.nvim_buf_set_lines(nb, 0, 0, false, { "- a line put in above everything" })
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- old line"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gA"), "x", false)
	assert_true("␣gA takes the suggestion on that line", line_of(nb, "- new line") and not line_of(nb, "- old line"))
end

print("\n=== auto-save runs in the one window; takes are recorded as it ends ===")
do
	-- As desk.setup wires it: what each save wrote is what the next is
	-- checked against.
	require("desk.autosave").setup({ "*/notes.md" })
	local r, nb, s = setup()
	require("desk.autosave").attach(nb)
	vim.api.nvim_win_set_cursor(0, { spot_row(s, "add b4"), 0 })
	vim.cmd("normal dp")
	vim.api.nvim_feedkeys("Go- typed\27", "xt", false)
	vim.api.nvim_exec_autocmds("InsertLeave", { buffer = nb })
	settle()
	assert_true("what is typed is saved", vim.tbl_contains(vim.fn.readfile(r .. "/notes.md"), "- typed"))
	assert_eq("the take not yet recorded", 0, #vim.tbl_keys(ledger.taken_by_id(ledger.read(r))))
	-- Take, undo, redo, end: taken.
	vim.cmd("normal u")
	vim.cmd("normal u")
	vim.cmd("redo")
	changed(nb)
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_true("a take undone and redone is recorded as the review ends", #vim.tbl_filter(function(rec)
		return rec.headline == "add b4"
	end, vim.tbl_values(ledger.taken_by_id(ledger.read(r)))) == 1)
end

print("\n=== an edit's struck line deleted by hand declines it, named as the review ends ===")
do
	local r, nb, s = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- old line"), 0 })
	vim.cmd("normal! dd")
	changed(nb)
	assert_true("its decoration goes", spot_row(s, "rewrite the old line") == nil)
	vim.cmd("normal! u")
	changed(nb)
	assert_true("u brings it back with its line", spot_row(s, "rewrite the old line") ~= nil)
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- old line"), 0 })
	vim.cmd("normal! dd")
	changed(nb)
	local said = {}
	vim.notify = function(m)
		said[#said + 1] = m
	end
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_true("recorded declined", vim.tbl_contains(vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids)), "rewrite the old line"))
	assert_true("and named", #vim.tbl_filter(function(m)
		return m:match("declined %(rewrite the old line%)") ~= nil
	end, said) == 1)
	vim.notify = function() end
end

print("\n=== a take undone, then a decline: the decline is recorded ===")
do
	local r, nb = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.cmd("normal dp")
	vim.cmd("normal u")
	changed(nb)
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- stale"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gD"), "x", false)
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	local records = ledger.read(r)
	assert_eq("declined, not taken", { { "drop the stale line" }, 0 }, { vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(records).ids)), #vim.tbl_keys(ledger.taken_by_id(records)) })
end

print("\n=== the view key over typing: no false stop either way ===")
do
	local r, nb = setup()
	vim.api.nvim_feedkeys("Go- typed in one window\27", "xt", false)
	changed(nb)
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	local rb = review.open_review_buf(nb)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b4 added"), 0 })
	assert_true("declined in the split", review.decline(rb))
	local said = {}
	vim.notify = function(m)
		said[#said + 1] = m
	end
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_true("Q closes, no edit of the review's found", review.open_review_buf(nb) == nil and not vim.tbl_contains(said, "desk: " .. review.HAND_EDITS))
	assert_eq("recording the decline", { "add b4" }, vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids)))
	-- And back: typing in the split's notes window, then to one window.
	local nb2 = select(2, setup())
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(nb2))
	vim.api.nvim_feedkeys("Go- typed in the split\27", "xt", false)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(review.open_review_buf(nb2)))
	local ok, why = review.toggle_view(review.session_of(nb2))
	assert_true("back to one window over notes typed in the split (" .. tostring(why) .. ")", ok)
	vim.api.nvim_feedkeys("Q", "x", false)
	settle()
	assert_true("and Q closes there", review.open_review_buf(nb2) == nil)
	vim.notify = function() end
end

print("\n=== typing into or splitting a struck line is an edit, not a decline ===")
do
	for _, typing in ipairs({ "A, typed into", "0wi\r" }) do
		local r, nb = setup()
		vim.api.nvim_win_set_cursor(0, { line_of(nb, "- old line"), 0 })
		vim.cmd("normal! " .. typing)
		changed(nb)
		vim.api.nvim_feedkeys("Q", "x", false)
		settle()
		assert_eq(typing .. ": nothing declined", 0, #vim.tbl_keys(ledger.declined(ledger.read(r)).ids))
	end
end

print("\n=== dp on a struck line takes everything on it, an addition drawn there too ===")
do
	local _, nb = setup({ "A", "- a1", "- a2", "B", "- b1", "- b2" }, {
		item("x", { kind = "add", target = { after = "- a1" }, after = "- x" }),
		item("rm", { kind = "remove", target = { at = "- a2" }, before = "- a2", after = "" }),
		item("y", { kind = "add", target = { after = "- b1" }, after = "- y" }),
		item("rm2", { kind = "remove", target = { at = "- b2" }, before = "- b2", after = "" }),
	})
	vim.api.nvim_win_set_cursor(0, { line_of(nb, "- a2"), 0 })
	vim.cmd("normal 2dp")
	assert_eq("both on that line and both on the next", { "A", "- a1", "- x", "B", "- b1", "- y" }, lines_of(nb))
end

print("\n=== it stays quick on a long file ===")
do
	local notes = {}
	for i = 1, 400 do
		notes[#notes + 1] = (i % 12 == 0) and "" or ("- line " .. i .. " " .. string.rep("word ", i % 30))
	end
	local items = {}
	for i = 1, 10 do
		local at = notes[i * 30 + 1]
		if at ~= "" then
			items[#items + 1] = item("e" .. i, { kind = "edit", target = { at = at }, before = at, after = at .. " edited" })
		end
	end
	local _, nb, s = setup(notes, items)
	local t0 = vim.uv.hrtime()
	for _ = 1, 5 do
		vim.api.nvim_buf_set_lines(nb, 0, 1, false, { "- edited " .. vim.uv.hrtime() })
		changed(nb)
	end
	local ms = (vim.uv.hrtime() - t0) / 1e6 / 5
	print(string.format("     (an edit and its redraw: %.1f ms)", ms))
	assert_true("an edit and its redraw stay well under a tenth of a second", ms < 100)
	assert_true("still drawn", #s.view_spots > 0)
	review.view = "split"
end

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
