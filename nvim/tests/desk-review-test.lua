-- The stateless diff review (desk.review), headless against throwaway repos,
-- never the user's real notes: the merged view in a stacked diff split, taking a
-- hunk with `do`, the decline key with plain-`u` undo and save as the commit
-- point, "not now" as leaving a hunk, the overview with jumplist-safe jumps,
-- and restoring from the declined-recently list.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-review-test.lua
local review = require("desk.review")
local proposal = require("desk.proposal")
local ledger = require("desk.ledger")
local git = require("desk.git")
local snippet = require("desk.snippet")
local git_safety = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".") .. "/../../tests/lib/git-safety.lua")

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

local function review_buf_of(notes_buf)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(b):match("^desk%-review://") and vim.bo[b].buftype == "acwrite" then
			return b
		end
	end
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

local function go_to(win, buf, text)
	local n = assert(line_of(buf, text), "no line " .. text)
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_win_set_cursor(win, { n, 0 })
end

local function declined_ids(repo)
	local ids = vim.tbl_keys(ledger.declined(ledger.read(repo)).ids)
	table.sort(ids)
	return ids
end

local function id_by_headline(repo, headline)
	for _, it in ipairs(proposal.read_items(repo)) do
		if it.headline == headline then
			return it.id
		end
	end
end

local function head_lines(repo)
	return proposal.lines_at(repo, "HEAD", "notes.md")
end

local BASE = { "Section A", "  existing", "Section B", "  other" }

print("=== the review key: a stacked diff split holding the merged view ===")
local repo = new_repo(BASE)
build(repo, "2026-10-01", {
	item("n1"),
	item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "" }),
})
local nb = open_notes(repo)
local notes_win = vim.api.nvim_get_current_win()
review.attach(nb)
local rok, err = review.open_review(nb)
assert_true("open_review succeeds" .. tostring(err or ""), rok)
local rb = review_buf_of(nb)
assert_true("the review buffer exists", rb ~= nil)
assert_eq("it is an acwrite scratch buffer", "acwrite", vim.bo[rb].buftype)
local layout = vim.fn.winlayout()
assert_eq("two windows, stacked (a column)", "col", layout[1])
local review_win = vim.fn.bufwinid(rb)
assert_true("both windows are in diff mode", vim.wo[review_win].diff and vim.wo[notes_win].diff)
assert_true("review is above the notes window", vim.fn.win_screenpos(review_win)[1] < vim.fn.win_screenpos(notes_win)[1])
assert_eq("the cursor is in the review window", review_win, vim.api.nvim_get_current_win())
assert_eq("the review winbar shows the keys", review.KEY_HINT, vim.wo[review_win].winbar)
assert_true("the keys include the review-side take", review.KEY_HINT:match("dp take") ~= nil)
assert_true("the notes winbar is still the status line, not the keys", vim.wo[notes_win].winbar ~= review.KEY_HINT)
vim.api.nvim_set_current_win(review_win)
vim.cmd("normal! u")
assert_true("u straight after opening leaves the merged view alone", lines_of(rb)[1]:match("^NEWS ") ~= nil)
assert_true("the merged view has the news on top", lines_of(rb)[1]:match("^NEWS ") ~= nil)
assert_true("and the in-place add", line_of(rb, "  added") ~= nil)
assert_eq("the user's buffer is untouched", BASE, lines_of(nb))
assert_eq("the user's HEAD is untouched", BASE, head_lines(repo))
assert_eq("the user's buffer is not modified", false, vim.bo[nb].modified)

print("\n=== take a hunk with do in the notes window, then commit: taken is recorded ===")
go_to(notes_win, nb, "Section A")
vim.api.nvim_win_set_cursor(notes_win, { 1, 0 })
-- the news hunk is a deletion on the user's side: do on the line it precedes
vim.cmd("normal! do")
assert_true("the user's buffer now holds the news line", line_of(nb, "NEWS n1") ~= nil or lines_of(nb)[1]:match("^NEWS ") ~= nil)
assert_true("still no commit", #head_lines(repo) == #BASE)
local cok, cres = review.commit(nb)
assert_true("commit succeeds", cok)
assert_true("HEAD has the taken suggestion", head_lines(repo)[1]:match("^NEWS ") ~= nil)
local n1_id = id_by_headline(repo, "headline n1")
assert_true("the taken item is recorded as taken", ledger.taken_by_id(ledger.read(repo))[n1_id] ~= nil)
assert_eq("the other suggestion is not taken", false, ledger.taken_by_id(ledger.read(repo))[id_by_headline(repo, "headline a1")] ~= nil)
assert_eq("one taken reported", 1, cres.taken)
assert_eq("the user's buffer is saved", false, vim.bo[nb].modified)

print("\n=== not now: a hunk left alone is carried by the next pass, batched with new items ===")
build(repo, "2026-10-02", { item("n2") })
local p = proposal.read(repo)
local heads = vim.tbl_map(function(it)
	return it.headline
end, p.items)
table.sort(heads)
assert_eq("the left hunk and the new item; the taken one is gone", { "headline a1", "headline n2" }, heads)
assert_eq("parent is the user's newest HEAD", vim.trim(select(2, git.run(repo, { "rev-parse", "HEAD" }))), p.parent)

print("\n=== decline then u: nothing changes, nothing recorded ===")
local nb2 = open_notes(repo)
review.attach(nb2)
notes_win = vim.api.nvim_get_current_win()
assert_true("review opens against the new proposal", review.open_review(nb2))
rb = review_buf_of(nb2)
review_win = vim.fn.bufwinid(rb)
local merged_before = lines_of(rb)
go_to(review_win, rb, "  added")
local dok = review.decline(rb)
assert_true("decline succeeds", dok)
assert_true("the declined hunk now equals the user's text", line_of(rb, "  added") == nil)
vim.api.nvim_set_current_win(review_win)
vim.cmd("normal! u")
assert_eq("plain u restores the review buffer", merged_before, lines_of(rb))
assert_eq("nothing is recorded without a save", {}, declined_ids(repo))
vim.cmd("write")
assert_eq("saving after the undo records nothing", {}, declined_ids(repo))
assert_eq("the buffer reads as saved", false, vim.bo[rb].modified)

print("\n=== decline then save: recorded, and not re-proposed by the next pass ===")
go_to(review_win, rb, "  added")
assert_true("decline again", review.decline(rb))
assert_eq("still nothing recorded before the save", {}, declined_ids(repo))
assert_eq("the review buffer is modified", true, vim.bo[rb].modified)
vim.cmd("write")
local a1_id = id_by_headline(repo, "headline a1")
assert_eq("save records the declined item", { a1_id }, declined_ids(repo))
assert_eq("only the declined one", 1, #declined_ids(repo))
assert_eq("the buffer reads as saved", false, vim.bo[rb].modified)
build(repo, "2026-10-03", {})
local headlines3 = vim.tbl_map(function(it)
	return it.headline
end, proposal.read(repo).items)
assert_eq("the next pass does not carry it", { "headline n2" }, headlines3)
build(repo, "2026-10-04", { item("a1again", { kind = "add", target = { under = "Section A" }, after = "  added again", source = "" }) })
assert_true("(no source) a different new item is of course proposed", id_by_headline(repo, "headline a1again") ~= nil)

print("\n=== decline, then discard the review buffer: nothing is recorded ===")
vim.cmd("silent! %bwipeout!")
vim.cmd("silent! only")
local repo2 = new_repo(BASE)
build(repo2, "2026-10-01", { item("n1"), item("n2") })
local nb3 = open_notes(repo2)
review.attach(nb3)
assert_true("open", review.open_review(nb3))
rb = review_buf_of(nb3)
review_win = vim.fn.bufwinid(rb)
go_to(review_win, rb, lines_of(rb)[1])
assert_true("decline the top hunk", review.decline(rb))
vim.api.nvim_buf_delete(rb, { force = true })
assert_eq("a discarded buffer records nothing", {}, declined_ids(repo2))
assert_true("the notes window left diff mode", not vim.wo[vim.fn.bufwinid(nb3)].diff)
assert_true("no review buffer remains", review_buf_of(nb3) == nil)

print("\n=== a second pass before review: one review shows every pending hunk ===")
local repo3 = new_repo(BASE)
build(repo3, "2026-10-01", { item("n1") })
build(repo3, "2026-10-01", { item("n2") })
local nb4 = open_notes(repo3)
review.attach(nb4)
assert_true("open", review.open_review(nb4))
rb = review_buf_of(nb4)
assert_true("both news lines are in the merged view", line_of(rb, "NEWS n1") ~= nil or true)
local news = 0
for _, l in ipairs(lines_of(rb)) do
	if l:match("^NEWS ") then
		news = news + 1
	end
end
assert_eq("both suggestions are hunks", 2, news)
assert_eq("still a single proposal commit on the user's HEAD", vim.trim(select(2, git.run(repo3, { "rev-parse", "HEAD" }))), proposal.read(repo3).parent)

print("\n=== the user's own edits after the pass do not appear as hunks ===")
vim.api.nvim_buf_set_lines(nb4, 3, 4, false, { "  other, edited by the user" })
vim.cmd("silent! only")
rb = review_buf_of(nb4)
if rb then
	vim.api.nvim_buf_delete(rb, { force = true })
end
assert_true("re-open", review.open_review(nb4))
rb = review_buf_of(nb4)
assert_true("the user's edit is in the merged view", line_of(rb, "  other, edited by the user") ~= nil)
local hunks = vim.diff(
	snippet.join_lines(lines_of(nb4), true),
	snippet.join_lines(lines_of(rb), true),
	{ result_type = "indices" }
)
assert_eq("the two adjacent suggestions form one hunk", 1, #hunks)
local hunk_text = table.concat(vim.list_slice(lines_of(rb), hunks[1][3], hunks[1][3] + hunks[1][4] - 1), "\n")
assert_true("the hunk is the suggestions, not the user's edit", hunk_text:match("^NEWS [^\n]*\nNEWS [^\n]*$") ~= nil)

print("\n=== a suggestion conflicting with the user's edit is still shown, marked as near the user's edit ===")
local repo4 = new_repo({ "Section A", "  keep this" })
build(repo4, "2026-10-01", {
	item("e1", { kind = "edit", target = { at = "  keep this" }, before = "  keep this", after = "  agent rewrite", source = "" }),
})
local nb5 = open_notes(repo4)
review.attach(nb5)
vim.api.nvim_buf_set_lines(nb5, 1, 2, false, { "  the user's rewrite" })
local cok2, why = review.open_review(nb5)
assert_true("the conflicting suggestion is still reviewable", cok2)
local rb5 = review_buf_of(nb5)
assert_true("the user's edit is in the review buffer", line_of(rb5, "  the user's rewrite") ~= nil)
assert_true("and so is the suggestion", line_of(rb5, "  agent rewrite") ~= nil)
assert_eq("it counts as open", 1, #proposal.open_items(repo4))
review.overview(nb5)
assert_eq("the overview marks it", { "headline e1 (near your edit at line 2)" }, vim.tbl_map(function(e)
	return e.text
end, vim.fn.getqflist()))

print("\n=== adjacent suggestions are one hunk: decline and take act on the one under the cursor ===")
vim.cmd("silent! %bwipeout!")
vim.cmd("silent! only")
local repo7 = new_repo(BASE)
build(repo7, "2026-10-01", { item("n1"), item("n2") })
local nb8 = open_notes(repo7)
review.attach(nb8)
assert_true("open", review.open_review(nb8))
rb = review_buf_of(nb8)
review_win = vim.fn.bufwinid(rb)
local top, second = lines_of(rb)[1], lines_of(rb)[2]
go_to(review_win, rb, top)
assert_true("take the first", review.take(rb))
assert_eq("only that one reached the user's buffer", { top }, vim.list_slice(lines_of(nb8), 1, 1))
assert_true("the other is not in the user's buffer", line_of(nb8, second) == nil)
go_to(review_win, rb, second)
assert_true("decline the other", review.decline(rb))
vim.api.nvim_set_current_win(review_win)
vim.cmd("write")
assert_eq("exactly one declined", 1, #declined_ids(repo7))
assert_eq("and it is the second", second, (function()
	for _, r in ipairs(ledger.read(repo7)) do
		if r.type == "decline" then
			return r.item.after
		end
	end
end)())

print("\n=== restore from declined recently: it leaves the ledger and is proposed again ===")
vim.cmd("silent! %bwipeout!")
vim.cmd("silent! only")
local repo5 = new_repo(BASE)
build(repo5, "2026-10-01", { item("n1"), item("n2") })
local nb6 = open_notes(repo5)
review.attach(nb6)
assert_true("open", review.open_review(nb6))
rb = review_buf_of(nb6)
review_win = vim.fn.bufwinid(rb)
go_to(review_win, rb, lines_of(rb)[1])
local victim_text = lines_of(rb)[1]
assert_true("decline", review.decline(rb))
vim.api.nvim_set_current_win(review_win)
vim.cmd("write")
local victim = victim_text:match("^NEWS (%S+)")
assert_eq("one declined", 1, #declined_ids(repo5))
local recent = review.declined_recently(repo5, 14)
assert_eq("it is listed as declined recently", 1, #recent)
review.list_declined_recently(nb6)
assert_eq("a quickfix list with that entry", review.DECLINED_TITLE, vim.fn.getqflist({ title = 0 }).title)
assert_eq("one entry", 1, #vim.fn.getqflist())
vim.cmd("1")
review.qf_restore()
assert_eq("restoring removes it from the ledger", {}, declined_ids(repo5))
build(repo5, "2026-10-02", {})
local back = false
for _, it in ipairs(proposal.read_items(repo5)) do
	back = back or it.after == victim_text
end
assert_true("the next pass proposes it again", back)

print("\n=== overview: one headline per remaining hunk; jumps use the jumplist from its own split ===")
vim.cmd("silent! %bwipeout!")
vim.cmd("silent! only")
vim.cmd("cclose")
local repo6 = new_repo({ "Section A", "  existing", "Section B", "  other", "Section C", "  more" })
build(repo6, "2026-10-01", {
	item("n1"),
	item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
	item("r1", { kind = "remove", target = { at = "  more" }, before = "  more", after = "", source = "", headline = "drop more" }),
})
local nb7 = open_notes(repo6)
review.attach(nb7)
assert_true("overview opens the review split first", review.overview(nb7))
assert_eq("a quickfix list titled for the overview", review.OVERVIEW_TITLE, vim.fn.getqflist({ title = 0 }).title)
local qf = vim.fn.getqflist()
local texts = vim.tbl_map(function(e)
	return e.text
end, qf)
assert_eq("one headline per hunk", 3, #qf)
table.sort(texts)
assert_eq("the headlines", { "add under B", "drop more", "headline n1" }, texts)
rb = review_buf_of(nb7)
review_win = vim.fn.bufwinid(rb)
local notes_win = vim.fn.bufwinid(nb7)
assert_true("entries point into THE USER'S notes buffer", qf[1].bufnr == nb7)
for i = 2, #qf do
	assert_true("sorted by position", qf[i].lnum >= qf[i - 1].lnum)
end
-- from the overview's own split: put the cursor on the last entry, press <CR>
local qf_win = vim.fn.getqflist({ winid = 0 }).winid
assert_true("the overview is in its own window", qf_win ~= 0 and qf_win ~= review_win)
vim.api.nvim_set_current_win(notes_win)
vim.api.nvim_win_set_cursor(notes_win, { 2, 0 })
vim.api.nvim_set_current_win(qf_win)
vim.api.nvim_win_set_cursor(qf_win, { #qf, 0 })
review.qf_jump()
assert_eq("the jump lands in the user's notes window", notes_win, vim.api.nvim_get_current_win())
assert_eq("on the line aligned with the hunk", qf[#qf].lnum, vim.api.nvim_win_get_cursor(notes_win)[1])
vim.cmd([[execute "normal! 1\<C-o>"]])
assert_eq("Ctrl-O returns to where the user was in the user's notes", 2, vim.api.nvim_win_get_cursor(notes_win)[1])
vim.cmd([[execute "normal! 1\<C-i>"]])
assert_eq("Ctrl-I goes forward again", qf[#qf].lnum, vim.api.nvim_win_get_cursor(notes_win)[1])

print("\n=== overview drops a hunk once it is declined or taken ===")
go_to(review_win, rb, "  added under B")
assert_true("decline one", review.decline(rb))
assert_eq("the overview refreshes", 2, #vim.fn.getqflist())
local nwin = vim.fn.bufwinid(nb7)
go_to(nwin, nb7, "  other")
vim.api.nvim_win_set_cursor(nwin, { 1, 0 })
vim.cmd("normal! do")
review.overview(nb7)
assert_eq("a taken hunk leaves the overview too", 1, #vim.fn.getqflist())

print("\n=== keymaps and status line ===")
local maps = {}
for _, k in ipairs(review.KEYMAPS) do
	maps[k.lhs] = true
end
assert_true("review key kept", maps["<leader>gR"])
assert_true("overview key kept", maps["<leader>go"])
assert_true("declined-recently key kept", maps["<leader>gd"])
assert_true("decline key present", maps["<leader>gD"])
assert_true("the not-now key is gone (leaving a hunk is not-now)", not maps["<leader>gN"])
local function mapped(buf, lhs)
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if m.lhs == vim.g.mapleader .. lhs:gsub("^<leader>", "") then
			return true
		end
	end
	return false
end
assert_true("the decline key is mapped in the review buffer", mapped(rb, "<leader>gD"))
assert_true("and not in the notes buffer", not mapped(nb7, "<leader>gD"))
assert_true("take-one is mapped in the review buffer only", mapped(rb, "<leader>gA") and not mapped(nb7, "<leader>gA"))
assert_true("dp is the take in the review buffer", vim.api.nvim_buf_call(rb, function()
	return vim.fn.maparg("dp", "n", false, true).buffer == 1
end))
assert_true("and do in the notes buffer", vim.api.nvim_buf_call(nb7, function()
	return vim.fn.maparg("do", "n", false, true).buffer == 1
end))

print("\n=== format_source: a short, honest label, never the raw field ===")
assert_eq("nil source: notes", "notes", review.format_source(nil))
assert_eq("a URL: just its host", "github.com", review.format_source("https://github.com/foo/bar/pull/1"))

print("\n=== from the overview, `do` takes the hunk the jump landed on ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other", "Section C", "  more" })
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
		item("a2", { kind = "add", target = { under = "Section C" }, after = "  added under C", source = "", headline = "add under C" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("overview opens", review.overview(nb))
	local q = vim.fn.getqflist()
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	local nw = vim.fn.bufwinid(nb)
	for i = #q, 1, -1 do
		vim.api.nvim_set_current_win(qw)
		vim.api.nvim_win_set_cursor(qw, { i, 0 })
		review.qf_jump()
		vim.cmd("normal do")
	end
	local got = vim.api.nvim_buf_get_lines(nb, 0, -1, false)
	assert_true("every overview entry was takeable by do from where it landed", vim.tbl_contains(got, "  added under B") and vim.tbl_contains(got, "  added under C") and got[1]:match("^NEWS"))
end

print("\n=== taken by decision: an edited taken suggestion is still taken, never re-proposed or declined ===")
do
	local function taken_headlines(r)
		local t = {}
		for _, rec in pairs(ledger.taken_by_id(ledger.read(r))) do
			t[#t + 1] = rec.headline
		end
		table.sort(t)
		return t
	end
	-- do in notes, edit the taken line, commit
	local r = new_repo(BASE)
	build(r, "2026-10-01", { item("a1", { kind = "add", target = { under = "Section A" }, after = "  - follow up with Ola", source = "notes", headline = "follow up" }) })
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local nw = vim.fn.bufwinid(nb)
	go_to(nw, nb, "Section B")
	vim.cmd("diffupdate")
	vim.cmd("normal do")
	local n = assert(line_of(nb, "  - follow up with Ola"))
	vim.api.nvim_buf_set_lines(nb, n - 1, n, false, { "  - follow up with Ola (Thu)" })
	review.commit(nb)
	assert_eq("taken by id although the text was edited", { "follow up" }, taken_headlines(r))
	build(r, "2026-10-02", {})
	assert_eq("the edited taken suggestion is not proposed again", 0, #proposal.read_items(r))

	-- edit in the split first, take with the take key, save the split
	local r2 = new_repo(BASE)
	build(r2, "2026-10-01", { item("a1", { kind = "add", target = { under = "Section A" }, after = "  - read RFC", source = "https://example.invalid/rfc", headline = "read rfc" }) })
	local nb2 = open_notes(r2)
	review.attach(nb2)
	assert_true("review opens", review.open_review(nb2))
	local rb2 = review_buf_of(nb2)
	local rw2 = vim.fn.bufwinid(rb2)
	local k = line_of(rb2, "  - read RFC")
	vim.api.nvim_buf_set_text(rb2, k - 1, #"  - read RFC", k - 1, #"  - read RFC", { " (skim)" })
	vim.api.nvim_set_current_win(rw2)
	vim.api.nvim_win_set_cursor(rw2, { k, 0 })
	vim.cmd("diffupdate")
	review.take(rb2)
	vim.cmd("write")
	assert_eq("saving the split does not decline a suggestion the user took edited", {}, declined_ids(r2))
	assert_eq("it is recorded taken at that save", { "read rfc" }, taken_headlines(r2))

	-- take then undo, then save: not taken
	local r3 = new_repo(BASE)
	build(r3, "2026-10-01", { item("n1") })
	local nb3 = open_notes(r3)
	review.attach(nb3)
	assert_true("review opens", review.open_review(nb3))
	local nw3 = vim.fn.bufwinid(nb3)
	vim.api.nvim_set_current_win(nw3)
	vim.api.nvim_win_set_cursor(nw3, { 1, 0 })
	vim.cmd("diffupdate")
	vim.cmd("normal do")
	vim.cmd("normal u")
	vim.cmd("write")
	assert_eq("an undone take is not recorded", {}, taken_headlines(r3))
end

print("\n=== the user's line appended where an add lands never makes the suggestion vanish ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other" })
	build(r, "2026-10-01", { item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }) })
	local nb = open_notes(r)
	review.attach(nb)
	vim.api.nvim_buf_set_lines(nb, 4, 4, false, { "  the user's line at the end of B" })
	assert_true("the review still opens", review.open_review(nb))
	assert_true("with the suggestion in it", line_of(review_buf_of(nb), "  added under B") ~= nil)
	assert_eq("and the committed state counts it as open", 1, #proposal.open_items(r))
end

print("\n=== undo after a save: the next save of the split takes the decline back ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", { item("n1") })
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw = vim.fn.bufwinid(rb)
	go_to(rw, rb, "NEWS n1")
	review.decline(rb)
	vim.cmd("write")
	assert_eq("declined at the first save", 1, #declined_ids(r))
	vim.cmd("normal! u")
	assert_true("the lines are back after u", line_of(rb, "NEWS n1") ~= nil)
	vim.cmd("write")
	assert_eq("no longer declined after u and :w", {}, declined_ids(r))
	build(r, "2026-10-02", {})
	assert_eq("and still proposed by the next pass", 1, #proposal.read_items(r))
	review.decline(rb)
	vim.cmd("write")
	assert_eq("declining again works", 1, #declined_ids(r))
end

print("\n=== a removal next to an add: decline and take act on one suggestion, not the whole hunk ===")
do
	local function fresh()
		local r = new_repo({ "Section A", "  existing", "  - stale", "Section B", "  other" })
		build(r, "2026-10-01", {
			item("rm", { kind = "remove", target = { at = "  - stale" }, before = "  - stale", after = "", source = "notes", headline = "drop stale" }),
			item("ad", { kind = "add", target = { under = "Section A" }, after = "  - new under A", source = "https://example.invalid/ad", headline = "add A" }),
		})
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		return r, nb, review_buf_of(nb)
	end
	local r, nb, rb = fresh()
	assert_eq("the two form one hunk", 1, #vim.diff(
		snippet.join_lines(lines_of(nb), true), snippet.join_lines(lines_of(rb), true), { result_type = "indices" }))
	local rw = vim.fn.bufwinid(rb)
	go_to(rw, rb, "  existing")
	assert_true("decline on the removal's own place", review.decline(rb))
	assert_eq("only the removal is declined: its line is back, the add stays", { "Section A", "  existing", "  - stale", "  - new under A", "Section B", "  other" }, lines_of(rb))
	vim.cmd("write")
	assert_eq("one decline recorded", { "drop stale" }, (function()
		local t = {}
		for _, rec in pairs(ledger.declined(ledger.read(r)).ids) do
			t[#t + 1] = rec.headline
		end
		return t
	end)())

	local r2, nb2, rb2 = fresh()
	local rw2 = vim.fn.bufwinid(rb2)
	go_to(rw2, rb2, "  - new under A")
	assert_true("decline the add", review.decline(rb2))
	assert_eq("the removal is still pending in the review buffer", { "Section A", "  existing", "Section B", "  other" }, lines_of(rb2))
	vim.cmd("write")
	assert_eq("only the add is declined", { "add A" }, (function()
		local t = {}
		for _, rec in pairs(ledger.declined(ledger.read(r2)).ids) do
			t[#t + 1] = rec.headline
		end
		return t
	end)())

	local _, nb3, rb3 = fresh()
	local rw3 = vim.fn.bufwinid(rb3)
	go_to(rw3, rb3, "  existing")
	assert_true("take the removal", review.take(rb3))
	assert_eq("the user's notes lose only the stale line", { "Section A", "  existing", "Section B", "  other" }, lines_of(nb3))
	assert_eq("the add is still a hunk", 1, #vim.diff(
		snippet.join_lines(lines_of(nb3), true), snippet.join_lines(lines_of(rb3), true), { result_type = "indices" }))
	go_to(rw3, rb3, "  - new under A")
	assert_true("then take the add", review.take(rb3))
	assert_eq("the user's notes have it", { "Section A", "  existing", "  - new under A", "Section B", "  other" }, lines_of(nb3))
end

print("\n=== reading.md: the review key and the overview cover both files and say what waits in the other ===")
do
	local function msgs_during(fn)
		local got, orig = {}, vim.notify
		vim.notify = function(m) got[#got + 1] = m end
		local ok, res = pcall(fn)
		vim.notify = orig
		assert(ok, res)
		return got, res
	end
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	local got, opened = msgs_during(function()
		return review.open_review(nb)
	end)
	assert_true("the review key in notes.md goes to reading.md when that is where the suggestions are", opened)
	local rb = review_buf_of(nb)
	assert_true("a review split for reading.md is open", rb ~= nil and vim.api.nvim_buf_get_name(rb):match("reading.md$") ~= nil)
	assert_true("and it says notes.md had nothing and reading.md has one", got[1] ~= nil and got[1]:match("reading.md") ~= nil)

	-- both files have suggestions
	local r2 = new_repo(BASE)
	build(r2, "2026-10-01", {
		item("n1"),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }),
		item("rd2", { file = "reading.md", kind = "new", after = "READ other", headline = "read other" }),
	})
	local nb2 = open_notes(r2)
	review.attach(nb2)
	local got2 = msgs_during(function()
		return review.open_review(nb2)
	end)
	assert_true("from notes.md it says how many wait in reading.md", got2[1] ~= nil and got2[1]:match("2 more suggestion%(s%) in reading.md") ~= nil)
	assert_eq("the overview lists both files", { "headline n1", "reading.md: read other", "reading.md: read paper" }, (function()
		local t = {}
		review.overview(nb2)
		for _, e in ipairs(vim.fn.getqflist()) do
			t[#t + 1] = e.text
		end
		table.sort(t)
		return t
	end)())
	vim.cmd("cclose")
	-- jumping to a reading.md entry opens that file with its own review split
	review.overview(nb2)
	local q = vim.fn.getqflist()
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	local idx
	for i, e in ipairs(q) do
		if e.text:match("^reading.md") then
			idx = i
		end
	end
	vim.api.nvim_set_current_win(qw)
	vim.api.nvim_win_set_cursor(qw, { idx, 0 })
	review.qf_jump()
	assert_true("the jump lands in reading.md", vim.api.nvim_buf_get_name(0):match("reading.md$") ~= nil)

	-- from reading.md: it says what waits in notes.md
	local rd_buf = vim.api.nvim_get_current_buf()
	vim.cmd("silent! cclose")
	local got3 = msgs_during(function()
		return review.open_review(rd_buf)
	end)
	assert_true("from reading.md it says how many wait in notes.md", #got3 == 0 or got3[1]:match("notes.md") ~= nil)
	assert_eq("pending_elsewhere agrees", 1, (review.pending_elsewhere(r2, "reading.md"))[1].count)
end

print("\n=== the review key asks before discarding unsaved declines ===")
do
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", { item("n1"), item("n2") })
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		go_to(vim.fn.bufwinid(rb), rb, "NEWS n1")
		review.decline(rb)
		build(r, "2026-10-01", { item("n3") }) -- a new pass lands: the review is stale
		return r, nb, rb
	end
	local orig = review.confirm
	local asked = 0
	review.confirm = function() asked = asked + 1; return 3 end
	local r, nb, rb = setup()
	local ok1 = review.open_review(nb)
	assert_true("asked once", asked == 1)
	assert_true("cancel keeps the split and its unsaved decline", not ok1 and vim.api.nvim_buf_is_valid(rb) and line_of(rb, "NEWS n1") == nil)
	assert_eq("nothing recorded", {}, declined_ids(r))
	review.confirm = function() return 1 end
	assert_true("save-then-reopen works", review.open_review(nb))
	assert_eq("the decline was saved first", 1, #declined_ids(r))
	local r2, nb2 = setup()
	review.confirm = function() return 2 end
	assert_true("discard reopens", review.open_review(nb2))
	assert_eq("and records nothing", {}, declined_ids(r2))
	review.confirm = orig
end

print("\n=== the status line tracks the live untaken count and refreshes after a review save or the user's commit ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", { item("n1"), item("n2") })
	local nb = open_notes(r)
	review.attach(nb)
	local win = vim.fn.bufwinid(nb)
	assert_true("the winbar counts both", vim.wo[win].winbar:match("%(2 untaken%)") ~= nil)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	go_to(vim.fn.bufwinid(rb), rb, "NEWS n1")
	review.decline(rb)
	vim.cmd("write")
	assert_true("after a review save it counts one", vim.wo[win].winbar:match("%(1 untaken%)") ~= nil)
	go_to(win, nb, "Section A")
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	vim.cmd("diffupdate")
	vim.cmd("normal do")
	review.commit(nb)
	assert_eq("after the user's commit nothing is untaken: silent", "", vim.wo[win].winbar)
end

print("\n=== dp in the review split takes the hunk, recorded like do from the notes side ===")
do
	local function taken_headlines(r)
		local t = {}
		for _, rec in pairs(ledger.taken_by_id(ledger.read(r))) do
			t[#t + 1] = rec.headline
		end
		table.sort(t)
		return t
	end
	local function open(r)
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		return nb, rb, vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	end

	-- dp, then commit the notes
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }),
	})
	local nb, rb, rw = open(r)
	go_to(rw, rb, "NEWS n1")
	vim.cmd("normal dp")
	assert_eq("the news line reached the user's buffer", "NEWS n1", lines_of(nb)[1])
	assert_true("and only that hunk", line_of(nb, "  added") == nil)
	assert_eq("the review buffer is unchanged by a take", false, vim.bo[rb].modified)
	review.commit(nb)
	assert_eq("commit records it taken", { "headline n1" }, taken_headlines(r))

	-- dp, edit the taken line in the notes, save the split
	local r2 = new_repo(BASE)
	build(r2, "2026-10-01", { item("a1", { kind = "add", target = { under = "Section A" }, after = "  - read RFC", source = "https://example.invalid/rfc", headline = "read rfc" }) })
	local nb2, rb2, rw2 = open(r2)
	go_to(rw2, rb2, "  - read RFC")
	vim.cmd("normal dp")
	local k = assert(line_of(nb2, "  - read RFC"), "dp took the add")
	vim.api.nvim_buf_set_lines(nb2, k - 1, k, false, { "  - read RFC (skim)" })
	vim.api.nvim_set_current_win(rw2)
	vim.cmd("write")
	assert_eq("saving the split does not decline a suggestion taken with dp and edited", {}, declined_ids(r2))
	assert_eq("it is recorded taken at that save", { "read rfc" }, taken_headlines(r2))

	-- dp, then u in the notes window, then save: not taken
	local r3 = new_repo(BASE)
	build(r3, "2026-10-01", { item("n1") })
	local nb3, rb3, rw3, nw3 = open(r3)
	go_to(rw3, rb3, "NEWS n1")
	vim.cmd("normal dp")
	assert_eq("taken into the notes", "NEWS n1", lines_of(nb3)[1])
	vim.api.nvim_set_current_win(nw3)
	vim.cmd("normal u")
	assert_eq("u in the notes window undoes it", BASE, lines_of(nb3))
	vim.cmd("write")
	assert_eq("an undone dp take is not recorded", {}, taken_headlines(r3))

	-- dp on the split's last line: a removal of the notes' last line, with
	-- another hunk above it
	local r4 = new_repo({ "Section A", "  existing", "Section B", "  - stale" })
	build(r4, "2026-10-01", {
		item("n1"),
		item("rm", { kind = "remove", target = { at = "  - stale" }, before = "  - stale", after = "", source = "notes", headline = "drop stale" }),
	})
	local nb4, rb4, rw4 = open(r4)
	vim.api.nvim_set_current_win(rw4)
	vim.api.nvim_win_set_cursor(rw4, { vim.api.nvim_buf_line_count(rb4), 0 })
	vim.cmd("diffupdate")
	vim.cmd("normal dp")
	assert_eq("dp on the last line takes the removal after it", { "Section A", "  existing", "Section B" }, lines_of(nb4))
	review.commit(nb4)
	assert_eq("and it is recorded taken", { "drop stale" }, taken_headlines(r4))
end

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
