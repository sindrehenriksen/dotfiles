-- D6 test: review keys, mode, virtual text, overview, jumplist, and the
-- <leader>ga visual-range fix — headless, against from-scratch fixtures in
-- throwaway git repos, never his real notes.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-review-test.lua
local review = require("desk.review")
local ledger = require("desk.ledger")
local apply = require("desk.apply")
local round = require("desk.round")
local git = require("desk.git")
local snippet = require("desk.snippet")
local git_safety_here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local git_safety = dofile(git_safety_here .. "/../../tests/lib/git-safety.lua")

-- Sandboxed: desk.review.commit_his_text (called by nearly every test here,
-- directly or via desk.review.review) now writes the pending-set snapshot
-- (desk.ledger.write_pending_snapshot) on every run, which resolves under
-- $DESK_STATE_DIR (real default ~/.local/state/desk) — never the real one
-- from a test run.
vim.env.DESK_STATE_DIR = vim.fn.tempname()

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

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

local function new_repo(lines)
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	git_safety.assert_repo_under_tmp(repo)
	assert(git.run(repo, { "init", "-q" }))
	assert(git.run(repo, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(repo, { "config", "user.name", "Desk Test" }))
	local fd = assert(io.open(repo .. "/notes.md", "w"))
	fd:write(snippet.join_lines(lines, true))
	fd:close()
	local mfd = assert(io.open(repo .. "/" .. review.MARKER, "w"))
	mfd:write("")
	mfd:close()
	assert(git.run(repo, { "add", "notes.md", review.MARKER }))
	assert(git.run(repo, { "commit", "-q", "-m", "initial" }))
	return repo
end

--- Writes `items` (proposal shape) as the tip of refs/desk/proposal, and an
--- `item` ledger record for each — what the (unbuilt) runner would have
--- done before he ever presses the review key.
local function seed_proposal(repo, items)
	for _, it in ipairs(items) do
		ledger.append(repo, {
			type = "item",
			id = it.id,
			file = it.file,
			kind = it.kind,
			anchor = it.target,
			before = it.before,
			after = it.after,
			source = it.source or "test",
			headline = it.headline or it.id,
			pass = "morning",
			proposed_at = it.proposed_at or os.time(),
		})
	end
	local blob = assert(git.hash_object_write(repo, vim.json.encode({ items = items })))
	local ok_mktree, tree_out =
		git.run(repo, { "mktree" }, string.format("100644 blob %s\tproposal.json\n", blob))
	assert(ok_mktree, tree_out)
	local tree_sha = vim.trim(tree_out)
	local parent = git.ref_sha(repo, review.PROPOSAL_REF)
	local args = { "commit-tree", tree_sha, "-m", "proposal" }
	if parent then
		table.insert(args, "-p")
		table.insert(args, parent)
	end
	local ok_commit, commit_out = git.run(repo, args)
	assert(ok_commit, commit_out)
	local commit_sha = vim.trim(commit_out)
	assert(git.update_ref_cas(repo, review.PROPOSAL_REF, commit_sha, parent))
end

local function open_notes(repo)
	vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/notes.md"))
	return vim.api.nvim_get_current_buf()
end

--- Lays `items` into `bufnr` by hand — like desk.review.review() itself,
--- but without the surrounding commit-his-text/proposal-read machinery —
--- for a test that wants precise, deterministic control over exactly what
--- is "already laid in" before it starts poking at accept/decline/not-now.
--- Writes the buffer, a "laid_in" ledger record, and (what a hand-rolled
--- desk.apply.apply_file call used to skip, before desk.round existed) the
--- "round" record every read now derives state from — desk.round.build
--- with the very ranges desk.apply.apply_file itself returns, so this is
--- never a second, drifting implementation of what review() does.
local function lay_in_by_hand(repo, bufnr, base_lines, items)
	local new_lines, results, _, ranges = apply.apply_file(base_lines, items)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	vim.cmd("noautocmd write")
	local laid_in_ids = {}
	for _, item in ipairs(items) do
		if results[item.id] == "applied" then
			table.insert(laid_in_ids, item.id)
		end
	end
	ledger.append(repo, round.build("notes.md", new_lines, items, ranges))
	ledger.append(repo, { type = "laid_in", at = os.time(), proposal = "seed", items = laid_in_ids })
	return new_lines
end

local function git_log_count(repo)
	local ok_log, out = git.run(repo, { "rev-list", "--count", "HEAD" })
	return ok_log and tonumber(vim.trim(out)) or 0
end

print("=== D6: the review key lays in a proposal ===")
do
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{
			id = "p1",
			file = "notes.md",
			kind = "add",
			target = { under = "Section A" },
			before = "",
			after = "  suggested line",
			source = "test",
			headline = "a suggestion",
		},
	})
	local bufnr = open_notes(repo)
	local before_log = git_log_count(repo)

	local review_ok, result = review.review(bufnr)
	assert_true("review() succeeds", review_ok)
	assert_eq("one item laid in", 1, result and result.laid_in)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_eq("the suggestion landed under Section A", "  suggested line", lines[3])

	local records = ledger.read(repo)
	local laid_in_rec
	for _, r in ipairs(records) do
		if r.type == "laid_in" then
			laid_in_rec = r
		end
	end
	assert_true("a laid_in record was written", laid_in_rec ~= nil)
	assert_eq("it names p1", { "p1" }, laid_in_rec and laid_in_rec.items)
	assert_true("review mode is on for this buffer", vim.b[bufnr].desk_review_mode)
	assert_true("his commit key ran (HEAD unchanged or advanced, never behind)", git_log_count(repo) >= before_log)
end

print()
print("=== D6: accept/decline/not-now act on the whole item, untouched neighbor ===")
do
	local base = { "Alpha", "  original", "Beta", "  keep me", "Gamma", "  other" }
	local repo = new_repo(base)

	local move_item = {
		id = "mv1",
		file = "notes.md",
		kind = "move",
		target = { { at = "  original" }, { under = "Beta" } },
		before = "  original",
		after = "  original (moved)",
	}
	-- A distinct anchor from the move's landing spot ("under Beta") — two
	-- items sharing one anchor is its own (real, but separate) edge case,
	-- not what this scenario is testing.
	local add_item = {
		id = "add1",
		file = "notes.md",
		kind = "add",
		target = { under = "Gamma" },
		before = "",
		after = "  a pending add",
	}
	seed_proposal(repo, { move_item, add_item })
	local bufnr = open_notes(repo)
	lay_in_by_hand(repo, bufnr, base, { move_item, add_item })

	-- His own edit, unrelated to either suggestion.
	local edited = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i, l in ipairs(edited) do
		if l == "  keep me" then
			edited[i] = "  keep me, edited by him"
		end
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, edited)
	vim.cmd("noautocmd write")

	-- Accept the move: find either of its two lines and press accept there.
	local move_line
	for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
		if l == "  original (moved)" then
			move_line = i
		end
	end
	assert_true("found the move's landed line", move_line ~= nil)
	local accept_ok, accept_err = review.accept(bufnr, move_line)
	assert_true("accept succeeds on the move (" .. tostring(accept_err) .. ")", accept_ok)

	local idx_lines = snippet.split_lines(git.index_content(repo, "notes.md") or "")
	assert_eq(
		"accepting the move stages BOTH its hunks (leaving side gone, landing side present)",
		true,
		(not vim.tbl_contains(idx_lines, "  original")) and vim.tbl_contains(idx_lines, "  original (moved)")
	)
	local buf_after_accept = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_true(
		"his unrelated edit is still there after accepting the move",
		vim.tbl_contains(buf_after_accept, "  keep me, edited by him")
	)

	-- Decline the add: find its line and press decline.
	local add_line
	for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
		if l == "  a pending add" then
			add_line = i
		end
	end
	assert_true("found the pending add's line", add_line ~= nil)
	local decline_ok, decline_err = review.decline(bufnr, add_line)
	assert_true("decline succeeds (" .. tostring(decline_err) .. ")", decline_ok)
	local buf_after_decline = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_true("the declined add is gone from the buffer", not vim.tbl_contains(buf_after_decline, "  a pending add"))
	assert_true(
		"his unrelated edit survived the decline too",
		vim.tbl_contains(buf_after_decline, "  keep me, edited by him")
	)

	local records = ledger.read(repo)
	local mv_key, add_key
	for _, r in ipairs(records) do
		if r.type == "key" and r.id == "mv1" then
			mv_key = r
		end
		if r.type == "key" and r.id == "add1" then
			add_key = r
		end
	end
	assert_eq("the move's key record is accept", "accept", mv_key and mv_key.action)
	assert_eq("the add's key record is decline", "decline", add_key and add_key.action)
end

print()
print("=== D6: not-now postpones rather than declines ===")
do
	local base = { "Alpha", "  line" }
	local repo = new_repo(base)
	local item = { id = "nn1", file = "notes.md", kind = "add", target = { under = "Alpha" }, before = "", after = "  suggestion" }
	seed_proposal(repo, { item })
	local bufnr = open_notes(repo)
	local laid = lay_in_by_hand(repo, bufnr, base, { item })

	local target_line
	for i, l in ipairs(laid) do
		if l == "  suggestion" then
			target_line = i
		end
	end
	local nn_ok = review.not_now(bufnr, target_line)
	assert_true("not_now succeeds", nn_ok)

	local idx = snippet.split_lines(git.index_content(repo, "notes.md") or "")
	local wt = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local states = ledger.derive_all(repo, "notes.md", idx, wt)
	assert_eq("the item is postponed, not declined", "postponed", states["nn1"])
end

print()
print("=== D6: overview ordering (news, then in-place by position, then deferred count) ===")
do
	local base = { "Alpha", "  a", "Beta", "  b", "Gamma", "  c" }
	local repo = new_repo(base)
	local news_item = { id = "news1", file = "notes.md", kind = "new", target = "top", before = "", after = "NEWS", headline = "a news item" }
	local late_item = { id = "late1", file = "notes.md", kind = "add", target = { under = "Gamma" }, before = "", after = "  late add", headline = "late in-place" }
	local early_item = { id = "early1", file = "notes.md", kind = "add", target = { under = "Alpha" }, before = "", after = "  early add", headline = "early in-place" }
	local postponed_item = { id = "post1", file = "notes.md", kind = "add", target = { under = "Beta" }, before = "", after = "  postponed add", headline = "postponed one" }
	seed_proposal(repo, { news_item, late_item, early_item, postponed_item })
	local bufnr = open_notes(repo)
	lay_in_by_hand(repo, bufnr, base, { news_item, late_item, early_item, postponed_item })

	-- Postpone one of the four before building the overview.
	local post_line
	for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
		if l == "  postponed add" then
			post_line = i
		end
	end
	assert(review.not_now(bufnr, post_line))
	local wt_after_postpone = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	-- not_now already wrote the reset lines to the buffer; refresh the open
	-- window's view of it for the overview build below.
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, wt_after_postpone)

	review.overview(bufnr)
	local qf = vim.fn.getqflist({ title = 0, items = 0 })
	assert_eq("overview title is set", review.OVERVIEW_TITLE, qf.title)
	local texts = {}
	for _, it in ipairs(qf.items) do
		table.insert(texts, it.text)
	end
	assert_eq(
		"news first, then in-place ordered by position, then the deferred count",
		{ "a news item", "early in-place", "late in-place", "1 deferred" },
		texts
	)
end

print()
print("=== D6: overview jump goes through the jumplist, even from its own split ===")
do
	local base = { "Alpha", "  a", "Beta", "  b" }
	local repo = new_repo(base)
	local item1 = { id = "j1", file = "notes.md", kind = "add", target = { under = "Alpha" }, before = "", after = "  jump target one", headline = "one" }
	local item2 = { id = "j2", file = "notes.md", kind = "add", target = { under = "Beta" }, before = "", after = "  jump target two", headline = "two" }
	seed_proposal(repo, { item1, item2 })

	vim.cmd("tabnew")
	local notes_buf = open_notes(repo)
	lay_in_by_hand(repo, notes_buf, base, { item1, item2 })
	local notes_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_cursor(notes_win, { 1, 0 }) -- a known starting position

	review.overview(notes_buf) -- opens the qf list in its own split (:copen)
	local qf_win
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "qf" then
			qf_win = w
		end
	end
	assert_true("the overview opened in its own window", qf_win ~= nil and qf_win ~= notes_win)

	vim.api.nvim_set_current_win(qf_win)
	local qf_items = vim.fn.getqflist()
	local jump_idx
	for i, it in ipairs(qf_items) do
		if it.text == "two" then
			jump_idx = i
		end
	end
	vim.api.nvim_win_set_cursor(qf_win, { jump_idx, 0 })
	review.qf_jump()

	assert_eq("after the jump, focus is back in the notes window", notes_win, vim.api.nvim_get_current_win())
	local cur = vim.api.nvim_win_get_cursor(notes_win)
	local jumped_line = vim.api.nvim_buf_get_lines(notes_buf, cur[1] - 1, cur[1], false)[1]
	assert_eq("the cursor landed on item two's line", "  jump target two", jumped_line)

	-- Ctrl-O in the notes window returns to where he was (line 1) — this
	-- only holds if the jump set the ' mark in *that* window, not the qf one.
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "x", false)
	local after_ctrl_o = vim.api.nvim_win_get_cursor(notes_win)
	assert_eq("Ctrl-O returns to the pre-jump line", 1, after_ctrl_o[1])

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-i>", true, false, true), "x", false)
	local after_ctrl_i = vim.api.nvim_win_get_cursor(notes_win)
	assert_eq("Ctrl-I goes forward again, back to item two's line", jump_idx and cur[1], after_ctrl_i[1])

	vim.cmd("tabclose!")
end

print()
print("=== D6 fix: the quickfix <CR> override never touches a location list ===")
do
	vim.cmd("tabnew")
	local repo = new_repo({ "GLOBAL TARGET", "LOCAL TARGET" })
	local bufnr = open_notes(repo)
	local win = vim.api.nvim_get_current_win()

	-- The bug: getqflist() always reads the *global* quickfix list, so a
	-- location list whose title happens to collide with desk's own
	-- overview title would have its <CR> misread the global list's own
	-- entries instead of its own.
	vim.fn.setqflist({}, " ", { title = review.OVERVIEW_TITLE, items = { { bufnr = bufnr, lnum = 1, col = 1 } } })
	vim.fn.setloclist(win, {}, " ", { title = review.OVERVIEW_TITLE, items = { { bufnr = bufnr, lnum = 2, col = 1 } } })
	vim.cmd("lopen")
	local loc_win = vim.api.nvim_get_current_win()
	assert_true(
		"this really is a location list window, not a quickfix one",
		vim.fn.getloclist(loc_win, { filewinid = 0 }).filewinid ~= 0
	)
	vim.api.nvim_win_set_cursor(loc_win, { 1, 0 })

	review.qf_jump()

	local notes_win
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(w) == bufnr then
			notes_win = w
		end
	end
	assert_true("a window is showing the notes buffer", notes_win ~= nil)
	assert_eq(
		"landed on the location list's own line, never the (title-colliding) global list's",
		2,
		notes_win and vim.api.nvim_win_get_cursor(notes_win)[1]
	)

	vim.fn.setqflist({}, "r", { title = "", items = {} })
	vim.cmd("tabclose!")
end

print()
print("=== D6 fix: a removal at the file's very last lines stays reachable ===")
do
	local base = { "Alpha", "  keep", "  tail line to remove" }
	local repo = new_repo(base)
	local item = {
		id = "rm-eof",
		file = "notes.md",
		kind = "remove",
		target = { at = "  tail line to remove" },
		before = "  tail line to remove",
		after = "",
		headline = "drop the tail",
	}
	seed_proposal(repo, { item })
	local bufnr = open_notes(repo)
	lay_in_by_hand(repo, bufnr, base, { item })

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_eq("the removal is already applied in the buffer (pending)", { "Alpha", "  keep" }, lines)
	local last_line = #lines

	local found_item = review.item_at_line(bufnr, last_line)
	assert_true("the item is reachable with the cursor on the file's actual last line", found_item ~= nil)
	assert_eq("...and it's the right one", "rm-eof", found_item and found_item.id)

	review.overview(bufnr)
	local qf = vim.fn.getqflist()
	local qf_entry
	for _, it in ipairs(qf) do
		if it.text == "drop the tail" then
			qf_entry = it
		end
	end
	assert_true("the overview lists it", qf_entry ~= nil)
	assert_eq("...at a valid (clamped) line, not one past the last line", last_line, qf_entry and qf_entry.lnum)
	vim.cmd("cclose")

	review.refresh_virtual_text(bufnr)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, review.ns, 0, -1, {})
	local mark_row = marks[1] and marks[1][2]
	assert_eq("its virtual text is attached to the actual last line, not a phantom one past it", last_line - 1, mark_row)

	local not_now_ok, not_now_err = review.not_now(bufnr, last_line)
	assert_true("not_now succeeds from the clamped, reachable line (" .. tostring(not_now_err) .. ")", not_now_ok)
	local restored = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_eq("the removed tail is correctly re-inserted AFTER the last line, not before it", base, restored)
end

print()
print("=== D6: format-on-save leaves the notes buffer untouched ===")
do
	package.path = package.path -- (no-op; real autocmds.lua uses relative require paths already on rtp)
	require("autocmds")
	local repo = new_repo({ "Alpha", "  line" })
	local bufnr = open_notes(repo)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	table.insert(lines, "  trailing space here   ")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.cmd("write")
	local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_eq(
		"trailing whitespace in notes.md survives a plain :w (the cleanup autocmd's pattern excludes *.md)",
		"  trailing space here   ",
		after[#after]
	)
end

print()
print("=== D6: <leader>ga in visual mode stages the selection, not the whole hunk ===")
do
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	git_safety.assert_repo_under_tmp(repo)
	assert(git.run(repo, { "init", "-q" }))
	assert(git.run(repo, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(repo, { "config", "user.name", "Desk Test" }))
	local base = {}
	for i = 1, 12 do
		base[i] = "line " .. i
	end
	local fd = assert(io.open(repo .. "/file.txt", "w"))
	fd:write(snippet.join_lines(base, true))
	fd:close()
	assert(git.run(repo, { "add", "file.txt" }))
	assert(git.run(repo, { "commit", "-q", "-m", "initial" }))

	vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/file.txt"))
	local bufnr = vim.api.nvim_get_current_buf()

	-- One THREE-line hunk (lines 2-4, all edited together) and one
	-- independent single-line edit far enough away to be its own hunk. The
	-- three-line hunk is the point: staging "the hunk under the cursor"
	-- (the bug) and staging only the selected lines (the fix) produce
	-- different results only when the selection is a genuine subset of a
	-- multi-line hunk — a single-line hunk can't tell them apart.
	vim.api.nvim_buf_set_lines(bufnr, 1, 4, false, { "line 2 EDITED", "line 3 EDITED", "line 4 EDITED" })
	vim.api.nvim_buf_set_lines(bufnr, 9, 10, false, { "line 10 EDITED" }) -- line 10
	vim.cmd("write")

	local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
	local git_spec = dofile(here .. "/../lua/plugins/git.lua")
	local on_attach = git_spec[1].opts.on_attach
	local gitsigns = require("gitsigns")
	gitsigns.setup({})
	-- Attach synchronously for the test: gitsigns normally attaches via its
	-- own BufRead autocmd (asynchronously); force it and wait for the hunks
	-- to be computed before selecting a range against them.
	gitsigns.attach(bufnr)
	vim.wait(500, function()
		local hunks = gitsigns.get_hunks(bufnr)
		return hunks ~= nil and #hunks == 2
	end)
	on_attach(bufnr)

	-- Visual-select only the MIDDLE line of the 3-line hunk (line 3), then
	-- press <leader>ga: a range-aware stage takes only line 3; the buggy
	-- cursor-hunk fallback would take all of lines 2-4.
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("normal! V")
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(" ga", true, false, true), "x", false)
	vim.wait(200)

	local idx_lines = snippet.split_lines(git.index_content(repo, "file.txt") or "")
	assert_true("the selected line (3) was staged", idx_lines[3] == "line 3 EDITED")
	assert_true("its neighbor in the SAME hunk (line 2) was NOT staged", idx_lines[2] == "line 2")
	assert_true("its other neighbor in the SAME hunk (line 4) was NOT staged", idx_lines[4] == "line 4")
	assert_true("the unrelated hunk (line 10) was NOT staged", idx_lines[10] == "line 10")
end

print()
print("=== D6 fix: pressing review again never re-lays an already-resolved item ===")
do
	local repo = new_repo({ "Section A", "  detail", "Section B", "  other" })
	seed_proposal(repo, {
		{
			id = "acc1",
			file = "notes.md",
			kind = "add",
			target = { under = "Section A" },
			before = "",
			after = "  will be accepted",
			headline = "accept me",
		},
		{
			id = "dec1",
			file = "notes.md",
			kind = "add",
			target = { under = "Section B" },
			before = "",
			after = "  will be declined",
			headline = "decline me",
		},
	})
	local bufnr = open_notes(repo)

	local ok1, result1 = review.review(bufnr)
	assert_true("first review() succeeds", ok1)
	assert_eq("both items laid in on the first press", 2, result1 and result1.laid_in)

	local function line_of(text)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			if l == text then
				return i
			end
		end
	end

	assert(review.accept(bufnr, line_of("  will be accepted")))
	assert(review.decline(bufnr, line_of("  will be declined")))

	local ok2, result2 = review.review(bufnr)
	assert_true("second review() succeeds", ok2)
	assert_eq("nothing new to lay in the second time", 0, result2 and result2.laid_in)

	local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local accepted_count, declined_count = 0, 0
	for _, l in ipairs(lines_after) do
		if l == "  will be accepted" then
			accepted_count = accepted_count + 1
		elseif l == "  will be declined" then
			declined_count = declined_count + 1
		end
	end
	assert_eq("the accepted item appears exactly once (never duplicated)", 1, accepted_count)
	assert_eq("the declined item never comes back", 0, declined_count)
end

print()
print("=== D6 fix: a postponed item is laid in again on its postponed state alone ===")
do
	-- design.md's "Review rounds" section: no `postponed_from` marker to
	-- gate on any more — whether the runner re-proposed it because of a
	-- newer pass is the runner's own call (git-ops.sh's supersede rule);
	-- from review()'s own side, any item the current proposal still names
	-- and the ledger derives as "postponed" is laid in again, full stop.
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{
			id = "pp1",
			file = "notes.md",
			kind = "add",
			target = { under = "Section A" },
			before = "",
			after = "  postpone me",
			headline = "postpone me",
		},
	})
	local bufnr = open_notes(repo)
	assert(review.review(bufnr))

	local function line_of(text)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			if l == text then
				return i
			end
		end
	end
	local not_now_at = os.time()
	assert(review.not_now(bufnr, line_of("  postpone me")))

	-- Re-pressing review right away, against the SAME still-standing
	-- proposal (nothing new from the runner), lays it in again.
	local ok_same, result_same = review.review(bufnr)
	assert_true("review() succeeds against the unchanged proposal", ok_same)
	assert_eq("the postponed item is laid in again", 1, result_same and result_same.laid_in)
	assert_true("its content is back in the buffer", line_of("  postpone me") ~= nil)

	local st = review.read_state(bufnr)
	review.refresh_virtual_text(bufnr)
	local marks = vim.api.nvim_buf_get_extmarks(bufnr, review.ns, 0, -1, { details = true })
	local found_postponed_text
	for _, m in ipairs(marks) do
		local text = m[4].virt_text[1][1]
		if text:find("postponed from ", 1, true) then
			found_postponed_text = text
		end
	end
	assert_true(
		"its virtual text says 'postponed from <day>', read from the not_now key's own time (never a stored field)",
		found_postponed_text ~= nil
	)
	assert_eq(
		"that day matches the not_now key's own recorded time",
		os.date("%A", not_now_at),
		found_postponed_text and found_postponed_text:match("postponed from (%a+)")
	)
	assert_true("desk.round tracked it (not derived from any 'postponed_from' field)", st ~= nil)
end

print()
print("=== D6 fix: a bad anchor lands on top and is interactable, not deferred forever ===")
do
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{
			id = "bad1",
			file = "notes.md",
			kind = "add",
			target = { under = "a heading that doesn't exist" },
			before = "",
			after = "  orphaned suggestion",
			headline = "orphaned",
		},
	})
	local bufnr = open_notes(repo)
	local review_ok, result = review.review(bufnr)
	assert_true("review() succeeds", review_ok)
	assert_eq("the bad-anchor item is applied, not deferred", 1, result and result.laid_in)
	assert_eq("...and reported as landed on top", 1, result and result.landed_on_top)
	assert_eq("...and never as deferred", 0, result and result.deferred)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_eq("its content is at the top of the file", "  orphaned suggestion", lines[1])

	-- It has to be interactable, not just visible: accept must find it.
	local accept_ok = review.accept(bufnr, 1)
	assert_true("accept finds it at the top (ledger.derive_all agrees on the position)", accept_ok)
	local idx_lines = snippet.split_lines(git.index_content(repo, "notes.md") or "")
	assert_true("accepting it staged its content into the index", vim.tbl_contains(idx_lines, "  orphaned suggestion"))
end

print()
print("=== D6 fix: nomodeline is set buffer-local on a notes buffer (the .desk-notes marker) ===")
do
	require("desk").setup()
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	local mfd = assert(io.open(repo .. "/" .. review.MARKER, "w"))
	mfd:write("")
	mfd:close()
	local fd = assert(io.open(repo .. "/notes.md", "w"))
	fd:write("Alpha\n  line\n\nvim: set tabstop=7 :\n")
	fd:close()

	vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/notes.md"))
	local bufnr = vim.api.nvim_get_current_buf()

	assert_true("modeline is off for the notes buffer", not vim.bo[bufnr].modeline)
	assert_true("the fixture's modeline was never applied (tabstop stayed default)", vim.bo[bufnr].tabstop ~= 7)
end

print()
print("=== D8 fix: commit_his_text writes the pending-set snapshot ===")
do
	local repo = new_repo({ "Alpha" })
	local item = {
		id = "snap1",
		file = "notes.md",
		kind = "add",
		target = { under = "Alpha" },
		before = "",
		after = "  a pending suggestion",
		headline = "a pending suggestion",
	}
	seed_proposal(repo, { item })
	local bufnr = open_notes(repo)
	assert_true("review() succeeds", review.review(bufnr))

	-- A later his-text run (a fresh <leader>gc press, or the next day's)
	-- snapshots whatever's pending right now.
	assert_true("commit_his_text succeeds", review.commit_his_text(bufnr))

	-- git canonicalizes the repo path (symlinks and all — macOS's
	-- /var -> /private/var), so the snapshot path has to be built from the
	-- same resolved root commit_his_text used internally, not the raw
	-- fixture path, or the two would never agree on a file.
	local canon_repo = review.repo_context(bufnr)
	local snap_path = ledger.pending_snapshot_path(canon_repo, "notes.md")
	local snap = ledger.read_pending_snapshot(snap_path)
	assert_true("a snapshot was written", snap ~= nil)
	assert_eq("it names the still-pending item", { "snap1" }, snap and snap.items)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local accept_line
	for i, l in ipairs(lines) do
		if l == "  a pending suggestion" then
			accept_line = i
		end
	end
	assert_true("accept succeeds", review.accept(bufnr, accept_line))
	assert_true("commit_his_text succeeds again", review.commit_his_text(bufnr))

	local snap2 = ledger.read_pending_snapshot(snap_path)
	assert_eq("once accepted, the next snapshot no longer names it", {}, snap2 and snap2.items)
end

print()
print("=== D8 fix: declined recently -- list, then restore ===")
do
	local repo = new_repo({ "Alpha" })
	local item = {
		id = "dr1",
		file = "notes.md",
		kind = "add",
		target = { under = "Alpha" },
		before = "",
		after = "  a declined suggestion",
		headline = "a declined suggestion",
	}
	seed_proposal(repo, { item })
	local bufnr = open_notes(repo)
	assert_true("review() succeeds", review.review(bufnr))

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local decline_line
	for i, l in ipairs(lines) do
		if l == "  a declined suggestion" then
			decline_line = i
		end
	end
	assert_true("decline succeeds", review.decline(bufnr, decline_line))
	local after_decline = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_true("the declined line is gone from the buffer", not vim.tbl_contains(after_decline, "  a declined suggestion"))

	review.list_declined_recently(bufnr)
	local qf = vim.fn.getqflist({ title = 0, items = 0, context = 0 })
	assert_eq("the declined-recently title is set", review.DECLINED_TITLE, qf.title)
	assert_eq("one declined-recently item is listed", 1, #qf.items)
	assert_true("it's labelled declined", qf.items[1].text:find("declined", 1, true) ~= nil)

	-- list_declined_recently opened the qf list via :copen, which switched
	-- focus into it — the cursor starts on line 1, its only entry.
	review.qf_restore()

	local restored_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_true("the restored line is back in the buffer", vim.tbl_contains(restored_lines, "  a declined suggestion"))

	local records = ledger.read(repo)
	local restore_key
	for _, r in ipairs(records) do
		if r.type == "key" and r.id == "dr1" and r.action == "restore" then
			restore_key = r
		end
	end
	assert_true("a restore key record was written", restore_key ~= nil)

	local head = review.head_lines(repo, "notes.md")
	local index_lines = snippet.split_lines(git.index_content(repo, "notes.md") or "")
	local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local states = ledger.derive_all(repo, head, index_lines, worktree_lines)
	assert_eq("the item derives as pending again", "pending", states["dr1"])
end

print()
print("=== D8 fix: <leader>gd and :DeskDeclined are wired by attach ===")
do
	local repo = new_repo({ "Alpha" })
	local bufnr = open_notes(repo)
	review.attach(bufnr)

	local found_keymap
	for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
		if m.desc and m.desc:find("Declined recently", 1, true) then
			found_keymap = m
		end
	end
	assert_true("a buffer-local normal-mode keymap for declined-recently exists", found_keymap ~= nil)

	local commands = vim.api.nvim_buf_get_commands(bufnr, {})
	assert_true("the :DeskDeclined buffer command exists", commands.DeskDeclined ~= nil)

	-- Invoking either one opens the (empty) declined-recently list without
	-- erroring.
	vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("DeskDeclined")
	end)
	local qf2 = vim.fn.getqflist({ title = 0 })
	assert_eq("the declined-recently title is set", review.DECLINED_TITLE, qf2.title)
	vim.cmd("cclose")
end

print()
print("=== D6 round fix: his own line added above a pending item, then a commit ===")
do
	-- The bug design.md names: his own line-count change above a pending
	-- item used to shift its anchor's resolved position without moving the
	-- item, misreading the result as "declined" — and the next commit then
	-- kept his stray edit instead of reverting the still-pending item.
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{ id = "p1", file = "notes.md", kind = "add", target = { under = "Section A" }, before = "", after = "  a suggestion" },
	})
	local bufnr = open_notes(repo)
	assert(review.review(bufnr))

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	table.insert(lines, 1, "his own new line, added above everything")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.cmd("noautocmd write")

	local states = review.read_state(bufnr).states
	assert_eq("still pending — his own edit above it never shifts it out of place", "pending", states["p1"])

	assert(review.commit_his_text(bufnr))
	local head_lines = review.head_lines(repo, "notes.md")
	assert_true("his new line is committed", vim.tbl_contains(head_lines, "his own new line, added above everything"))
	assert_true("the still-pending suggestion is reverted out of HEAD, not baked in", not vim.tbl_contains(head_lines, "  a suggestion"))
end

print()
print("=== D6 round fix: accepting a news item, then committing with others still pending ===")
do
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{ id = "news1", file = "notes.md", kind = "new", target = "top", before = "", after = "NEWS ITEM", headline = "news" },
		{ id = "add1", file = "notes.md", kind = "add", target = { under = "Section A" }, before = "", after = "  a pending add", headline = "add" },
	})
	local bufnr = open_notes(repo)
	assert(review.review(bufnr))

	local function line_of(text)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			if l == text then
				return i
			end
		end
	end
	assert(review.accept(bufnr, line_of("NEWS ITEM")))
	assert(review.commit_his_text(bufnr))

	local head_lines = review.head_lines(repo, "notes.md")
	assert_true("the accepted news item is committed", vim.tbl_contains(head_lines, "NEWS ITEM"))
	assert_true("the still-pending add is reverted, not swept in with it", not vim.tbl_contains(head_lines, "  a pending add"))

	local records = ledger.read(repo)
	local resolved
	for _, r in ipairs(records) do
		if r.type == "resolved" and r.id == "news1" then
			resolved = r
		end
	end
	assert_true("the commit froze the accepted item's state", resolved ~= nil)
	assert_eq("frozen as accepted", "accepted", resolved and resolved.state)
end

print()
print("=== D6 round fix: an accepted item still reads accepted after HEAD moves further ===")
do
	-- design.md: "each commit freezes resolved items ... so they are never
	-- re-derived against a moved HEAD." Once frozen, further commits (his
	-- own continued editing) must never flip it back.
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{ id = "acc1", file = "notes.md", kind = "add", target = { under = "Section A" }, before = "", after = "  will be accepted", headline = "acc" },
	})
	local bufnr = open_notes(repo)
	assert(review.review(bufnr))
	local function line_of(text)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			if l == text then
				return i
			end
		end
	end
	assert(review.accept(bufnr, line_of("  will be accepted")))
	assert(review.commit_his_text(bufnr))
	assert_eq("accepted right after the freezing commit", "accepted", review.read_state(bufnr).states["acc1"])

	-- HEAD moves further: several of his own unrelated edits, each its own
	-- commit, right around the accepted item's own text.
	for i = 1, 3 do
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		table.insert(lines, 1, "unrelated edit " .. i)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.cmd("noautocmd write")
		assert(review.commit_his_text(bufnr))
	end

	assert_eq(
		"still accepted after HEAD moved three commits further — frozen, never re-derived",
		"accepted",
		review.read_state(bufnr).states["acc1"]
	)
end

print()
print("=== D6 round fix: a restart (a fresh nvim -l process) then pressing review again ===")
do
	-- Nothing this relies on may live only in this process's own Lua
	-- state — a restart is exactly a second `nvim -l` process reading the
	-- same repo. Simulated here by dropping every desk.* module from
	-- package.loaded and re-require'ing them (a fresh interpreter would
	-- start with an empty cache the same way), then working the SAME repo
	-- through freshly-required modules end to end.
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{ id = "pp1", file = "notes.md", kind = "add", target = { under = "Section A" }, before = "", after = "  postpone me", headline = "pp" },
	})
	local bufnr = open_notes(repo)
	assert(review.review(bufnr))
	local function line_of(bn, text)
		for i, l in ipairs(vim.api.nvim_buf_get_lines(bn, 0, -1, false)) do
			if l == text then
				return i
			end
		end
	end
	assert(review.not_now(bufnr, line_of(bufnr, "  postpone me")))

	for name in pairs(package.loaded) do
		if name:match("^desk%.") then
			package.loaded[name] = nil
		end
	end
	local fresh_review = require("desk.review")
	assert(fresh_review ~= review, "a genuinely fresh module table, not the cached one")

	vim.cmd("bwipeout! " .. bufnr)
	local bufnr2 = fresh_review.repo_context and open_notes(repo) or open_notes(repo)
	local ok2, result2 = fresh_review.review(bufnr2)
	assert_true("review() succeeds against a freshly-required module set", ok2)
	assert_eq("the postponed item is laid in again, read entirely from the repo", 1, result2 and result2.laid_in)
	assert_true("its content is back", line_of(bufnr2, "  postpone me") ~= nil)
end

print()
print("=== D6 round fix: two passes land in the proposal before any review press ===")
do
	local repo = new_repo({ "Section A", "  detail" })
	seed_proposal(repo, {
		{ id = "j1", file = "notes.md", kind = "add", target = { under = "Section A" }, before = "", after = "  from the first pass", headline = "j1" },
	})
	-- A second pass's own write (the runner's own merge already carries the
	-- first pass's item forward — desk_stage_and_write_proposal — so the
	-- SECOND proposal blob names both, same as a real second pass would).
	seed_proposal(repo, {
		{ id = "j1", file = "notes.md", kind = "add", target = { under = "Section A" }, before = "", after = "  from the first pass", headline = "j1" },
		{ id = "c1", file = "notes.md", kind = "new", target = "top", before = "", after = "  from the second pass", headline = "c1" },
	})

	local bufnr = open_notes(repo)
	local ok, result = review.review(bufnr)
	assert_true("review() succeeds", ok)
	assert_eq("both passes' items are laid in together, in one round", 2, result and result.laid_in)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert_true("the first pass's item is there", vim.tbl_contains(lines, "  from the first pass"))
	assert_true("the second pass's item is there too", vim.tbl_contains(lines, "  from the second pass"))
end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
