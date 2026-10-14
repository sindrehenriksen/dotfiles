-- The review's one-window view (desk.inline, desk.review with view
-- "inline"), headless against throwaway repos: what it draws, and that
-- take, decline, n/N, undo, the save, the overview, the view key and `:q`
-- work in it as they do in the split.
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
local function setup(items)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	local r = new_repo(BASE)
	assert(proposal.build(r, "morning", "2026-10-01", items or ITEMS, FILES))
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	review.view = "inline"
	assert(review.open_review(nb))
	return r, nb, review.open_review_buf(nb)
end

-- The view's extmarks on `buf`, as { row (1-based), virt lines' text,
-- line highlight, eol label }.
local function marks(buf)
	local out = {}
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, inline.NS, 0, -1, { details = true })) do
		local d = m[4]
		local e = { row = m[2] + 1 }
		if d.virt_lines then
			e.virt = {}
			for _, vl in ipairs(d.virt_lines) do
				local t = {}
				for _, chunk in ipairs(vl) do
					t[#t + 1] = chunk[1]
				end
				e.virt[#e.virt + 1] = table.concat(t)
			end
			e.above = d.virt_lines_above or false
		end
		e.hl = d.line_hl_group
		if d.virt_text then
			e.label = d.virt_text[1][1]
		end
		out[#out + 1] = e
	end
	return out
end

local function find(ms, pred)
	for _, m in ipairs(ms) do
		if pred(m) then
			return m
		end
	end
end

print("=== the split is the default; one window is the view key away ===")
assert_eq("a review opens as the split", "split", review.view)
do
	local reply = { review.toggle_view(0) }
	assert_eq("and the view key says the one window is coming back", { false, review.VIEW_COMING }, reply)
end
-- What follows tests the one window itself, the key switched back on.
review.view_key_off = false

print("\n=== one window: the merged text with each suggestion's old lines drawn above its new ones ===")
do
	local _, nb, rb = setup()
	assert_eq("one window", "leaf", vim.fn.winlayout()[1])
	assert_eq("showing the review", rb, vim.api.nvim_get_current_buf())
	assert_true("not in diff mode", not vim.wo.diff)
	assert_true("the notes stay loaded behind it", vim.api.nvim_buf_is_loaded(nb) and #vim.fn.win_findbuf(nb) == 0)
	local ms = marks(rb)
	local new_row = line_of(rb, "- new line")
	local old = find(ms, function(m)
		return m.virt and m.row == new_row
	end)
	assert_eq("an edit's old line is drawn directly above its new one", { { "- old line" }, true }, { old and old.virt, old and old.above })
	assert_true("its new line is highlighted", find(ms, function(m)
		return m.row == new_row and m.hl == "DeskInlineNew"
	end))
	assert_true("with its headline beside it", find(ms, function(m)
		return m.row == new_row and m.label and m.label:match("rewrite the old line")
	end))
	local add_row = line_of(rb, "- b4 added")
	assert_true("an added line is highlighted, with its headline", find(ms, function(m)
		return m.row == add_row and m.hl == "DeskInlineNew"
	end) and find(ms, function(m)
		return m.row == add_row and m.label and m.label:match("add b4")
	end))
	local removed = find(ms, function(m)
		return m.virt and m.virt[1]:match("^%- stale")
	end)
	assert_true("a removed line hangs, struck, under the line before it, its headline on it", removed
		and removed.row == line_of(rb, "- b1")
		and not removed.above
		and removed.virt[1]:match("drop the stale line"))
	assert_true("the bar names the view's keys and the toggle", vim.wo.winbar:match("^" .. vim.pesc(review.INLINE_KEY_HINT)))
end

print("\n=== n/N, take, decline and undo in one window ===")
do
	local r, nb, rb = setup()
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	vim.cmd("normal n")
	assert_eq("n goes to the first suggestion", line_of(rb, "- new line"), vim.api.nvim_win_get_cursor(win)[1])
	vim.cmd("normal n")
	vim.cmd("normal n")
	vim.cmd("normal n")
	assert_eq("and wraps round to it after the last", line_of(rb, "- new line"), vim.api.nvim_win_get_cursor(win)[1])
	vim.cmd("normal N")
	assert_eq("N goes back, wrapping to the last", line_of(rb, "- b4 added"), vim.api.nvim_win_get_cursor(win)[1])

	vim.api.nvim_win_set_cursor(win, { line_of(rb, "- new line"), 0 })
	vim.cmd("normal dp")
	assert_true("dp takes the edit into the notes", line_of(nb, "- new line") and not line_of(nb, "- old line"))
	assert_true("and its old line is no longer drawn", not find(marks(rb), function(m)
		return m.virt and m.virt[1] == "- old line"
	end))
	vim.cmd("normal u")
	assert_true("u undoes the take", line_of(nb, "- old line") and not line_of(nb, "- new line"))
	assert_true("and it is drawn again", find(marks(rb), function(m)
		return m.virt and m.virt[1] == "- old line"
	end))

	vim.api.nvim_win_set_cursor(win, { line_of(rb, "- b4 added"), 0 })
	assert_true("␣gD declines the line under the cursor", review.decline(rb) and not line_of(rb, "- b4 added"))
	vim.cmd("normal u")
	assert_true("u undoes the decline", line_of(rb, "- b4 added"))
	review.decline(rb)
	vim.api.nvim_win_set_cursor(win, { line_of(rb, "- b1"), 0 })
	assert_true("␣gA takes the removal its lines hang under", review.take(rb) and not line_of(nb, "- stale"))
	vim.cmd("silent write")
	local declined = vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.declined(ledger.read(r)).ids))
	assert_eq("the save records the decline", { "add b4" }, declined)
end

print("\n=== the overview previews and acts in one window ===")
do
	local _, nb, rb = setup()
	local rw = vim.api.nvim_get_current_win()
	assert_true("the overview opens", review.overview(nb))
	assert_eq("a list above the one view", 2, #vim.api.nvim_tabpage_list_wins(0))
	local qw = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(qw, { 2, 0 })
	review.qf_preview()
	assert_eq("moving in the list shows the entry in the view: a removal at the line below its removed lines", line_of(rb, "- b3"), vim.api.nvim_win_get_cursor(rw)[1])
	vim.cmd("normal t")
	assert_true("t takes it", not line_of(nb, "- stale"))
	vim.cmd("normal x")
	assert_true("x declines the next one", not line_of(rb, "- b4 added"))
	review.confirm = function()
		return 1
	end
	vim.cmd("normal Q")
	assert_true("Q ends the review, saving the decline", review.open_review_buf(nb) == nil)
	assert_eq("leaving the notes in the window", nb, vim.api.nvim_win_get_buf(vim.fn.win_findbuf(nb)[1]))
end

print("\n=== the view key switches to two windows and back, and is remembered ===")
do
	local _, nb, rb = setup()
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(win, { line_of(rb, "- b4 added"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	assert_eq("two windows", "col", vim.fn.winlayout()[1])
	assert_true("both in diff mode", vim.wo[vim.fn.bufwinid(rb)].diff and vim.wo[vim.fn.bufwinid(nb)].diff)
	assert_true("nothing drawn in the split", #marks(rb) == 0)
	assert_eq("remembered", "split", review.view)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b4 added"), 0 })
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	assert_eq("back to one window", "leaf", vim.fn.winlayout()[1])
	assert_true("out of diff mode", not vim.wo.diff)
	assert_eq("the cursor where it was", line_of(rb, "- b4 added"), vim.api.nvim_win_get_cursor(0)[1])
	assert_true("drawn again", #marks(rb) > 0)
	assert_eq("and remembered", "inline", review.view)
end

print("\n=== :q in one window ends the review and leaves the notes showing ===")
do
	local _, nb, rb = setup()
	vim.cmd("q")
	vim.wait(20, function()
		return false
	end)
	assert_true("the review is gone", not vim.api.nvim_buf_is_valid(rb))
	assert_true("nvim is still here, the notes in a window", #vim.fn.win_findbuf(nb) == 1)
end

print("\n=== closing the view's window another way brings the notes back ===")
do
	local _, nb, rb = setup()
	vim.cmd("botright new")
	local other = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.cmd("close")
	vim.wait(20, function()
		return false
	end)
	assert_true("the review is gone", not vim.api.nvim_buf_is_valid(rb))
	assert_true("the notes show again", #vim.fn.win_findbuf(nb) == 1)
	assert_true("and the other window is left as it was", vim.api.nvim_win_is_valid(other))
end

print("\n=== the review moves to the other file in one window ===")
do
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	local r = new_repo(BASE)
	write(r, "reading.md", { "- a paper" })
	assert(git.run(r, { "commit", "-qam", "reading" }))
	assert(proposal.build(r, "morning", "2026-10-01", {
		item("n1", { after = "NEWS n1" }),
		item("p1", { file = "reading.md", after = "- another paper" }),
	}, FILES))
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	review.view = "inline"
	assert(review.open_review(nb))
	local rb = review.open_review_buf(nb)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal dp")
	assert_true("the review moves there", review.switch_review(rb))
	local rd = vim.fn.bufnr(r .. "/reading.md")
	local rb2 = review.open_review_buf(rd)
	assert_true("in one window, drawn", rb2 and vim.fn.winlayout()[1] == "leaf" and vim.api.nvim_get_current_buf() == rb2 and #marks(rb2) > 0)
end

-- Opens a review in one window over `notes` and `items`.
local function review_of(notes, items)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("silent! only")
	local r = new_repo(notes)
	assert(proposal.build(r, "morning", "2026-10-01", items, FILES))
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	review.view = "inline"
	assert(review.open_review(nb))
	return r, nb, review.open_review_buf(nb)
end

print("\n=== each suggestion keeps its own old lines and headline, adjacent ones too ===")
do
	local _, _, rb = review_of({ "A", "- one", "- two", "- keep", "- gone", "- tail" }, {
		item("e1", { kind = "edit", target = { at = "- one" }, before = "- one", after = "- ONE", headline = "first" }),
		item("e2", { kind = "edit", target = { at = "- two" }, before = "- two", after = "- TWO", headline = "second" }),
		item("rm", { kind = "remove", target = { at = "- gone" }, before = "- gone", after = "", headline = "drop" }),
		item("ad", { kind = "add", target = { after = "- keep" }, after = "- added", headline = "add" }),
	})
	local ms = marks(rb)
	local function virt_at(row)
		local out = {}
		for _, m in ipairs(ms) do
			if m.virt and m.row == row then
				vim.list_extend(out, m.virt)
			end
		end
		return out
	end
	assert_eq("two adjacent edits: each old line above its own new one", { { "- one" }, { "- two" } }, { virt_at(line_of(rb, "- ONE")), virt_at(line_of(rb, "- TWO")) })
	assert_eq("a removal beside an add keeps its own struck line and headline", { "- gone  « drop" }, virt_at(line_of(rb, "- keep")))
	assert_true("and the add its own headline", find(ms, function(m)
		return m.row == line_of(rb, "- added") and m.label and m.label:match("add$")
	end))
end

print("\n=== a removal on the first line is drawn above it; dp from either side of a removal ===")
do
	local _, nb, rb = review_of({ "- first", "- second", "- last" }, {
		item("r1", { kind = "remove", target = { at = "- first" }, before = "- first", after = "", headline = "drop first" }),
		item("r3", { kind = "remove", target = { at = "- last" }, before = "- last", after = "", headline = "drop last" }),
	})
	local top = find(marks(rb), function(m)
		return m.virt and m.virt[1]:match("^%- first")
	end)
	assert_eq("above line 1", { 1, true }, { top and top.row, top and top.above })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal dp")
	assert_true("dp on the line below a removal takes it", not line_of(nb, "- first"))
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- second"), 0 })
	vim.cmd("normal dp")
	assert_true("dp on the line a removal hangs under takes it, at the end of the file", not line_of(nb, "- last"))
end

print("\n=== n from a suggestion's own line goes to the next; dp takes it whole, recorded on the save ===")
do
	local r, nb, rb = review_of({ "A", "- a1", "", "B", "- b1", "- b2", "- b9", "", "C", "- c1" }, {
		item("n1", { kind = "add", target = { after = "- a1" }, after = "- a2", headline = "a2" }),
		item("mv", { kind = "move", target = { { at = "- b2" }, { after = "- c1" } }, before = "- b2", after = "- b2", headline = "move b2" }),
		item("n3", { kind = "add", target = { after = "- b9" }, after = "- b3", headline = "b3" }),
	})
	local rows = review.inline_rows(review.session_of(nb))
	vim.api.nvim_win_set_cursor(0, { rows[1], 0 })
	vim.cmd("normal n")
	assert_eq("n from a hunk's row goes to the next hunk", rows[2], vim.api.nvim_win_get_cursor(0)[1])
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b2"), 0 })
	vim.cmd("normal dp")
	assert_true("dp on a move's landing takes both its places", line_of(nb, "- b2") == line_of(nb, "- c1") + 1 and #vim.tbl_filter(function(l)
		return l == "- b2"
	end, lines_of(nb)) == 1)
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- a2"), 0 })
	vim.cmd("normal dp")
	vim.api.nvim_buf_call(nb, function()
		vim.cmd("silent write")
	end)
	local taken = vim.tbl_map(function(rec)
		return rec.headline
	end, vim.tbl_values(ledger.taken_by_id(ledger.read(r))))
	table.sort(taken)
	assert_eq("the takes are recorded once the notes are saved", { "a2", "move b2" }, taken)
end

print("\n=== a count on dp takes that many hunks from the cursor down ===")
do
	local _, nb, rb = review_of({ "- a1", "- a2", "- a3", "- a4" }, {
		item("x", { kind = "add", target = { after = "- a1" }, after = "- x" }),
		item("y", { kind = "add", target = { after = "- a3" }, after = "- y" }),
		item("z", { kind = "add", target = "top", after = "- z" }),
	})
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- x"), 0 })
	vim.cmd("normal 2dp")
	assert_eq("2dp: the one under the cursor and the next, not the one above", { "- a1", "- x", "- a2", "- a3", "- y", "- a4" }, lines_of(nb))
end

print("\n=== dp into an empty notes file leaves no extra line ===")
do
	local _, nb = review_of({}, { item("n1", { kind = "new", target = "top", after = "NEWS n1" }) })
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal dp")
	assert_eq("just the suggestion", { "NEWS n1" }, lines_of(nb))
end

print("\n=== <CR> in the overview jumps to the suggestion in one window ===")
do
	local _, nb, rb = setup()
	local rw = vim.api.nvim_get_current_win()
	assert_true("the overview opens", review.overview(nb))
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	review.qf_jump()
	assert_eq("in the view's window", rw, vim.api.nvim_get_current_win())
	assert_eq("on the entry's line", line_of(rb, "- b4 added"), vim.api.nvim_win_get_cursor(rw)[1])
end

print("\n=== :q over unsaved declines stops as the split does; :q! ends the review ===")
do
	local r, nb, rb = setup()
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b4 added"), 0 })
	review.decline(rb)
	local ok = pcall(vim.cmd, "q")
	vim.wait(20, function()
		return false
	end)
	assert_eq("the quit is refused (E37)", false, ok)
	assert_eq("with no window added", 1, #vim.api.nvim_tabpage_list_wins(0))
	assert_true("and the review open", vim.api.nvim_buf_is_valid(rb) and #vim.fn.win_findbuf(nb) == 0)
	vim.cmd("q!")
	vim.wait(20, function()
		return false
	end)
	assert_true(":q! ends the review, its declines dropped", not vim.api.nvim_buf_is_valid(rb) and next(ledger.declined(ledger.read(r)).ids) == nil)
	assert_eq("leaving the notes in the one window, nvim still running", { 1, 1 }, { #vim.api.nvim_tabpage_list_wins(0), #vim.fn.win_findbuf(nb) })
end

print("\n=== an ended review leaves nothing behind ===")
do
	local function count()
		return #vim.api.nvim_get_autocmds({ event = "WinClosed" })
	end
	local nb = select(2, setup())
	review.close_review(review.session_of(nb))
	vim.wait(20, function()
		return false
	end)
	local after_one = count()
	for _ = 1, 3 do
		nb = select(2, setup())
		review.close_review(review.session_of(nb))
		vim.wait(20, function()
			return false
		end)
	end
	assert_eq("no window watch stays per review", after_one, count())
	assert_eq("the notes' 'bufhidden' is theirs again", "", vim.bo[nb].bufhidden)
end

print("\n=== after the toggle to one window nothing folds; edits in the view count ===")
do
	local _, nb, rb = setup()
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	local closed = false
	for l = 1, vim.api.nvim_buf_line_count(rb) do
		closed = closed or vim.fn.foldclosed(l) ~= -1
	end
	assert_true("no diff folds left", vim.wo.foldmethod ~= "diff" and not closed)
	local s = review.session_of(nb)
	local before = review.left(s)
	vim.api.nvim_win_set_cursor(0, { line_of(rb, "- b4 added"), 0 })
	vim.cmd("normal! dd")
	assert_eq("deleting a suggestion's line in the view takes it off the count", before - 1, review.left(s))
end

print("\n=== the status line counts what is deferred, with the view open ===")
do
	local _, nb = review_of({ "A", "- keep" }, {
		item("e1", { kind = "edit", target = { at = "- keep" }, before = "- keep", after = "- kept" }),
		item("e2", { kind = "edit", target = { at = "- keep" }, before = "- keep", after = "- changed" }),
	})
	assert_true("1 deferred", review.status_line(nb):match("1 deferred") ~= nil)
end

print("\n=== removed lines wrap to the window, unicode and all ===")
do
	local long = string.rep("æøå ", 40) .. "slutt"
	local pieces = inline.wrap(long, 30)
	local fits = true
	for _, p in ipairs(pieces) do
		fits = fits and vim.fn.strdisplaywidth(p) <= 30
	end
	assert_true("into pieces that fit", #pieces > 1 and fits)
	assert_eq("and lose nothing", long, table.concat(pieces))
	assert_true("cut at spaces", pieces[1]:sub(-1) == " ")
	local _, _, rb = review_of({ "A", "- " .. long }, {
		item("e", { kind = "edit", target = { at = "- " .. long }, before = "- " .. long, after = "- kort" }),
	})
	local old = find(marks(rb), function(m)
		return m.virt and m.row == line_of(rb, "- kort")
	end)
	assert_true("a long removed line is drawn on several lines", old and #old.virt > 1)
end

print("\n=== removing every line, or your own edit at the top, is drawn above line 1 ===")
do
	local _, _, rb = review_of({ "- only" }, {
		item("r", { kind = "remove", target = { at = "- only" }, before = "- only", after = "", headline = "drop it" }),
	})
	local m = find(marks(rb), function(x)
		return x.virt
	end)
	assert_eq("an emptied review hangs the line above its one row", { 1, true, "- only  « drop it" }, { m and m.row, m and m.above, m and m.virt[1] })
	local _, nb2, rb2 = setup()
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	vim.cmd("normal! dd")
	review.render_inline(review.session_of(nb2))
	local top = find(marks(rb2), function(x)
		return x.virt and x.virt[1] == "Section A"
	end)
	assert_eq("your own deletion of the first line is drawn above line 1", { 1, true }, { top and top.row, top and top.above })
end

print("\n=== with 'nohidden' the notes still stay behind the view; the toggle leaves no diff state ===")
do
	local diffopt = vim.o.diffopt
	vim.cmd("silent! %bwipeout!")
	local r = new_repo(BASE)
	assert(proposal.build(r, "morning", "2026-10-01", ITEMS, FILES))
	vim.o.hidden = false
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	vim.api.nvim_buf_set_lines(nb, 0, 0, false, { "- mine" })
	review.view = "inline"
	assert_true("the review opens over modified notes", review.open_review(nb))
	local rb = review.open_review_buf(nb)
	assert_true("which stay loaded and modified behind it", vim.api.nvim_get_current_buf() == rb and vim.api.nvim_buf_is_loaded(nb) and vim.bo[nb].modified)
	vim.o.hidden = true
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.api.nvim_feedkeys(vim.keycode("<leader>gv"), "x", false)
	assert_true("back in one window, nothing bound or diffed", not vim.wo.diff and not vim.wo.scrollbind and not vim.wo.cursorbind)
	assert_eq("and the diff context left as it was", diffopt, vim.o.diffopt)
	vim.bo[nb].modified = false
end

print("\n=== drawing stays fast on a long file ===")
do
	local notes = {}
	for i = 1, 600 do
		notes[#notes + 1] = (i % 12 == 0) and "" or ("- line " .. i .. " " .. string.rep("word ", i % 30))
	end
	local items = {}
	for i = 1, 40 do
		local at = notes[i * 14 + 1]
		if at ~= "" then
			items[#items + 1] = item("e" .. i, { kind = "edit", target = { at = at }, before = at, after = at .. " edited", headline = "edit " .. i })
		end
	end
	vim.cmd("silent! %bwipeout!")
	local r = new_repo(notes)
	assert(proposal.build(r, "morning", "2026-10-01", items, FILES))
	vim.cmd("edit " .. vim.fn.fnameescape(r .. "/notes.md"))
	local nb = vim.api.nvim_get_current_buf()
	review.attach(nb)
	review.view = "inline"
	assert(review.open_review(nb))
	local function time(f)
		local t0 = vim.uv.hrtime()
		for _ = 1, 10 do
			f()
		end
		return (vim.uv.hrtime() - t0) / 1e6 / 10
	end
	local draw = time(function()
		review.render_inline(review.session_of(nb))
	end)
	local refresh = time(function()
		review.refresh_status_line(nb)
	end)
	review.view = "split"
	print(string.format("     (drawing: %.1f ms; a whole refresh with it: %.1f ms)", draw, refresh))
	assert_true("drawing the view takes a few milliseconds", draw < 20)
end

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
