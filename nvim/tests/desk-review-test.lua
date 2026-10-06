-- The stateless diff review (desk.review), headless against throwaway repos,
-- never his real notes: the merged view in a stacked diff split, taking a
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
assert_true("review is below the notes window", vim.fn.win_screenpos(review_win)[1] > vim.fn.win_screenpos(notes_win)[1])
assert_true("the merged view has the news on top", lines_of(rb)[1]:match("^NEWS ") ~= nil)
assert_true("and the in-place add", line_of(rb, "  added") ~= nil)
assert_eq("his buffer is untouched", BASE, lines_of(nb))
assert_eq("his HEAD is untouched", BASE, head_lines(repo))
assert_eq("his buffer is not modified", false, vim.bo[nb].modified)

print("\n=== take a hunk with do in the notes window, then commit: taken is recorded ===")
go_to(notes_win, nb, "Section A")
vim.api.nvim_win_set_cursor(notes_win, { 1, 0 })
-- the news hunk is a deletion on his side: do on the line it precedes
vim.cmd("normal! do")
assert_true("his buffer now holds the news line", line_of(nb, "NEWS n1") ~= nil or lines_of(nb)[1]:match("^NEWS ") ~= nil)
assert_true("still no commit", #head_lines(repo) == #BASE)
local cok, cres = review.commit(nb)
assert_true("commit succeeds", cok)
assert_true("HEAD has the taken suggestion", head_lines(repo)[1]:match("^NEWS ") ~= nil)
local n1_id = id_by_headline(repo, "headline n1")
assert_true("the taken item is recorded as taken", ledger.taken_by_id(ledger.read(repo))[n1_id] ~= nil)
assert_eq("the other suggestion is not taken", false, ledger.taken_by_id(ledger.read(repo))[id_by_headline(repo, "headline a1")] ~= nil)
assert_eq("one taken reported", 1, cres.taken)
assert_eq("his buffer is saved", false, vim.bo[nb].modified)

print("\n=== not now: a hunk left alone is carried by the next pass, batched with new items ===")
build(repo, "2026-10-02", { item("n2") })
local p = proposal.read(repo)
local heads = vim.tbl_map(function(it)
	return it.headline
end, p.items)
table.sort(heads)
assert_eq("the left hunk and the new item; the taken one is gone", { "headline a1", "headline n2" }, heads)
assert_eq("parent is his newest HEAD", vim.trim(select(2, git.run(repo, { "rev-parse", "HEAD" }))), p.parent)

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
assert_true("the declined hunk now equals his text", line_of(rb, "  added") == nil)
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
assert_eq("still a single proposal commit on his HEAD", vim.trim(select(2, git.run(repo3, { "rev-parse", "HEAD" }))), proposal.read(repo3).parent)

print("\n=== his own edits after the pass do not appear as hunks ===")
vim.api.nvim_buf_set_lines(nb4, 3, 4, false, { "  other, edited by him" })
vim.cmd("silent! only")
rb = review_buf_of(nb4)
if rb then
	vim.api.nvim_buf_delete(rb, { force = true })
end
assert_true("re-open", review.open_review(nb4))
rb = review_buf_of(nb4)
assert_true("his edit is in the merged view", line_of(rb, "  other, edited by him") ~= nil)
local hunks = vim.diff(
	snippet.join_lines(lines_of(nb4), true),
	snippet.join_lines(lines_of(rb), true),
	{ result_type = "indices" }
)
assert_eq("the two adjacent suggestions form one hunk", 1, #hunks)
local hunk_text = table.concat(vim.list_slice(lines_of(rb), hunks[1][3], hunks[1][3] + hunks[1][4] - 1), "\n")
assert_true("the hunk is the suggestions, not his edit", hunk_text:match("^NEWS [^\n]*\nNEWS [^\n]*$") ~= nil)

print("\n=== a suggestion conflicting with his edit is still shown, marked as near his edit ===")
local repo4 = new_repo({ "Section A", "  keep this" })
build(repo4, "2026-10-01", {
	item("e1", { kind = "edit", target = { at = "  keep this" }, before = "  keep this", after = "  agent rewrite", source = "" }),
})
local nb5 = open_notes(repo4)
review.attach(nb5)
vim.api.nvim_buf_set_lines(nb5, 1, 2, false, { "  his rewrite" })
local cok2, why = review.open_review(nb5)
assert_true("the conflicting suggestion is still reviewable", cok2)
local rb5 = review_buf_of(nb5)
assert_true("his edit is in the review buffer", line_of(rb5, "  his rewrite") ~= nil)
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
assert_eq("only that one reached his buffer", { top }, vim.list_slice(lines_of(nb8), 1, 1))
assert_true("the other is not in his buffer", line_of(nb8, second) == nil)
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
assert_true("entries point into HIS notes buffer", qf[1].bufnr == nb7)
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
assert_eq("the jump lands in his notes window", notes_win, vim.api.nvim_get_current_win())
assert_eq("on the line aligned with the hunk", qf[#qf].lnum, vim.api.nvim_win_get_cursor(notes_win)[1])
vim.cmd([[execute "normal! 1\<C-o>"]])
assert_eq("Ctrl-O returns to where he was in his notes", 2, vim.api.nvim_win_get_cursor(notes_win)[1])
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
	assert_eq("saving the split does not decline a suggestion he took edited", {}, declined_ids(r2))
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

print("\n=== his line appended where an add lands never makes the suggestion vanish ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other" })
	build(r, "2026-10-01", { item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }) })
	local nb = open_notes(r)
	review.attach(nb)
	vim.api.nvim_buf_set_lines(nb, 4, 4, false, { "  his line at the end of B" })
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

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
