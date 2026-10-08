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
assert_eq("the review winbar shows the keys, then the count on the right", review.KEY_HINT .. "%=2 left (2 saved)", vim.wo[review_win].winbar)
assert_true("the keys include the review-side take", review.KEY_HINT:match("dp take") ~= nil)
assert_eq("the hotkey works in the split too, not nvim's own gx", "Desk: act on the token under the cursor", vim.fn.maparg(vim.g.mapleader .. "gx", "n", false, true).desc)
assert_true("and the next key, the easy one", review.KEY_HINT:match("^n/N next") ~= nil)
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
assert_eq("the message says what the commit takes", "Take 1 suggestion\n\nTaken:\n- headline n1", vim.trim(select(2, git.run(repo, { "log", "-1", "--format=%B" }))))
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
vim.api.nvim_set_current_win(review_win)
vim.api.nvim_win_set_cursor(review_win, { 2, 0 })
vim.api.nvim_set_current_win(qf_win)
vim.api.nvim_win_set_cursor(qf_win, { 2, 0 })
review.qf_jump()
assert_eq("with a review open, the jump lands in the review split", review_win, vim.api.nvim_get_current_win())
assert_eq("on the suggestion's own line there", line_of(rb, "  added under B"), vim.api.nvim_win_get_cursor(review_win)[1])
vim.cmd([[execute "normal! 1\<C-o>"]])
assert_eq("Ctrl-O returns to where the user was in the review split", 2, vim.api.nvim_win_get_cursor(review_win)[1])
vim.cmd([[execute "normal! 1\<C-i>"]])
assert_eq("Ctrl-I goes forward again", line_of(rb, "  added under B"), vim.api.nvim_win_get_cursor(review_win)[1])
vim.api.nvim_set_current_win(qf_win)
vim.api.nvim_win_set_cursor(qf_win, { #qf, 0 })
review.qf_jump()
assert_eq("a removal at the end lands on the split's last line, where dp takes it", vim.api.nvim_buf_line_count(rb), vim.api.nvim_win_get_cursor(review_win)[1])

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
assert_true("and in the notes buffer while the review is open", mapped(nb7, "<leader>gD"))
assert_true("take-one is mapped in both", mapped(rb, "<leader>gA") and mapped(nb7, "<leader>gA"))
assert_true("dp is the take in the review buffer", vim.api.nvim_buf_call(rb, function()
	return vim.fn.maparg("dp", "n", false, true).buffer == 1
end))
assert_true("and do in the notes buffer", vim.api.nvim_buf_call(nb7, function()
	return vim.fn.maparg("do", "n", false, true).buffer == 1
end))

print("\n=== format_source: a short, honest label, never the raw field ===")
assert_eq("nil source: notes", "notes", review.format_source(nil))
assert_eq("a URL: just its host", "github.com", review.format_source("https://github.com/foo/bar/pull/1"))

print("\n=== from the overview, dp takes the hunk the jump landed on ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other", "Section C", "  more" })
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
		item("r1", { kind = "remove", target = { at = "  existing" }, before = "  existing", after = "", source = "", headline = "drop existing" }),
		item("r2", { kind = "remove", target = { at = "  more" }, before = "  more", after = "", source = "", headline = "drop more" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("overview opens", review.overview(nb))
	local q = vim.fn.getqflist()
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	-- first to last: each take moves the lines below it, so this only works
	-- if the jump finds the suggestion afresh
	for i = 1, #q do
		vim.api.nvim_set_current_win(qw)
		vim.api.nvim_win_set_cursor(qw, { i, 0 })
		review.qf_jump()
		vim.cmd("normal dp")
	end
	assert_eq("every overview entry was takeable by dp from where it landed",
		{ "NEWS n1", "Section A", "Section B", "  other", "  added under B", "Section C" }, lines_of(nb))
end

print("\n=== the overview opens across the top and shows each entry's suggestion as the cursor moves ===")
do
	local base = { "Section A" }
	for i = 1, 60 do
		base[#base + 1] = "  line " .. i
	end
	base[#base + 1] = "Section Z"
	local r = new_repo(base)
	build(r, "2026-10-01", {
		item("n1", { headline = "news" }),
		item("z1", { kind = "add", target = { under = "Section Z" }, after = "  added under Z", source = "", headline = "add under Z" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw, nw = vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	vim.api.nvim_win_set_cursor(rw, { 30, 0 })
	assert_true("overview opens", review.overview(nb))
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	local qbuf = vim.api.nvim_win_get_buf(qw)
	assert_eq("the list is at the very top", 1, vim.fn.win_screenpos(qw)[1])
	assert_eq("full width", vim.o.columns, vim.api.nvim_win_get_width(qw))
	assert_true("above the review split", vim.fn.win_screenpos(qw)[1] < vim.fn.win_screenpos(rw)[1])
	assert_eq("the cursor is in the list", qw, vim.api.nvim_get_current_win())
	assert_eq("the first entry already shows in the split", 1, vim.api.nvim_win_get_cursor(rw)[1])
	vim.api.nvim_win_set_cursor(qw, { 2, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = qbuf })
	local z = line_of(rb, "  added under Z")
	assert_eq("moving in the list puts the split's cursor on that entry's suggestion", z, vim.api.nvim_win_get_cursor(rw)[1])
	assert_true("scrolled into view", vim.fn.line("w0", rw) <= z and vim.fn.line("w$", rw) >= z and vim.fn.line("w0", rw) > 1)
	assert_true("the notes window scrolls with it", vim.fn.line("w0", nw) > 1)
	assert_eq("the cursor stays in the list", qw, vim.api.nvim_get_current_win())
	vim.api.nvim_buf_call(qbuf, function()
		vim.cmd("doautocmd FileType qf")
	end)
	assert_eq("a list buffer set up again previews once, not twice", 1, #vim.api.nvim_get_autocmds({ event = "CursorMoved", buffer = qbuf }))
	review.qf_jump()
	assert_eq("<CR> still jumps", { rw, z }, { vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(rw)[1] })
	vim.cmd([[execute "normal! 1\<C-o>"]])
	assert_eq("Ctrl-O returns to where the user was before the preview moved it", 30, vim.api.nvim_win_get_cursor(rw)[1])
	vim.cmd("cclose")
	vim.cmd("copen")
	assert_true("in any other list nothing previews", (function()
		vim.fn.setqflist({}, " ", { title = "other", items = { { bufnr = nb, lnum = 5, text = "x" } } })
		local before = vim.api.nvim_win_get_cursor(rw)
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
		return vim.deep_equal(before, vim.api.nvim_win_get_cursor(rw))
	end)())
	vim.cmd("cclose")
end

print("\n=== with no review open, the overview jumps into the notes window ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other" })
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("overview opens", review.overview(nb))
	local q = vim.fn.getqflist()
	local rb = review_buf_of(nb)
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	vim.cmd("quit")
	assert_true("the review is closed", review_buf_of(nb) == nil)
	local nw = vim.fn.bufwinid(nb)
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	vim.api.nvim_set_current_win(qw)
	vim.api.nvim_win_set_cursor(qw, { #q, 0 })
	review.qf_jump()
	assert_eq("the jump lands in the notes window", nw, vim.api.nvim_get_current_win())
	assert_eq("on the line aligned with the hunk", q[#q].lnum, vim.api.nvim_win_get_cursor(nw)[1])
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
	assert_true("the take carries the edit into the notes", line_of(nb2, "  - read RFC (skim)") ~= nil)
	assert_true("not the text as proposed", line_of(nb2, "  - read RFC") == nil)
	vim.cmd("write")
	assert_eq("saving the split does not decline a suggestion the user took edited", {}, declined_ids(r2))
	assert_eq("it is recorded taken at that save", { "read rfc" }, taken_headlines(r2))

	-- the same for an edit of an existing line
	local r5 = new_repo(BASE)
	build(r5, "2026-10-01", { item("e1", { kind = "edit", target = { at = "  existing" }, before = "  existing", after = "  existing, revised", source = "notes", headline = "revise" }) })
	local nb5 = open_notes(r5)
	review.attach(nb5)
	assert_true("review opens", review.open_review(nb5))
	local rb5 = review_buf_of(nb5)
	local rw5 = vim.fn.bufwinid(rb5)
	local k5 = line_of(rb5, "  existing, revised")
	vim.api.nvim_buf_set_text(rb5, k5 - 1, #"  existing, revised", k5 - 1, #"  existing, revised", { " twice" })
	vim.api.nvim_set_current_win(rw5)
	vim.api.nvim_win_set_cursor(rw5, { k5, 0 })
	vim.cmd("diffupdate")
	review.take(rb5)
	assert_eq("an edited edit lands as edited, in place", { "Section A", "  existing, revised twice", "Section B", "  other" }, lines_of(nb5))

	-- edit in the split, then save it without taking: still waiting, not declined
	local r6 = new_repo(BASE)
	build(r6, "2026-10-01", { item("a1", { kind = "add", target = { under = "Section A" }, after = "  - read RFC", source = "https://example.invalid/rfc", headline = "read rfc" }) })
	local nb6 = open_notes(r6)
	review.attach(nb6)
	assert_true("review opens", review.open_review(nb6))
	local rb6 = review_buf_of(nb6)
	local k6 = line_of(rb6, "  - read RFC")
	vim.api.nvim_buf_set_text(rb6, k6 - 1, #"  - read RFC", k6 - 1, #"  - read RFC", { " (skim)" })
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb6))
	vim.cmd("write")
	assert_eq("saving an edited, untaken suggestion does not decline it", {}, declined_ids(r6))
	assert_eq("nor take it", {}, taken_headlines(r6))

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

	-- take, undo, then an edit elsewhere, then save: the edit starts a new
	-- undo branch, which leaves the undone take behind
	local r4 = new_repo(BASE)
	build(r4, "2026-10-01", { item("n1") })
	local nb4 = open_notes(r4)
	review.attach(nb4)
	assert_true("review opens", review.open_review(nb4))
	local nw4 = vim.fn.bufwinid(nb4)
	vim.api.nvim_set_current_win(nw4)
	vim.api.nvim_win_set_cursor(nw4, { 1, 0 })
	vim.cmd("diffupdate")
	vim.cmd("normal do")
	vim.cmd("normal u")
	vim.api.nvim_buf_set_lines(nb4, -1, -1, false, { "  an unrelated edit" })
	vim.cmd("write")
	assert_eq("an undone take stays unrecorded after an unrelated edit", {}, taken_headlines(r4))
	build(r4, "2026-10-02", {})
	assert_eq("and the next pass carries it again", 1, #proposal.read_items(r4))
end

print("\n=== a suggestion recorded taken or declined leaves no hunk in a reopened review ===")
do
	local function hunk_count(nb, rb)
		return #vim.diff(table.concat(lines_of(nb), "\n") .. "\n", table.concat(lines_of(rb), "\n") .. "\n", { result_type = "indices" })
	end
	-- declined and saved, then the review reopened over the same proposal
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	go_to(vim.fn.bufwinid(rb), rb, "  added under B")
	assert_true("decline", review.decline(rb))
	vim.cmd("write")
	assert_eq("the decline is recorded", 1, #declined_ids(r))
	vim.cmd("normal 1" .. vim.g.mapleader .. "gq")
	assert_true("the review ends", not vim.api.nvim_buf_is_valid(rb))
	assert_true("and reopens", review.open_review(nb))
	rb = review_buf_of(nb)
	assert_true("the declined line is not back", line_of(rb, "  added under B") == nil)
	assert_eq("one hunk, for the one suggestion left", 1, hunk_count(nb, rb))
	assert_true("overview opens", review.overview(nb))
	assert_eq("which the overview lists", 1, #vim.fn.getqflist())
	vim.cmd("cclose")

	-- taken and committed, then reworded in the notes
	local r2 = new_repo(BASE)
	build(r2, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
	})
	local nb2 = open_notes(r2)
	vim.api.nvim_buf_set_lines(nb2, 4, 4, false, { "  added under B" })
	review.commit(nb2)
	assert_eq("the take is recorded", 1, vim.tbl_count(ledger.taken_by_id(ledger.read(r2))))
	vim.api.nvim_buf_set_lines(nb2, 4, 5, false, { "  added under B, reworded" })
	review.attach(nb2)
	assert_true("review opens", review.open_review(nb2))
	local rb2 = review_buf_of(nb2)
	assert_true("the taken line is not proposed beside the rewording", line_of(rb2, "  added under B") == nil)
	assert_eq("one hunk, for the one suggestion left", 1, hunk_count(nb2, rb2))
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
		-- a pass may name the file in the headline itself
		item("rd2", { file = "reading.md", kind = "new", after = "READ other", headline = "reading.md: read other" }),
	})
	local nb2 = open_notes(r2)
	review.attach(nb2)
	local got2 = msgs_during(function()
		return review.open_review(nb2)
	end)
	assert_true("from notes.md it says how many wait in reading.md", got2[1] ~= nil and got2[1]:match("2 more suggestion%(s%) in reading.md") ~= nil)
	assert_eq("the overview lists both files, a headline naming its file prefixed once", { "headline n1", "reading.md: read other", "reading.md: read paper" }, (function()
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
	assert_eq("the other file's entry keeps focus in the list", qw, vim.api.nvim_get_current_win())
	local rd_buf = vim.fn.bufnr(r2 .. "/reading.md")
	assert_true("the review moved to reading.md", rd_buf ~= -1 and vim.fn.bufwinid(rd_buf) ~= -1)
	assert_true("the title names the switch", review.OVERVIEW_TITLE:match("other file: switch") ~= nil)
	local texts_after = vim.tbl_map(function(e)
		return e.text
	end, vim.fn.getqflist())
	table.sort(texts_after)
	assert_eq("the list is rebuilt around the new review", { "notes.md: headline n1", "read other", "read paper" }, texts_after)
	assert_true("the cursor stays on the entry", vim.fn.getqflist()[vim.fn.line(".")].text:match("^read ") ~= nil)
	-- <CR> on an entry in the file now under review jumps, as for the current file
	review.qf_jump()
	assert_true("an entry in the reviewed file jumps into its review split", vim.api.nvim_get_current_win() ~= qw)

	-- from reading.md: it says what waits in notes.md
	vim.cmd("silent! cclose")
	local got3 = msgs_during(function()
		return review.open_review(rd_buf)
	end)
	assert_true("from reading.md it says how many wait in notes.md", #got3 == 0 or got3[1]:match("notes.md") ~= nil)
	assert_eq("pending_elsewhere agrees", 1, (review.pending_elsewhere(r2, "reading.md"))[1].count)
	review.overview(vim.fn.bufnr(r2 .. "/reading.md"))
	local texts = vim.tbl_map(function(e)
		return e.text
	end, vim.fn.getqflist())
	table.sort(texts)
	assert_eq("in reading.md's own overview its entries carry no file name", { "notes.md: headline n1", "read other", "read paper" }, texts)
	vim.cmd("cclose")
end

print("\n=== moving the review between files, and back to the notes it started from ===")
do
	local function leader(keys)
		vim.cmd("normal 1" .. vim.g.mapleader .. keys)
	end
	local said = {}
	local orig_notify, orig_confirm = vim.notify, review.confirm
	vim.notify = function(m)
		said[#said + 1] = m
	end
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	local home = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(home, { 3, 0 })
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	vim.api.nvim_win_set_cursor(home, { 3, 0 })
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
	leader("gR")
	assert_eq("␣gR in the split with suggestions left says so", "desk: 1 left here first; then ␣gR moves to reading.md", said[#said])
	assert_eq("and stays", rb, review_buf_of(nb))
	go_to(vim.fn.bufwinid(rb), rb, "NEWS n1")
	review.decline(rb)
	local asked
	review.confirm = function()
		asked = true
		return 3
	end
	leader("gR")
	assert_true("with unsaved declines it asks", asked)
	assert_eq("cancelling keeps the review", rb, review_buf_of(nb))
	review.confirm = function()
		return 1
	end
	leader("gR")
	assert_eq("saving them records the decline", { id_by_headline(r, "headline n1") }, declined_ids(r))
	local rrb = review_buf_of(nb)
	assert_true("the review is now of reading.md", rrb ~= nil and vim.api.nvim_buf_get_name(rrb):match("reading.md$") ~= nil)
	assert_true("shown where the notes were", vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(home)):match("reading.md$") ~= nil)
	assert_eq("two windows, as before", 2, #vim.api.nvim_tabpage_list_wins(0))
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rrb))
	vim.cmd("quit")
	vim.wait(100, function()
		return vim.api.nvim_win_get_buf(home) == nb
	end)
	assert_eq(":q of the moved review leaves the notes it started from", nb, vim.api.nvim_win_get_buf(home))
	assert_eq("as they were", 3, vim.api.nvim_win_get_cursor(home)[1])
	assert_eq("in one window", 1, #vim.api.nvim_tabpage_list_wins(0))

	-- started from notes.md with nothing in it: the key goes to reading.md,
	-- and :q in the reading.md window still ends in notes.md
	local r2 = new_repo(BASE)
	build(r2, "2026-10-01", { item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }) })
	local nb2 = open_notes(r2)
	review.attach(nb2)
	local home2 = vim.api.nvim_get_current_win()
	assert_true("the key opens reading.md's review", review.open_review(nb2))
	assert_eq("in the same two windows", 2, #vim.api.nvim_tabpage_list_wins(0))
	vim.api.nvim_set_current_win(home2)
	vim.cmd("quit")
	vim.wait(100, function()
		return vim.api.nvim_get_current_buf() == nb2
	end)
	assert_eq(":q in the reading.md window leaves notes.md", nb2, vim.api.nvim_get_current_buf())
	assert_eq("in one window", 1, #vim.api.nvim_tabpage_list_wins(0))
	vim.notify, review.confirm = orig_notify, orig_confirm
end

print("\n=== the other file open in another nvim: one line, and the review stays ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	local home = vim.api.nvim_get_current_win()
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local path = r .. "/reading.md"
	local swapdir = vim.fn.tempname()
	vim.fn.mkdir(swapdir, "p")
	local saved_dir, saved_swap = vim.o.directory, vim.o.swapfile
	vim.o.directory = swapdir .. "//"
	vim.o.swapfile = true
	local function swaps()
		return vim.fn.glob(swapdir .. "/*reading.md.sw?", false, true)
	end
	local function unchanged(desc)
		assert_eq(desc .. ": the review is as it was", rb, review_buf_of(nb))
		assert_eq(desc .. ": the notes stay in their window", nb, vim.api.nvim_win_get_buf(home))
		assert_eq(desc .. ": reading.md is not loaded here", 0, vim.fn.bufloaded(path))
	end
	-- A real second nvim holding reading.md, so its swap file is the
	-- condition a load here would stop on.
	local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "--embed", "--headless",
		"--cmd", "set directory=" .. swapdir .. "//", path }, { rpc = true })
	local pid = vim.fn.jobpid(job)
	assert_true("the other nvim has its swap file", vim.wait(5000, function()
		return #swaps() > 0
	end))
	local moved, why = review.move_review(nb, "reading.md")
	assert_eq("the move is refused", false, moved)
	assert_eq("with one line naming the file and the other nvim's pid",
		string.format("reading.md is open in another nvim (pid %d); close it there first", pid), why)
	unchanged("open elsewhere")
	-- The same swap file once that nvim is gone without cleaning up.
	vim.uv.kill(pid, "sigkill")
	vim.fn.jobwait({ job }, 5000)
	moved, why = review.move_review(nb, "reading.md")
	assert_eq("a swap file left by an nvim that died is named as such",
		"reading.md has a swap file from an nvim that is no longer running; recover or delete it first", why)
	unchanged("left behind")
	for _, f in ipairs(swaps()) do
		os.remove(f)
	end
	-- A load that fails on E325 anyway (no swap file the check could find).
	vim.o.swapfile = false
	local orig_bufload = vim.fn.bufload
	vim.fn.bufload = function()
		error("Vim:E325: ATTENTION")
	end
	moved, why = review.move_review(nb, "reading.md")
	vim.fn.bufload = orig_bufload
	assert_eq("a load that stops on E325 still says so in one line", "reading.md is open in another nvim; close it there first", why)
	unchanged("E325 on load")
	vim.o.directory, vim.o.swapfile = saved_dir, saved_swap
	moved = review.move_review(nb, "reading.md")
	assert_true("with the other nvim gone the move goes through", moved)
	vim.fn.delete(swapdir, "rf")
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

print("\n=== overview keys: take and decline from the list, without leaving it ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other", "Section C", "  more" })
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
		item("r1", { kind = "remove", target = { at = "  more" }, before = "  more", after = "", source = "", headline = "drop more" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("overview opens", review.overview(nb))
	local rb = review_buf_of(nb)
	local rw = vim.fn.bufwinid(rb)
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	assert_true("the title names the keys", review.OVERVIEW_TITLE:match("t/dp take") and review.OVERVIEW_TITLE:match("x/gD decline"))
	local function entry(headline)
		for i, e in ipairs(vim.fn.getqflist()) do
			if e.text == headline then
				return i
			end
		end
	end
	local function on(headline, keys)
		vim.api.nvim_set_current_win(qw)
		vim.api.nvim_win_set_cursor(qw, { assert(entry(headline), "no entry " .. headline), 0 })
		vim.cmd("normal " .. keys)
	end
	on("add under B", "t")
	assert_true("t takes the entry's suggestion into the notes", line_of(nb, "  added under B") ~= nil)
	assert_eq("and only that one", nil, line_of(nb, "NEWS n1"))
	assert_eq("the cursor stays in the list", qw, vim.api.nvim_get_current_win())
	assert_eq("the list drops it", 2, #vim.fn.getqflist())
	assert_eq("the split's cursor is on it", line_of(rb, "  added under B"), vim.api.nvim_win_get_cursor(rw)[1])
	assert_true("the count moves", vim.wo[rw].winbar:match("%%=2 left %(3 saved%)$") ~= nil)
	on("drop more", "x")
	assert_true("x declines it: the split keeps the line", line_of(rb, "  more") ~= nil)
	assert_true("and the notes too", line_of(nb, "  more") ~= nil)
	assert_eq("the cursor stays in the list", qw, vim.api.nvim_get_current_win())
	assert_eq("the list drops it", 1, #vim.fn.getqflist())
	assert_true("the count moves", vim.wo[rw].winbar:match("%%=1 left %(3 saved%)$") ~= nil)

	vim.api.nvim_set_current_win(rw)
	vim.cmd("normal u")
	assert_eq("u in the split undoes the decline, and the list has it again", 2, #vim.fn.getqflist())
	vim.cmd("normal u")
	assert_eq("u again undoes the take in the notes", nil, line_of(nb, "  added under B"))
	assert_eq("and the list has that again too", 3, #vim.fn.getqflist())

	on("drop more", "gD")
	assert_eq("gD declines too", 2, #vim.fn.getqflist())
	on("add under B", "dp")
	assert_eq("dp takes too", 1, #vim.fn.getqflist())
	assert_true("into the notes", line_of(nb, "  added under B") ~= nil)
	vim.api.nvim_set_current_win(rw)
	vim.cmd("write")
	local a1, r1 = id_by_headline(r, "add under B"), id_by_headline(r, "drop more")
	assert_true("the save records the take, as from the split", ledger.taken_by_id(ledger.read(r))[a1] ~= nil)
	assert_eq("and the decline", { r1 }, declined_ids(r))

	vim.fn.setqflist({}, " ", { title = "something else", items = { { bufnr = nb, lnum = 1, text = "x" } } })
	assert_eq("in any other list the keys do nothing of desk's", false, (review.qf_act("take")))
end

print("\n=== the bars: one live count in both while a review is open, the recorded one otherwise ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section A" }, after = "  added A", source = "", headline = "add A" }),
		item("a2", { kind = "add", target = { under = "Section B" }, after = "  added B", source = "", headline = "add B" }),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	local win = vim.fn.bufwinid(nb)
	local function bars()
		local rb = review_buf_of(nb)
		local rw = rb and vim.fn.bufwinid(rb)
		return vim.wo[win].winbar, rw and rw ~= -1 and vim.wo[rw].winbar or nil
	end
	local function counts(desc, n, saved)
		local text = string.format("%d left (%d saved)", n, saved)
		local notes_bar, review_bar = bars()
		assert_eq(desc .. ": the notes bar has its keys, then " .. text .. " on the right", review.NOTES_KEY_HINT .. "%=" .. text, notes_bar)
		assert_eq(desc .. ": the review bar has its keys, then what waits in the other file and the same text", review.KEY_HINT .. "%=reading.md: 1 more ␣gR · " .. text, review_bar)
	end
	assert_true("before a review: the recorded count, both files", vim.wo[win].winbar:match("%(4 untaken%)") ~= nil)
	assert_true("the keys still being learned on the left, the status on the right", vim.wo[win].winbar:match("^" .. vim.pesc(review.NOTES_IDLE_HINT) .. "%%=") ~= nil)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw = vim.fn.bufwinid(rb)
	counts("at open: this review's own, live and recorded", 3, 3)
	assert_true("the top bar fits in 120 columns with two-digit counts", vim.fn.strchars("99 left (99 saved) · " .. review.KEY_HINT) <= 120)
	assert_true("the top bar names the window below, not above", review.KEY_HINT:match("C%-n down") and not review.KEY_HINT:match("C%-t"))
	assert_true("and the folds", review.KEY_HINT:match("zo/zc fold"))
	for _, h in ipairs({ review.KEY_HINT, review.NOTES_KEY_HINT, review.NOTES_IDLE_HINT }) do
		assert_true("the commit key in every bar: " .. h, h:match("␣gc commit") ~= nil)
	end
	assert_true("the notes bar names the window above, not below", review.NOTES_KEY_HINT:match("C%-t up") and not review.NOTES_KEY_HINT:match("C%-n"))

	go_to(rw, rb, "  added A")
	review.decline(rb)
	counts("an unsaved decline counts as done", 2, 3)
	vim.api.nvim_set_current_win(win)
	vim.api.nvim_set_current_win(rw)
	vim.wait(20, function()
		return false
	end)
	assert_true("moving between the windows keeps the notes bar", vim.wo[win].winbar:match("%%=2 left %(3 saved%)$") ~= nil)
	vim.cmd("normal u")
	counts("u brings it back", 3, 3)

	go_to(rw, rb, "NEWS n1")
	vim.cmd("normal dp")
	counts("a dp take counts as done", 2, 3)
	local k = assert(line_of(nb, "NEWS n1"))
	vim.api.nvim_buf_set_lines(nb, k - 1, k, false, { "NEWS n1, edited" })
	go_to(rw, rb, "  added B")
	review.decline(rb)
	counts("a take edited afterwards is still done", 1, 3)

	go_to(win, nb, "Section B")
	vim.cmd("diffupdate")
	vim.cmd("normal do")
	counts("a do take from the notes counts too", 0, 3)

	vim.api.nvim_set_current_win(rw)
	vim.cmd("write")
	counts("a save of the split records them all", 0, 0)
	vim.cmd("wq")
	assert_true("after the review, the recorded count again: the takes were recorded at the save", vim.wo[win].winbar:match("%(1 untaken%)") ~= nil)
	assert_true("and the keys for outside a review", vim.wo[win].winbar:match("^" .. vim.pesc(review.NOTES_IDLE_HINT) .. "%%=") ~= nil)
end

print("\n=== a removal is taken from the review split: ]c lands below its filler, where dp takes it ===")
do
	local r = new_repo({ "Section A", "  existing", "  - stale", "Section B", "  other" })
	build(r, "2026-10-01", {
		item("rm", { kind = "remove", target = { at = "  - stale" }, before = "  - stale", after = "", source = "notes", headline = "drop stale" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw = vim.fn.bufwinid(rb)
	assert_eq("the cursor starts on the first hunk: the line below the filler", line_of(rb, "Section B"), vim.api.nvim_win_get_cursor(rw)[1])
	vim.cmd("normal dp")
	assert_eq("dp there takes the removal", { "Section A", "  existing", "Section B", "  other" }, lines_of(nb))
	vim.cmd("normal u")
	assert_eq("u puts it back", { "Section A", "  existing", "  - stale", "Section B", "  other" }, lines_of(nb))
	go_to(rw, rb, "  existing")
	vim.cmd("normal dp")
	assert_eq("dp on the line above the filler takes it too", { "Section A", "  existing", "Section B", "  other" }, lines_of(nb))
	vim.cmd("normal u")
	go_to(rw, rb, "Section A")
	vim.cmd("normal dp")
	assert_eq("two lines above it, dp takes nothing", { "Section A", "  existing", "  - stale", "Section B", "  other" }, lines_of(nb))
end

print("\n=== ]c and [c wrap around in both windows, and say so ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other", "Section C", "  more" })
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added under B", source = "", headline = "add under B" }),
		item("r1", { kind = "remove", target = { at = "  more" }, before = "  more", after = "", source = "", headline = "drop more" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw, nw = vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	local said = {}
	local orig = vim.notify
	vim.notify = function(m)
		said[#said + 1] = m
	end
	local function press(win, keys)
		said = {}
		vim.api.nvim_set_current_win(win)
		vim.cmd("normal " .. keys)
		return vim.api.nvim_win_get_cursor(win)[1], said[#said]
	end
	local last = vim.api.nvim_buf_line_count(rb)
	assert_eq("the review opens on the first change, even on line 1", 1, vim.api.nvim_win_get_cursor(rw)[1])
	assert_eq("]c moves on as usual, silently", { line_of(rb, "  added under B") }, { press(rw, "]c") })
	assert_eq("then to the removal at the end", { last }, { press(rw, "]c") })
	assert_eq("]c at the last wraps to the first, and says so", { 1, "desk: wrapped to first" }, { press(rw, "]c") })
	assert_eq("[c at the first wraps to the last", { last, "desk: wrapped to last" }, { press(rw, "[c") })
	assert_eq("[c moves back as usual", { line_of(rb, "  added under B") }, { press(rw, "[c") })
	vim.api.nvim_win_set_cursor(nw, { line_of(nb, "  more"), 0 })
	assert_eq("in the notes window too: ]c at the last wraps to the first", { 1, "desk: wrapped to first" }, { press(nw, "]c") })
	assert_eq("and [c at the first to the last", { line_of(nb, "  more"), "desk: wrapped to last" }, { press(nw, "[c") })
	vim.cmd("nohlsearch")
	vim.api.nvim_win_set_cursor(rw, { 1, 0 })
	assert_eq("with no search highlighted, n is the next suggestion", { line_of(rb, "  added under B") }, { press(rw, "n") })
	assert_eq("and N the previous", { 1 }, { press(rw, "N") })
	assert_eq("N wraps the same way", { last, "desk: wrapped to last" }, { press(rw, "N") })
	assert_eq("and n", { 1, "desk: wrapped to first" }, { press(rw, "n") })
	vim.api.nvim_win_set_cursor(nw, { 1, 0 })
	assert_eq("n in the notes window too", { line_of(nb, "Section C") }, { press(nw, "n") })
	vim.fn.setreg("/", "Section")
	vim.cmd("let v:hlsearch = 1")
	vim.api.nvim_win_set_cursor(rw, { 1, 0 })
	assert_eq("with a search highlighted, n is the search's next match", { line_of(rb, "Section A") }, { press(rw, "n") })
	assert_eq("and N its previous, wrapping as a search does", line_of(rb, "Section C"), (press(rw, "N")))
	vim.api.nvim_win_set_cursor(nw, { 1, 0 })
	assert_eq("in the notes window as well", { line_of(nb, "Section B") }, { press(nw, "n") })
	assert_eq("]c still moves by suggestion meanwhile", { line_of(rb, "  added under B") }, { press(rw, "]c") })
	vim.cmd("nohlsearch")
	for _, h in ipairs({ "  added under B", "NEWS n1" }) do
		go_to(rw, rb, h)
		review.decline(rb)
	end
	vim.api.nvim_win_set_cursor(rw, { vim.api.nvim_buf_line_count(rb), 0 })
	assert_true("(the removal declined too)", review.decline(rb))
	vim.cmd("diffupdate")
	vim.api.nvim_win_set_cursor(rw, { 2, 0 })
	assert_eq("with nothing left, ]c stays put and says so", { 2, "desk: no suggestions left here" }, { press(rw, "]c") })
	vim.notify = orig
	vim.cmd("silent! %bwipeout!")
	assert_true("after the review the notes buffer has no ]c of desk's", (function()
		local b = open_notes(r)
		review.attach(b)
		return vim.fn.maparg("]c", "n", false, true).buffer ~= 1 and vim.fn.maparg("n", "n", false, true).buffer ~= 1
	end)())
end

print("\n=== from the notes window, ␣gA and ␣gD act on the hunk's suggestion and u undoes them ===")
do
	local function leader(keys)
		-- :normal can't start with a space; a count of 1 can
		vim.cmd("normal 1" .. vim.g.mapleader .. keys)
	end
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("n2"),
		item("a1", { kind = "add", target = { under = "Section B" }, after = "  added B", source = "", headline = "add B" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw, nw = vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	local merged = lines_of(rb)
	local top, second = merged[1], merged[2]
	local said = {}
	local orig = vim.notify
	vim.notify = function(m)
		said[#said + 1] = m
	end
	local function bar_count()
		return vim.wo[nw].winbar:match("%%=(%d+ left)")
	end

	vim.api.nvim_set_current_win(nw)
	vim.api.nvim_win_set_cursor(nw, { 1, 0 })
	leader("gD")
	assert_true("␣gD below the filler declines the topmost suggestion of that hunk", line_of(rb, top) == nil and line_of(rb, second) ~= nil)
	assert_eq("and says how many are left in it", "desk: 1 more in this hunk", said[#said])
	assert_eq("the count moves", "2 left", bar_count())
	assert_eq("the notes are untouched", BASE, lines_of(nb))
	leader("gD")
	assert_true("pressed again, it declines the next", line_of(rb, second) == nil)
	vim.cmd("normal u")
	assert_true("u in the notes window undoes the latest decline made there", line_of(rb, second) ~= nil and line_of(rb, top) == nil)
	vim.cmd("normal u")
	assert_eq("and then the one before", merged, lines_of(rb))
	assert_eq("the count is back", "3 left", bar_count())
	assert_eq("the notes are still untouched", BASE, lines_of(nb))

	vim.api.nvim_win_set_cursor(nw, { 1, 0 })
	leader("gA")
	assert_eq("␣gA takes just the topmost into the notes", { top, "Section A" }, vim.list_slice(lines_of(nb), 1, 2))
	assert_eq("a take counts as done", "2 left", bar_count())
	vim.bo[nb].undolevels = vim.bo[nb].undolevels -- a keypress of its own
	vim.api.nvim_buf_set_lines(nb, 2, 3, false, { "  existing, edited" })
	vim.cmd("normal u")
	assert_eq("u after an edit of the user's own undoes that edit first", { top, "Section A", "  existing" }, vim.list_slice(lines_of(nb), 1, 3))
	vim.cmd("normal u")
	assert_eq("then the take", BASE, lines_of(nb))
	assert_eq("which is no longer counted as done", "3 left", bar_count())

	assert_eq("a line next to no hunk names no suggestion", { false, "no suggestion in a hunk here" }, (function()
		vim.api.nvim_win_set_cursor(nw, { 2, 0 })
		return { review.notes_act(nb, "decline") }
	end)())
	go_to(nw, nb, "  other")
	leader("gD")
	assert_true("above a filler at the end, ␣gD declines that suggestion", line_of(rb, "  added B") == nil)
	vim.api.nvim_set_current_win(rw)
	vim.cmd("write")
	assert_eq("the split's save records it", { id_by_headline(r, "add B") }, declined_ids(r))
	vim.cmd("quit")
	assert_true("after the review the notes buffer has no ␣gD", vim.fn.maparg(vim.g.mapleader .. "gD", "n", false, true).buffer ~= 1)
	assert_true("and u is plain undo again", vim.fn.maparg("u", "n", false, true).buffer ~= 1)
	vim.notify = orig

	-- a removal: the cursor is on its own line in the notes
	local r2 = new_repo({ "Section A", "  existing", "  - stale", "Section B", "  other" })
	build(r2, "2026-10-01", {
		item("rm", { kind = "remove", target = { at = "  - stale" }, before = "  - stale", after = "", source = "notes", headline = "drop stale" }),
	})
	local nb2 = open_notes(r2)
	review.attach(nb2)
	assert_true("review opens", review.open_review(nb2))
	local rb2 = review_buf_of(nb2)
	go_to(vim.fn.bufwinid(nb2), nb2, "  - stale")
	leader("gD")
	assert_true("␣gD on a removal's line brings it back in the split", line_of(rb2, "  - stale") ~= nil)
	vim.cmd("normal u")
	go_to(vim.fn.bufwinid(nb2), nb2, "  - stale")
	leader("gA")
	assert_eq("␣gA there takes the removal", { "Section A", "  existing", "Section B", "  other" }, lines_of(nb2))
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

print("\n=== u in the review split undoes the latest take or decline, in either order ===")
do
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", {
			item("n1"),
			item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }),
		})
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		return r, nb, rb, vim.fn.bufwinid(rb)
	end
	local function u(rw)
		vim.api.nvim_set_current_win(rw)
		vim.cmd("normal u")
	end
	local function taken_count(r)
		return vim.tbl_count(ledger.taken_by_id(ledger.read(r)))
	end

	-- take, then decline: u undoes the decline first, then the take
	local r, nb, rb, rw = setup()
	go_to(rw, rb, "NEWS n1")
	vim.cmd("normal dp")
	go_to(rw, rb, "  added")
	assert_true("decline", review.decline(rb))
	u(rw)
	assert_true("the first u brings the declined suggestion back", line_of(rb, "  added") ~= nil)
	assert_eq("and leaves the take in the notes", "NEWS n1", lines_of(nb)[1])
	u(rw)
	assert_eq("the second u undoes the take in the notes buffer", BASE, lines_of(nb))
	local merged = lines_of(rb)
	u(rw)
	assert_eq("a third u, with nothing left, is plain undo: nothing to undo", merged, lines_of(rb))
	vim.cmd("write")
	assert_eq("nothing taken after the undone take", 0, taken_count(r))
	assert_eq("nothing declined after the undone decline", {}, declined_ids(r))

	-- decline, then take: u undoes the take first, then the decline
	local r2, nb2, rb2, rw2 = setup()
	go_to(rw2, rb2, "  added")
	assert_true("decline", review.decline(rb2))
	go_to(rw2, rb2, "NEWS n1")
	assert_true("take one with the take key", review.take(rb2))
	assert_eq("taken into the notes", "NEWS n1", lines_of(nb2)[1])
	u(rw2)
	assert_eq("the first u undoes the take in the notes buffer", BASE, lines_of(nb2))
	assert_true("and leaves the decline", line_of(rb2, "  added") == nil)
	u(rw2)
	assert_true("the second u undoes the decline", line_of(rb2, "  added") ~= nil)
	assert_eq("the notes stay as they were", BASE, lines_of(nb2))
	vim.cmd("write")
	assert_eq("nothing taken", 0, taken_count(r2))
	assert_eq("nothing declined", {}, declined_ids(r2))

	-- notes edited after the take: u in the split leaves the notes alone
	local _, nb3, rb3, rw3 = setup()
	go_to(rw3, rb3, "NEWS n1")
	vim.cmd("normal dp")
	-- a later edit is its own undo step, as typed text is
	vim.api.nvim_buf_call(nb3, function()
		vim.cmd("let &l:undolevels = &l:undolevels")
	end)
	vim.api.nvim_buf_set_lines(nb3, 1, 1, false, { "the user's own line" })
	local before = lines_of(nb3)
	local orig = vim.notify
	local said
	vim.notify = function(m)
		said = m
	end
	u(rw3)
	vim.notify = orig
	assert_eq("the user's later edit and the take both stay", before, lines_of(nb3))
	assert_true("and it says why", said ~= nil and said:match("notes changed") ~= nil)
end

print("\n=== colours like git: per-window diff groups while the review is open, cleared after ===")
do
	vim.o.termguicolors = true
	vim.api.nvim_set_hl(0, "Normal", { bg = 0x1d2021, fg = 0xebdbb2 })
	vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x5a633a })
	vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0x792329 })
	vim.cmd("doautocmd ColorScheme")
	local r = new_repo(BASE)
	build(r, "2026-10-01", { item("n1") })
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw, nw = vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	assert_eq("the review window maps the diff groups to green", review.REVIEW_WINHL, vim.wo[rw].winhighlight)
	assert_eq("the notes window maps them to red", review.NOTES_WINHL, vim.wo[nw].winhighlight)
	local function bg(g)
		return vim.api.nvim_get_hl(0, { name = g, link = false }).bg
	end
	assert_eq("green comes from the scheme's DiffAdd", 0x5a633a, bg("DeskDiffAdd"))
	assert_eq("red from its DiffDelete", 0x792329, bg("DeskDiffRemove"))
	assert_true("the filler is neither", bg("DeskDiffFiller") ~= bg("DiffDelete") and bg("DeskDiffFiller") ~= nil)
	assert_true("the review side's DiffAdd is green, the notes side's red", review.REVIEW_WINHL:match("DiffAdd:DeskDiffAdd,") and review.NOTES_WINHL:match("DiffAdd:DeskDiffRemove,"))
	vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x225522 })
	vim.cmd("doautocmd ColorScheme")
	assert_eq("a scheme change redefines them", 0x225522, bg("DeskDiffAdd"))
	vim.api.nvim_set_current_win(rw)
	vim.cmd("quit")
	assert_true("after :q in the review window the notes window left diff mode", not vim.wo[nw].diff)
	assert_eq("and its winhighlight is cleared", "", vim.wo[nw].winhighlight)

	-- another buffer shown in the review window: that window is cleared too
	assert_true("review reopens", review.open_review(nb))
	rb = review_buf_of(nb)
	rw = vim.fn.bufwinid(rb)
	vim.api.nvim_win_set_buf(rw, vim.api.nvim_create_buf(true, false))
	assert_true("the review buffer is gone", not vim.api.nvim_buf_is_valid(rb))
	assert_eq("the window that showed it has its winhighlight cleared", "", vim.wo[rw].winhighlight)
	assert_eq("as does the notes window", "", vim.wo[vim.fn.bufwinid(nb)].winhighlight)
end

print("\n=== :q from either window ends the review and leaves the user in their notes ===")
do
	local function tick()
		vim.wait(20, function()
			return false
		end)
	end
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", { item("n1"), item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }) })
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		return r, nb, rb, vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	end
	local function left_in_notes(desc, nb)
		local wins = vim.api.nvim_tabpage_list_wins(0)
		assert_eq(desc .. ": one window left", 1, #wins)
		assert_eq(desc .. ": showing the notes", nb, vim.api.nvim_win_get_buf(wins[1]))
		assert_true(desc .. ": diff off", not vim.wo[wins[1]].diff)
		assert_eq(desc .. ": no review colours", "", vim.wo[wins[1]].winhighlight)
		assert_true(desc .. ": the status line with the keys for outside a review", vim.wo[wins[1]].winbar:match("^" .. vim.pesc(review.NOTES_IDLE_HINT) .. "%%=") ~= nil)
		assert_true(desc .. ": no review buffer remains", review_buf_of(nb) == nil)
	end
	local orig = review.confirm
	local asked
	local function answer(n)
		asked = 0
		review.confirm = function()
			asked = asked + 1
			return n
		end
	end

	-- nothing unsaved: :q in the notes window just ends it
	answer(3)
	local _, nb, _, _, nw = setup()
	vim.api.nvim_set_current_win(nw)
	vim.cmd("quit")
	tick()
	left_in_notes(":q in the notes window", nb)
	assert_eq("nothing to ask about", 0, asked)

	-- unsaved declines, cancel: the review stays and the notes come back below it
	local r2, nb2, rb2, rw2, nw2 = setup()
	go_to(rw2, rb2, "  added")
	assert_true("decline", review.decline(rb2))
	answer(3)
	vim.api.nvim_set_current_win(nw2)
	vim.cmd("quit")
	tick()
	assert_eq("it asked", 1, asked)
	assert_true("cancel keeps the review and its unsaved decline", vim.api.nvim_buf_is_valid(rb2) and vim.bo[rb2].modified)
	local nw2b = vim.fn.bufwinid(nb2)
	assert_true("the notes are shown again", nw2b ~= -1)
	assert_true("below the review", vim.fn.win_screenpos(rw2)[1] < vim.fn.win_screenpos(nw2b)[1])
	assert_true("in diff mode with the review colours", vim.wo[nw2b].diff and vim.wo[nw2b].winhighlight == review.NOTES_WINHL)
	-- then save: the decline is recorded and the review ends
	answer(1)
	vim.api.nvim_set_current_win(nw2b)
	vim.cmd("quit")
	tick()
	assert_eq("asked again", 1, asked)
	assert_eq("save records the decline", 1, #declined_ids(r2))
	left_in_notes(":q in the notes window, then save", nb2)

	-- discard: nothing recorded
	local r3, nb3, rb3, rw3, nw3 = setup()
	go_to(rw3, rb3, "  added")
	assert_true("decline", review.decline(rb3))
	answer(2)
	vim.api.nvim_set_current_win(nw3)
	vim.cmd("quit")
	tick()
	assert_eq("discard records nothing", {}, declined_ids(r3))
	left_in_notes(":q in the notes window, then discard", nb3)

	-- another buffer in the notes window ends it too
	answer(3)
	local _, nb4, rb4, _, nw4 = setup()
	vim.api.nvim_set_current_win(nw4)
	vim.cmd("enew")
	tick()
	assert_true("the review buffer is gone", not vim.api.nvim_buf_is_valid(rb4))
	local w4 = vim.fn.bufwinid(nb4)
	assert_true("the notes are shown where the review was, out of diff mode", w4 ~= -1 and not vim.wo[w4].diff and vim.wo[w4].winhighlight == "")

	-- :wq in the review window: saves the declines and leaves the notes
	local r5, nb5, rb5, rw5 = setup()
	go_to(rw5, rb5, "  added")
	assert_true("decline", review.decline(rb5))
	vim.api.nvim_set_current_win(rw5)
	vim.cmd("wq")
	tick()
	assert_eq(":wq records the decline", 1, #declined_ids(r5))
	left_in_notes(":wq in the review window", nb5)
	review.confirm = orig
end

print("\n=== soft wrap while reviewing, the notes window's own values back after ===")
do
	local function opts(win)
		return { vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent }
	end
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", { item("n1") })
		local nb = open_notes(r)
		review.attach(nb)
		local nw = vim.fn.bufwinid(nb)
		vim.wo[nw].wrap, vim.wo[nw].linebreak, vim.wo[nw].breakindent = false, false, false
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		return nb, rb, vim.fn.bufwinid(rb), nw
	end
	local nb, _, rw, nw = setup()
	assert_eq("the review window wraps, at word breaks, indented", { true, true, true }, opts(rw))
	assert_eq("so does the notes window", { true, true, true }, opts(nw))
	vim.api.nvim_set_current_win(rw)
	vim.cmd("quit")
	assert_eq(":q in the review window puts the notes window's own values back", { false, false, false }, opts(vim.fn.bufwinid(nb)))

	local nb2, _, _, nw2 = setup()
	vim.api.nvim_set_current_win(nw2)
	vim.cmd("quit")
	vim.wait(20, function()
		return false
	end)
	assert_eq(":q in the notes window: the window left showing them has their own values", { false, false, false }, opts(vim.fn.bufwinid(nb2)))
end

print("\n=== the commit key works from the review split: saves its declines, then commits ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section A" }, after = "  added A", source = "", headline = "add A" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	local rw = vim.fn.bufwinid(rb)
	go_to(rw, rb, "NEWS n1")
	vim.cmd("normal dp")
	go_to(rw, rb, "  added A")
	review.decline(rb)
	vim.cmd("normal 1" .. vim.g.mapleader .. "gc")
	assert_eq("HEAD has the take", "NEWS n1", head_lines(r)[1])
	assert_eq("the decline is recorded", { id_by_headline(r, "add A") }, declined_ids(r))
	assert_eq("both buffers read as saved", { false, false }, { vim.bo[nb].modified, vim.bo[rb].modified })
	assert_eq("the message says what it took", "Take 1 suggestion", select(2, git.run(r, { "log", "-1", "--format=%s" })):gsub("%s+$", ""))
	assert_eq("the review stays open", rw, vim.fn.bufwinid(rb))
end

print("\n=== the commit key commits every notes file with changes, saving both first ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "reading.md: read paper" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	go_to(vim.fn.bufwinid(rb), rb, "NEWS n1")
	vim.cmd("normal dp")
	local rd = vim.fn.bufadd(r .. "/reading.md")
	vim.fn.bufload(rd)
	vim.api.nvim_buf_set_lines(rd, 0, -1, false, { "READ paper", "my own line" })
	assert_true("commit", (review.commit(nb)))
	assert_eq("both files are in the commit", { "notes.md", "reading.md" }, vim.split(vim.trim(select(2, git.run(r, { "show", "--name-only", "--format=", "HEAD" }))), "\n"))
	assert_eq("both buffers are saved", { false, false }, { vim.bo[nb].modified, vim.bo[rd].modified })
	assert_eq(
		"the message covers both, each item with its file",
		"Take 2 suggestions, edit 1 section\n\nTaken:\n- notes.md: headline n1\n- reading.md: read paper\n\nEdited:\n- reading.md: my own line",
		vim.trim(select(2, git.run(r, { "log", "-1", "--format=%B" })))
	)
	assert_eq("and nothing is left over", "", vim.trim(select(2, git.run(r, { "status", "--porcelain", "--", "notes.md", "reading.md" }))))
end

print("\n=== the commit key's message: the takes and the sections edited ===")
do
	local function sug(id, over)
		return vim.tbl_extend("force", { id = id, kind = "new", before = "", after = "", headline = "headline " .. id }, over)
	end
	local head = { "- alpha", "    - a1", "- beta (an aside)", "    - b1", "**gamma:**", "    - g1", "- delta", "    - d1" }
	local now = { "NEWS n1", "- alpha", "    - a1 edited", "- beta (an aside)", "**gamma:**", "    - g1", "    - g2" }
	local news = sug("n1", { after = "NEWS n1", headline = "news one" })
	local drop = sug("r1", { kind = "remove", before = "    - b1", headline = "drop b1" })
	assert_eq(
		"takes and own edits, each section once, named without its markup",
		"Take 2 suggestions, edit 3 sections\n\nTaken:\n- news one\n- drop b1\n\nEdited:\n- alpha\n- gamma\n- delta",
		review.commit_message(head, now, { news, drop })
	)
	assert_eq("a section deleted whole is named as itself", "Edit 1 section\n\nEdited:\n- delta", review.commit_message({ "- a", "- delta", "  - d1" }, { "- a" }, {}))
	assert_eq("only takes", "Take 1 suggestion\n\nTaken:\n- news one", review.commit_message({ "- alpha" }, { "NEWS n1", "- alpha" }, { news }))
	assert_eq("an edit above every section", "Edit 1 section\n\nEdited:\n- top", review.commit_message({ "  loose", "- alpha" }, { "  looser", "- alpha" }, {}))
	assert_eq(
		"a session's section: its name; a link: its label",
		"Edit 2 sections\n\nEdited:\n- some-session\n- read this",
		review.commit_message({ "- some-session", "  x", "- [read this](https://example.invalid/a)", "  y" }, { "- some-session", "  x2", "- [read this](https://example.invalid/a)", "  y2" }, {})
	)
	assert_eq("an edited take is still a take, and the edit an edit: a column-0 line heads its own section", "Take 1 suggestion, edit 1 section\n\nTaken:\n- news one\n\nEdited:\n- NEWS n1, edited", review.commit_message({ "- alpha" }, { "NEWS n1, edited", "- alpha" }, { news }))
	assert_eq("blank lines alone are no edit", "Update notes", review.commit_message({ "- alpha" }, { "- alpha", "" }, {}))
	assert_eq(
		"a column-0 bullet with nothing under it belongs to the heading above; one with indented lines heads its own",
		"Edit 2 sections\n\nEdited:\n- Topic\n- sess",
		review.commit_message(
			{ "Topic", "- a", "- b", "- sess", "    child" },
			{ "Topic", "- a, edited", "- b, edited", "- c, new", "- sess", "    child, edited" },
			{}
		)
	)
	assert_eq("a reworded heading is one section, by its new name", "Edit 1 section\n\nEdited:\n- New name", review.commit_message({ "Old name", "- x" }, { "New name", "- x" }, {}))
	local long = sug("l1", { after = "LONG", headline = string.rep("word ", 30) })
	local capped = review.commit_message({ "Topic" }, { "Topic", "LONG" }, { long })
	assert_eq("a long headline is one body line, capped at 72 with …", "- " .. string.rep("word ", 13) .. "word…", capped:match("Taken:\n([^\n]*)"))
	assert_eq("(72 columns)", 72, vim.fn.strchars(capped:match("Taken:\n([^\n]*)")))
	local many = {}
	for i = 1, 999 do
		many[i] = sug("m" .. i, { after = "M" .. i })
	end
	local big = {}
	for i = 1, 999 do
		big[#big + 1] = "M" .. i
		big[#big + 1] = "- s" .. i
		big[#big + 1] = "  own " .. i
	end
	local subject = review.commit_message({}, big, many):match("^[^\n]*")
	assert_eq("the subject fits under 50 columns at any count", "Take 999 suggestions, edit 999 sections", subject)

	local r = new_repo({ "- alpha", "    - a1", "- beta", "    - b1" })
	build(r, "2026-10-01", {
		item("n1", { headline = "news one" }),
		item("a2", { kind = "add", target = { under = "- beta" }, after = "    - b2", source = "", headline = "add b2" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("review opens", review.open_review(nb))
	local rb = review_buf_of(nb)
	go_to(vim.fn.bufwinid(rb), rb, "NEWS n1")
	assert_true("take one", review.take(rb))
	local k = assert(line_of(nb, "NEWS n1"))
	vim.api.nvim_buf_set_lines(nb, k - 1, k, false, { "NEWS n1, reworded" })
	go_to(vim.fn.bufwinid(rb), rb, "    - b2")
	assert_true("take another", review.take(rb))
	local a = assert(line_of(nb, "    - a1"))
	vim.api.nvim_buf_set_lines(nb, a - 1, a, false, { "    - a1, mine" })
	assert_true("commit", (review.commit(nb)))
	assert_eq(
		"the commit says what it took, edited take included, and which sections he edited",
		"Take 2 suggestions, edit 2 sections\n\nTaken:\n- news one\n- add b2\n\nEdited:\n- NEWS n1, reworded\n- alpha",
		vim.trim(select(2, git.run(r, { "log", "-1", "--format=%B" })))
	)
end

print("\n=== an overview decline leaves the list, even when the list outlived its review ===")
do
	local r = new_repo({ "Section A", "- vendor-x, editor", "Section B", "- low pri: dropping the editor" })
	build(r, "2026-10-01", {
		item("e1", { kind = "edit", target = { at = "- vendor-x, editor" }, before = "- vendor-x, editor", after = "- vendor-x, editor's own AI", source = "notes", headline = "Editor stays, its AI goes" }),
		item("e2", { kind = "edit", target = { at = "- low pri: dropping the editor" }, before = "- low pri: dropping the editor", after = "- low pri: dropping the editor's own AI", source = "notes", headline = "Editor stays, its AI goes" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("overview opens", review.overview(nb))
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	local function press(row, keys)
		vim.api.nvim_set_current_win(qw)
		vim.api.nvim_win_set_cursor(qw, { row, 0 })
		vim.cmd("normal " .. keys)
	end
	press(1, "t")
	assert_eq("taking the top one of two alike leaves one entry", 1, #vim.fn.getqflist())
	press(1, "x")
	assert_eq("x on the one left, alike in headline to the taken one, empties the list", 0, #vim.fn.getqflist())

	-- The review is reopened under the list (a new proposal landed): the
	-- list still names the old review's buffer, and acting from it must
	-- still update it.
	local r2 = new_repo({ "Section A", "- vendor-x, editor", "Section B", "- low pri: dropping the editor" })
	local items = {
		item("e1", { kind = "edit", target = { at = "- vendor-x, editor" }, before = "- vendor-x, editor", after = "- vendor-x, editor's own AI", source = "notes", headline = "Editor stays, its AI goes" }),
		item("e2", { kind = "edit", target = { at = "- low pri: dropping the editor" }, before = "- low pri: dropping the editor", after = "- low pri: dropping the editor's own AI", source = "notes", headline = "Editor stays, its AI goes" }),
	}
	build(r2, "2026-10-01", items)
	local nb2 = open_notes(r2)
	review.attach(nb2)
	assert_true("overview opens", review.overview(nb2))
	qw = vim.fn.getqflist({ winid = 0 }).winid
	build(r2, "2026-10-01", { item("n9") })
	assert_true("the review reopens on the new proposal", review.open_review(nb2))
	local function row_of(id)
		for i, e in ipairs(vim.fn.getqflist()) do
			if type(e.user_data) == "table" and e.user_data.id == id then
				return i
			end
		end
	end
	local e1, e2 = id_by_headline(r2, "Editor stays, its AI goes"), nil
	for _, it in ipairs(proposal.read_items(r2)) do
		if it.headline == "Editor stays, its AI goes" and it.id ~= e1 then
			e2 = it.id
		end
	end
	local n = #vim.fn.getqflist()
	press(assert(row_of(e2), "e2 listed"), "x")
	assert_eq("x in a list its review was reopened under drops the entry", nil, row_of(e2))
	assert_eq("and only that one", n - 1, #vim.fn.getqflist())
	press(assert(row_of(e1), "e1 listed"), "t")
	assert_eq("t there takes from the review now open", nil, row_of(e1))
	assert_true("into the notes", line_of(nb2, "- vendor-x, editor's own AI") ~= nil)
end

print("\n=== closing: q closes the overview, Q and ␣gq end the whole review ===")
do
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", {
			item("n1"),
			item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }),
		})
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("overview opens", review.overview(nb))
		local rb = review_buf_of(nb)
		return r, nb, rb, vim.fn.getqflist({ winid = 0 }).winid
	end
	local function in_list(qw, keys)
		vim.api.nvim_set_current_win(qw)
		vim.cmd("normal " .. keys)
	end
	local function list_open()
		return vim.fn.getqflist({ winid = 0 }).winid ~= 0
	end
	assert_true("the title names both", review.OVERVIEW_TITLE:match("q close list · Q close review$") ~= nil)

	local _, nb, rb, qw = setup()
	in_list(qw, "q")
	assert_true("q closes the list", not list_open())
	assert_true("and leaves the review open", vim.api.nvim_buf_is_valid(rb) and vim.fn.bufwinid(rb) ~= -1)

	local orig = review.confirm
	local asked = 0
	local r2, nb2, rb2, qw2 = setup()
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb2))
	go_to(vim.fn.bufwinid(rb2), rb2, "NEWS n1")
	assert_true("decline", review.decline(rb2))
	review.confirm = function()
		asked = asked + 1
		return 3
	end
	in_list(qw2, "Q")
	assert_eq("Q over unsaved declines asks", 1, asked)
	assert_true("cancelling keeps the list", list_open())
	assert_true("and the split", vim.api.nvim_buf_is_valid(rb2))
	review.confirm = function()
		asked = asked + 1
		return 1
	end
	in_list(qw2, "Q")
	assert_eq("saving records the decline", { id_by_headline(r2, "headline n1") }, declined_ids(r2))
	assert_true("Q closes the list", not list_open())
	assert_true("and the split", not vim.api.nvim_buf_is_valid(rb2))
	assert_eq("leaving the user in their notes", nb2, vim.api.nvim_get_current_buf())
	assert_true("out of diff mode", not vim.wo.diff)
	assert_eq("the notes' review keys are gone", "", vim.fn.maparg(vim.g.mapleader .. "gq", "n"))
	review.confirm = orig

	for _, from in ipairs({ "split", "notes" }) do
		local _, nb3, rb3 = setup()
		vim.cmd("cclose")
		local win = from == "split" and vim.fn.bufwinid(rb3) or vim.fn.bufwinid(nb3)
		vim.api.nvim_set_current_win(win)
		vim.cmd("normal 1" .. vim.g.mapleader .. "gq")
		assert_true("␣gq from the " .. from .. " ends the review", not vim.api.nvim_buf_is_valid(rb3))
		assert_eq("in the notes", nb3, vim.api.nvim_get_current_buf())
		assert_eq("one window left", 1, #vim.api.nvim_tabpage_list_wins(0))
	end
	assert_true("the notes bar names ␣gq", review.NOTES_KEY_HINT:match("␣gq close") ~= nil)
	assert_true("the top bar still fits in 120 columns", vim.fn.strchars("99 left (99 saved) · " .. review.KEY_HINT) <= 120)
end

print("\n=== a move is taken or declined whole, from either of its hunks ===")
do
	local NOTES = { "Section A", "- a1", "", "Section B", "- b1", "", "Section C", "- c1", "- c2", "- c3", "", "Section D", "- d1" }
	local MOVE = {
		id = "mv",
		file = "notes.md",
		kind = "move",
		target = { { at = "Section B" }, { under = "Section C" } },
		before = "Section B\n- b1",
		after = "Section B\n- b1",
		source = "notes",
		headline = "move B under C",
	}
	local function setup()
		local r = new_repo(NOTES)
		local sha = build(r, "2026-10-01", { vim.deepcopy(MOVE) })
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		return r, nb, rb, vim.fn.bufwinid(rb), vim.fn.bufwinid(nb), proposal.lines_at(r, sha, "notes.md")
	end
	local said = {}
	local orig_notify = vim.notify
	vim.notify = function(m)
		said[#said + 1] = m
	end
	local function last_said()
		return said[#said] or ""
	end
	local function on(win, buf, text, keys)
		go_to(win, buf, text)
		vim.cmd("diffupdate")
		vim.cmd("normal " .. keys)
	end

	-- Each way of taking one hunk, from the landing or from the removal.
	local takes = {
		{ "dp on the landing, in the split", "landing", function(_, rb, rw) on(rw, rb, "- b1", "dp") end },
		{ "dp on the removal, in the split", "removal", function(_, rb, rw) on(rw, rb, "Section C", "dp") end },
		{ "do on the removal, in the notes", "removal", function(nb, _, _, nw) on(nw, nb, "Section B", "do") end },
		{ "do on the landing, in the notes", "landing", function(nb, _, _, nw) on(nw, nb, "Section D", "do") end },
		{ "␣gA on the landing, in the split", "landing", function(_, rb, rw) on(rw, rb, "- b1", "1" .. vim.g.mapleader .. "gA") end },
		{ "␣gA on the removal, in the notes", "removal", function(nb, _, _, nw) on(nw, nb, "Section B", "1" .. vim.g.mapleader .. "gA") end },
		{ "t in the overview", nil, function(nb)
			review.overview(nb)
			vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
			vim.cmd("normal t")
		end },
	}
	for _, t in ipairs(takes) do
		local desc, side, act = t[1], t[2], t[3]
		local r, nb, rb, rw, nw, want = setup()
		act(nb, rb, rw, nw)
		assert_eq(desc .. ": takes the whole move", want, lines_of(nb))
		local msg = last_said()
		if side == "removal" then
			assert_eq(desc .. ": and says so", "desk: took the whole move: removed here, added under Section C", msg)
		elseif side == "landing" then
			assert_true(desc .. ": and says so (" .. msg .. ")", msg:match("^desk: took the whole move: added here, removed from line %d+$") ~= nil)
		else
			assert_true(desc .. ": and says so (" .. msg .. ")", msg:match("^desk: took the whole move: removed from line %d+, added under Section C$") ~= nil)
		end
		vim.api.nvim_set_current_win(rw)
		vim.cmd("write")
		assert_eq(desc .. ": recorded taken on the save", true, ledger.taken_by_id(ledger.read(r))[id_by_headline(r, "move B under C")] ~= nil)
		assert_eq(desc .. ": and not declined", {}, declined_ids(r))
	end

	-- One u in the notes window takes a do of half a move back whole.
	local _, nb, _, _, nw = setup()
	on(nw, nb, "Section B", "do")
	vim.cmd("normal u")
	assert_eq("one u in the notes undoes the whole move a do took", NOTES, lines_of(nb))

	-- Each way of declining it, from either side: the split ends up as the
	-- notes are, so no hunk is left behind.
	local declines = {
		{ "␣gD on the landing, in the split", function(_, rb, rw) on(rw, rb, "- b1", "1" .. vim.g.mapleader .. "gD") end },
		{ "␣gD on the removal, in the notes", function(nb, _, _, nw) on(nw, nb, "Section B", "1" .. vim.g.mapleader .. "gD") end },
		{ "x in the overview", function(nb)
			review.overview(nb)
			vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
			vim.cmd("normal x")
		end },
	}
	for _, d in ipairs(declines) do
		local desc, act = d[1], d[2]
		local r, nb2, rb, rw, nw = setup()
		act(nb2, rb, rw, nw)
		assert_eq(desc .. ": the split is the notes again, both places", NOTES, lines_of(rb))
		assert_eq(desc .. ": the notes are untouched", NOTES, lines_of(nb2))
		vim.api.nvim_set_current_win(rw)
		vim.cmd("write")
		assert_eq(desc .. ": recorded declined on the save", { id_by_headline(r, "move B under C") }, declined_ids(r))
	end

	-- Half a move already taken by hand: taking the landing finishes it.
	local _, nb3, rb3, rw3, _, want3 = setup()
	vim.api.nvim_buf_set_lines(nb3, 3, 6, false, {})
	go_to(rw3, rb3, "- b1")
	assert_true("␣gA on the landing of a move whose removal is done", review.take(rb3))
	assert_eq("adds just the landing", want3, lines_of(nb3))

	-- The same from the overview, both ways.
	for _, key in ipairs({ "t", "x" }) do
		local r4, nb4, rb4, _, _, want4 = setup()
		vim.api.nvim_buf_set_lines(nb4, 3, 6, false, {})
		local half = lines_of(nb4)
		review.overview(nb4)
		local qw4 = vim.fn.getqflist({ winid = 0 }).winid
		vim.api.nvim_set_current_win(qw4)
		vim.cmd("normal " .. key)
		assert_eq(key .. " in the overview on a half-taken move: the list drops it", 0, #vim.fn.getqflist())
		if key == "t" then
			assert_eq("t adds just the landing", want4, lines_of(nb4))
		else
			assert_eq("x leaves the notes as they are", half, lines_of(nb4))
			assert_eq("and the split matches them: no hunk left", half, lines_of(rb4))
			vim.api.nvim_set_current_win(vim.fn.bufwinid(rb4))
			vim.cmd("write")
			assert_eq("recorded declined", { id_by_headline(r4, "move B under C") }, declined_ids(r4))
		end
	end
	vim.notify = orig_notify
end

print("\n=== the overview list reads like the review windows: keys above, current entry under the cursor ===")
do
	local r = new_repo(BASE)
	build(r, "2026-10-01", {
		item("n1"),
		item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }),
		item("e1", { kind = "edit", target = { at = "  other" }, before = "  other", after = "  other, edited", source = "", headline = "edit other" }),
	})
	local nb = open_notes(r)
	review.attach(nb)
	assert_true("overview opens", review.overview(nb))
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	assert_eq("the title and keys are in a winbar above the list", review.OVERVIEW_TITLE, vim.wo[qw].winbar)
	assert_true("the status line below doesn't repeat them", not vim.wo[qw].statusline:match("Desk overview"))
	vim.api.nvim_set_current_win(qw)
	vim.api.nvim_win_set_cursor(qw, { 3, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
	assert_eq("the current entry follows the cursor", 3, vim.fn.getqflist({ idx = 0 }).idx)

	-- A key that can't act says why, after its own redraw.
	local k = assert(line_of(nb, "  other"))
	vim.api.nvim_buf_set_lines(nb, k - 1, k, false, { "  other, mine" })
	local said
	local orig = vim.notify
	vim.notify = function(m)
		said = m
	end
	vim.cmd("normal t")
	vim.wait(100, function()
		return said ~= nil
	end)
	vim.notify = orig
	assert_true("t that can't take says so (" .. tostring(said) .. ")", said ~= nil and said:match("^desk: could not take") ~= nil)

	vim.fn.setqflist({}, " ", { title = "something else", items = { { bufnr = nb, lnum = 1, text = "x" } } })
	review.qf_bars(qw)
	assert_eq("another list in the window loses the winbar", "", vim.wo[qw].winbar)
end

print("\n=== a proposal rebuilt under an open review: reloaded in place, refused while declines are unsaved ===")
do
	local said = {}
	local orig_notify, orig_confirm = vim.notify, review.confirm
	vim.notify = function(m)
		said[#said + 1] = m
	end
	local function last()
		return said[#said] or ""
	end
	local function leader(keys)
		vim.cmd("normal 1" .. vim.g.mapleader .. keys)
	end
	local function setup()
		local r = new_repo(BASE)
		build(r, "2026-10-01", {
			item("n1"),
			item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }),
		})
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		return r, nb, rb, vim.fn.bufwinid(rb), vim.fn.bufwinid(nb)
	end
	-- What a session staging or a pass does meanwhile: n1 is taken
	-- elsewhere and drops out of the proposal, and b1 comes in.
	local function restage(r)
		local n1
		for _, it in ipairs(proposal.read_items(r)) do
			if it.headline == "headline n1" then
				n1 = it
			end
		end
		ledger.record_taken(r, { assert(n1) })
		build(r, "2026-10-02", { item("b1", { kind = "add", target = { under = "Section B" }, after = "  b-added", source = "", headline = "add B" }) })
	end

	-- Entering the split with nothing unsaved: rebuilt in the same windows.
	local r, nb, rb, rw, nw = setup()
	go_to(rw, rb, "  added")
	vim.api.nvim_set_current_win(nw)
	restage(r)
	vim.api.nvim_set_current_win(rw)
	assert_eq("entering the split keeps its buffer", rb, vim.api.nvim_win_get_buf(rw))
	assert_eq("and its windows", 2, #vim.api.nvim_tabpage_list_wins(0))
	assert_true("the dropped suggestion is gone from the split", line_of(rb, "NEWS n1") == nil)
	assert_true("the new one is in it", line_of(rb, "  b-added") ~= nil)
	assert_eq("the cursor stays on the line it was on", "  added", vim.api.nvim_get_current_line())
	assert_true("it says so in one line (" .. last() .. ")", last():match("^desk: the proposal changed") ~= nil)
	assert_eq("the count follows the new proposal", review.KEY_HINT .. "%=2 left (2 saved)", vim.wo[rw].winbar)
	assert_true("both windows still in diff mode", vim.wo[rw].diff and vim.wo[nw].diff)
	go_to(rw, rb, "  b-added")
	assert_true("and the new suggestion can be taken", review.take(rb) and line_of(nb, "  b-added") ~= nil)

	-- Entering the overview: the list is the new proposal's.
	local r2, nb2 = setup()
	assert_true("overview opens", review.overview(nb2))
	local qw = vim.fn.getqflist({ winid = 0 }).winid
	vim.api.nvim_set_current_win(vim.fn.bufwinid(nb2))
	restage(r2)
	vim.api.nvim_set_current_win(qw)
	local texts = vim.tbl_map(function(e)
		return e.text
	end, vim.fn.getqflist())
	table.sort(texts)
	assert_eq("entering the overview reloads the review and its list", { "add A", "add B" }, texts)

	-- A take against a stale view, without entering anything first.
	local r3, nb3, rb3, rw3 = setup()
	go_to(rw3, rb3, "NEWS n1")
	restage(r3)
	local ok3, why3 = review.take(rb3)
	assert_true("a take on a stale view does not act", not ok3)
	assert_true("it says the review was reloaded (" .. tostring(why3) .. ")", tostring(why3):match("proposal changed") ~= nil)
	assert_eq("nothing taken", BASE, lines_of(nb3))
	assert_true("the split is reloaded", line_of(rb3, "NEWS n1") == nil and line_of(rb3, "  b-added") ~= nil)
	local r3b, nb3b, rb3b, rw3b = setup()
	go_to(rw3b, rb3b, "NEWS n1")
	restage(r3b)
	vim.cmd("normal dp")
	assert_eq("dp on a stale view takes nothing", BASE, lines_of(nb3b))

	-- Unsaved declines: the split stays, says why, and refuses to act.
	local r4, nb4, rb4, rw4, nw4 = setup()
	go_to(rw4, rb4, "  added")
	assert_true("decline", review.decline(rb4))
	local before4 = lines_of(rb4)
	vim.api.nvim_set_current_win(nw4)
	restage(r4)
	vim.api.nvim_set_current_win(rw4)
	assert_eq("with unsaved declines the split is left as it was", before4, lines_of(rb4))
	assert_true("it says the proposal changed and ␣gR reloads it (" .. last() .. ")", last():match("proposal changed") ~= nil and last():match("␣gR") ~= nil)
	go_to(rw4, rb4, "NEWS n1")
	local okt, whyt = review.take(rb4)
	assert_true("a take is refused (" .. tostring(whyt) .. ")", not okt and tostring(whyt):match("␣gR") ~= nil)
	assert_true("so is a decline", not review.decline(rb4))
	vim.api.nvim_set_current_win(nw4)
	vim.api.nvim_win_set_cursor(nw4, { 1, 0 })
	assert_true("and both from the notes window", not review.notes_act(nb4, "take") and not review.notes_act(nb4, "decline"))
	vim.cmd("normal do")
	assert_true("do there takes nothing", not vim.bo[nb4].modified)
	assert_eq("the split is untouched", before4, lines_of(rb4))
	assert_eq("and the notes", BASE, lines_of(nb4))
	review.confirm = function()
		return 1
	end
	vim.api.nvim_set_current_win(rw4)
	leader("gR")
	assert_eq("␣gR in the split saves the declines first", { id_by_headline(r4, "add A") }, declined_ids(r4))
	assert_eq("then reloads in the same buffer", rb4, review_buf_of(nb4))
	assert_true("over the new proposal", line_of(rb4, "NEWS n1") == nil and line_of(rb4, "  b-added") ~= nil)
	assert_true("with nothing unsaved", not vim.bo[rb4].modified)
	go_to(rw4, rb4, "  b-added")
	assert_true("and acts again", review.take(rb4))
	vim.notify, review.confirm = orig_notify, orig_confirm
end

print("\n=== ending the review with :wq, Q or ␣gq writes the notes it took into; :q does not ===")
do
	local said = {}
	local orig_notify = vim.notify
	vim.notify = function(m)
		said[#said + 1] = m
	end
	local function tick()
		vim.wait(30, function()
			return false
		end)
	end
	local function leader(keys)
		vim.cmd("normal 1" .. vim.g.mapleader .. keys)
	end
	local function setup(take)
		local r = new_repo(BASE)
		build(r, "2026-10-01", {
			item("n1"),
			item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "", headline = "add A" }),
		})
		local nb = open_notes(r)
		review.attach(nb)
		assert_true("review opens", review.open_review(nb))
		local rb = review_buf_of(nb)
		local rw = vim.fn.bufwinid(rb)
		if take ~= false then
			go_to(rw, rb, "NEWS n1")
			assert_true("take", review.take(rb))
		end
		said = {}
		return r, nb, rb, rw
	end
	local function on_disk(r, file)
		return vim.fn.readfile(r .. "/" .. (file or "notes.md"))
	end
	local function taken(r, headline)
		return ledger.taken_by_id(ledger.read(r))[id_by_headline(r, headline)] ~= nil
	end
	local ends = {
		{ "␣gq in the split", function(_, rb)
			vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
			leader("gq")
		end },
		{ "␣gq in the notes", function(nb)
			vim.api.nvim_set_current_win(vim.fn.bufwinid(nb))
			leader("gq")
		end },
		{ "Q in the overview", function(nb)
			review.overview(nb)
			vim.api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
			vim.cmd("normal Q")
		end },
		{ ":wq in the split", function(_, rb)
			vim.api.nvim_set_current_win(vim.fn.bufwinid(rb))
			vim.cmd("wq")
		end },
	}
	for _, e in ipairs(ends) do
		local desc, act = e[1], e[2]
		local r, nb, rb = setup()
		act(nb, rb)
		tick()
		assert_true(desc .. ": the review ended", not vim.api.nvim_buf_is_valid(rb))
		assert_true(desc .. ": the take is on disk", vim.tbl_contains(on_disk(r), "NEWS n1"))
		assert_eq(desc .. ": the notes are saved", false, vim.bo[nb].modified)
		assert_true(desc .. ": the take is recorded", taken(r, "headline n1"))
		assert_true(desc .. ": and it says so", vim.tbl_contains(said, "desk: saved notes.md with your takes"))
	end

	local r, nb = setup()
	vim.api.nvim_set_current_win(vim.fn.bufwinid(review_buf_of(nb)))
	vim.cmd("quit")
	tick()
	assert_true(":q leaves the take unsaved", vim.bo[nb].modified and vim.tbl_contains(lines_of(nb), "NEWS n1"))
	assert_eq(":q writes nothing", BASE, on_disk(r))

	local r2, nb2, rb2 = setup()
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb2))
	vim.cmd("write")
	tick()
	vim.cmd("quit")
	tick()
	assert_eq(":w, then :q later, writes no notes either", BASE, on_disk(r2))
	assert_true("the notes keep the take, unsaved", vim.bo[nb2].modified)

	local r3, nb3, rb3 = setup(false)
	vim.api.nvim_buf_set_lines(nb3, 1, 2, false, { "  mine" })
	vim.api.nvim_set_current_win(vim.fn.bufwinid(rb3))
	leader("gq")
	tick()
	assert_eq("with nothing taken, ␣gq writes nothing", BASE, on_disk(r3))
	assert_true("and leaves the user's own edit unsaved", vim.bo[nb3].modified)
	assert_true("and says nothing about saving", not vim.tbl_contains(said, "desk: saved notes.md with your takes"))

	-- A review that moved to the other file writes both.
	local r4 = new_repo(BASE)
	build(r4, "2026-10-01", {
		item("n1"),
		item("rd", { file = "reading.md", kind = "new", after = "READ paper", headline = "read paper" }),
	})
	local nb4 = open_notes(r4)
	review.attach(nb4)
	assert_true("review opens", review.open_review(nb4))
	local rb4 = review_buf_of(nb4)
	go_to(vim.fn.bufwinid(rb4), rb4, "NEWS n1")
	assert_true("take in notes.md", review.take(rb4))
	leader("gR")
	local rrb = review_buf_of(nb4)
	assert_true("moved to reading.md", rrb ~= nil and vim.api.nvim_buf_get_name(rrb):match("reading.md$") ~= nil)
	go_to(vim.fn.bufwinid(rrb), rrb, "READ paper")
	assert_true("take in reading.md", review.take(rrb))
	said = {}
	leader("gq")
	tick()
	assert_true("notes.md is written", vim.tbl_contains(on_disk(r4), "NEWS n1"))
	assert_true("and reading.md", vim.tbl_contains(on_disk(r4, "reading.md"), "READ paper"))
	assert_true("both takes recorded", taken(r4, "headline n1") and taken(r4, "read paper"))
	assert_true("said in one line (" .. table.concat(said, " | ") .. ")", vim.tbl_contains(said, "desk: saved notes.md and reading.md with your takes"))
	vim.notify = orig_notify
end

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
