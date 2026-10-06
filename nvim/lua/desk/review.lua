-- The stateless diff review. A pass leaves ONE proposal commit
-- (desk.proposal): his HEAD at pass time as its parent, the files with every
-- suggestion applied as its tree. Nothing in it ever enters his notes unless
-- he takes it, and nothing here tracks a suggestion by position.
--
-- Review key: merges his CURRENT buffer text (ours) with the proposal
-- (theirs) against the pass-time version (base) with `git merge-file`, his
-- text winning any conflict, and opens the result in a stacked split as an
-- `acwrite` scratch buffer, both windows in diff mode. He takes a hunk with
-- `do` in the notes window (editing first is fine) and leaves one alone to
-- mean "not now" (the next pass carries it). The decline key makes the hunk
-- under the cursor in the review split equal his text — an ordinary edit, so
-- plain `u` undoes it. Nothing is recorded until he SAVES the review split:
-- that is the commit point, recording every suggestion whose lines are gone
-- from the review buffer and not in his notes as declined. A discarded
-- review buffer records nothing. Adjacent suggestions are one diff hunk, so
-- the decline key (and `<leader>gA`, which takes one) act on a single
-- suggestion's own lines rather than the whole hunk.
local git = require("desk.git")
local ledger = require("desk.ledger")
local proposal = require("desk.proposal")
local snippet = require("desk.snippet")
local status = require("desk.status")
local tokens = require("desk.tokens")

local M = {}

M.PROPOSAL_REF = proposal.REF

-- ---------------------------------------------------------------------------
-- Repo/file context
-- ---------------------------------------------------------------------------

--- The notes repo root and the buffer's file name relative to it (assumed
--- to live at the repo root — notes.md / reading.md), or nil, why.
function M.repo_context(bufnr)
	local full = vim.api.nvim_buf_get_name(bufnr)
	if full == "" then
		return nil, "buffer has no file"
	end
	local dir = vim.fn.fnamemodify(full, ":p:h")
	local ok, out = git.run(dir, { "rev-parse", "--show-toplevel" })
	if not ok then
		return nil, "not in a git repo"
	end
	return vim.trim(out), vim.fn.fnamemodify(full, ":t")
end

local function buf_lines(buf)
	return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- ---------------------------------------------------------------------------
-- The merged view
-- ---------------------------------------------------------------------------

--- `git merge-file` of `ours` (his current text) with the proposal: base is
--- the proposal's parent version, theirs the proposal's version, his text
--- winning conflicts. Returns the merged lines, or nil, err.
function M.merged_lines(repo, p, file, ours_lines)
	local base = p.parent and proposal.lines_at(repo, p.parent, file) or {}
	local theirs = proposal.lines_at(repo, p.sha, file)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local function put(name, lines)
		local path = dir .. "/" .. name
		local fd = assert(io.open(path, "w"))
		fd:write(snippet.join_lines(lines, true))
		fd:close()
		return path
	end
	local ours_path, base_path, theirs_path = put("ours", ours_lines), put("base", base), put("theirs", theirs)
	local ok, out, err = git.run(repo, { "merge-file", "-p", "--ours", ours_path, base_path, theirs_path })
	vim.fn.delete(dir, "rf")
	if not ok then
		return nil, "git merge-file failed: " .. err
	end
	return (snippet.split_lines(out))
end

-- ---------------------------------------------------------------------------
-- Sessions (one review split per notes buffer)
-- ---------------------------------------------------------------------------

local sessions = {} -- notes bufnr -> session

local function session_for_review_buf(buf)
	for _, s in pairs(sessions) do
		if s.review_buf == buf then
			return s
		end
	end
end

--- The suggestions of `file` the merged view actually shows as hunks: not
--- deferred, not already taken or declined, proposed in the merged text but
--- not yet in his own.
local function shown_items(repo, p, file, ours, merged, base)
	local records = ledger.read(repo)
	local declined = ledger.declined(records)
	local taken = ledger.taken_by_id(records)
	local shown = {}
	for _, item in ipairs(p.items) do
		if
			item.file == file
			and not item.deferred
			and not taken[item.id]
			and not declined.ids[item.id]
			and proposal.proposed_in(item, merged, base)
			and not proposal.proposed_in(item, ours, base)
		then
			shown[item.id] = item
		end
	end
	return shown
end

local function first_hunk(win)
	vim.api.nvim_win_call(win, function()
		vim.cmd("diffupdate")
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		pcall(vim.cmd, "normal! ]c")
	end)
end

local function close_session(s)
	sessions[s.notes_buf] = nil
	if vim.api.nvim_buf_is_valid(s.review_buf) then
		pcall(vim.api.nvim_buf_delete, s.review_buf, { force = true })
	end
end

--- Records as declined every shown suggestion whose lines are gone from the
--- review buffer and not present in his notes — the review split's save.
function M.save_review(s)
	if not vim.api.nvim_buf_is_valid(s.review_buf) then
		return false, "review buffer is gone"
	end
	local review_lines = buf_lines(s.review_buf)
	local notes_lines
	if vim.api.nvim_buf_is_loaded(s.notes_buf) then
		notes_lines = buf_lines(s.notes_buf)
	else
		notes_lines = proposal.lines_at(s.repo, "HEAD", s.file)
	end
	local gone = {}
	for _, item in pairs(s.shown) do
		if not proposal.proposed_in(item, review_lines, s.base) and not proposal.proposed_in(item, notes_lines, s.base) then
			gone[#gone + 1] = item
		end
	end
	table.sort(gone, function(a, b)
		return a.id < b.id
	end)
	if not ledger.record_declines(s.repo, gone) then
		return false, "could not record the declines in the ledger"
	end
	vim.bo[s.review_buf].modified = false
	return true, #gone
end

--- The review key: opens the merged view in a stacked split (or focuses
--- the one already open for this proposal). Returns true, or false, why.
function M.open_review(notes_buf)
	local repo, file = M.repo_context(notes_buf)
	if not repo then
		return false, file
	end
	local p = proposal.read(repo)
	if not p then
		return false, "no proposal yet"
	end
	local existing = sessions[notes_buf]
	if existing and vim.api.nvim_buf_is_valid(existing.review_buf) then
		if existing.sha == p.sha then
			local win = vim.fn.bufwinid(existing.review_buf)
			if win ~= -1 then
				vim.api.nvim_set_current_win(win)
				return true
			end
		end
		close_session(existing)
	end

	local ours = buf_lines(notes_buf)
	local merged, err = M.merged_lines(repo, p, file, ours)
	if not merged then
		return false, err
	end
	local base = proposal.base_lines(repo, p, file)
	local shown = shown_items(repo, p, file, ours, merged, base)
	if next(shown) == nil then
		return false, "no suggestions to review"
	end

	local notes_win = vim.fn.bufwinid(notes_buf)
	if notes_win == -1 then
		notes_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(notes_win, notes_buf)
	end
	vim.api.nvim_set_current_win(notes_win)
	vim.cmd("belowright split")
	local review_win = vim.api.nvim_get_current_win()
	local review_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[review_buf].buftype = "acwrite"
	vim.bo[review_buf].bufhidden = "wipe"
	vim.bo[review_buf].swapfile = false
	vim.bo[review_buf].modeline = false
	vim.api.nvim_buf_set_name(review_buf, "desk-review://" .. file)
	vim.bo[review_buf].filetype = vim.bo[notes_buf].filetype
	vim.api.nvim_buf_set_lines(review_buf, 0, -1, false, merged)
	vim.bo[review_buf].modified = false
	vim.api.nvim_win_set_buf(review_win, review_buf)

	local s = {
		notes_buf = notes_buf,
		review_buf = review_buf,
		repo = repo,
		file = file,
		sha = p.sha,
		shown = shown,
		base = base,
	}
	sessions[notes_buf] = s

	vim.api.nvim_win_call(review_win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(notes_win, function()
		vim.cmd("diffthis")
	end)

	local group = vim.api.nvim_create_augroup("desk_review_" .. review_buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = review_buf,
		callback = function()
			local ok, n_or_err = M.save_review(s)
			if not ok then
				vim.notify("desk: " .. tostring(n_or_err), vim.log.levels.WARN)
			elseif n_or_err > 0 then
				vim.notify("desk: declined " .. n_or_err .. " suggestion(s)", vim.log.levels.INFO)
			end
			M.refresh_overview(s)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = review_buf,
		callback = function()
			if sessions[notes_buf] == s then
				sessions[notes_buf] = nil
			end
			local win = vim.fn.bufwinid(notes_buf)
			if win ~= -1 then
				vim.api.nvim_win_call(win, function()
					vim.cmd("diffoff")
				end)
			end
		end,
	})
	vim.keymap.set("n", "<leader>gD", function()
		local ok, why = M.decline(review_buf)
		if not ok then
			vim.notify("desk: " .. tostring(why), vim.log.levels.WARN)
		end
	end, { buffer = review_buf, desc = "Decline the suggestion under the cursor (u undoes; :w records)" })
	vim.keymap.set("n", "<leader>gA", function()
		local ok, why = M.take(review_buf)
		if not ok then
			vim.notify("desk: " .. tostring(why), vim.log.levels.WARN)
		end
	end, { buffer = review_buf, desc = "Take just the suggestion under the cursor" })
	vim.keymap.set("n", "<leader>go", function()
		M.overview(notes_buf)
	end, { buffer = review_buf, desc = "Overview: remaining suggestions" })

	vim.api.nvim_set_current_win(notes_win)
	first_hunk(notes_win)
	return true
end

local function find_all(lines, block)
	local out = {}
	if #block == 0 then
		return out
	end
	for pos = 1, #lines - #block + 1 do
		if snippet.lines_match_at(lines, pos, block) then
			out[#out + 1] = pos
		end
	end
	return out
end

--- The review-buffer line range of the suggestion whose lines contain
--- `line`, or nil (a removal has no lines of its own there, and plain text
--- of his own is no suggestion). Adjacent suggestions form ONE diff hunk, so
--- acting on a single suggestion means acting on this range, not the hunk.
function M.item_range(s, line)
	local review_lines = buf_lines(s.review_buf)
	for _, item in pairs(s.shown) do
		local after = snippet.split_lines(item.after)
		for _, pos in ipairs(find_all(review_lines, after)) do
			if line >= pos and line <= pos + #after - 1 then
				return pos, pos + #after - 1, item
			end
		end
	end
end

-- Runs `diffget` (obtain from his notes) or `diffput` (hand to his notes)
-- for the suggestion under the cursor in the review split, or for the whole
-- hunk there when the cursor isn't on a suggestion's own lines. Returns
-- whether either buffer changed.
local function diff_act(s, verb)
	local win = vim.fn.bufwinid(s.review_buf)
	if win == -1 then
		return false, "review buffer has no window"
	end
	local before_review, before_notes = buf_lines(s.review_buf), buf_lines(s.notes_buf)
	vim.api.nvim_win_call(win, function()
		local first, last = M.item_range(s, vim.api.nvim_win_get_cursor(win)[1])
		if first then
			pcall(vim.cmd, string.format("%d,%d%s", first, last, verb))
		else
			pcall(vim.cmd, "normal! d" .. (verb == "diffget" and "o" or "p"))
		end
	end)
	if vim.deep_equal(before_review, buf_lines(s.review_buf)) and vim.deep_equal(before_notes, buf_lines(s.notes_buf)) then
		return false, "no suggestion under the cursor"
	end
	return true
end

--- The decline key: makes the suggestion under the cursor in the review
--- split equal his text (it obtains his side), so its diff disappears. An
--- ordinary edit — `u` undoes it; nothing is recorded until the review split
--- is saved.
function M.decline(review_buf)
	local s = session_for_review_buf(review_buf)
	if not s then
		return false, "not a desk review buffer"
	end
	local ok, why = diff_act(s, "diffget")
	if ok then
		M.refresh_overview(s)
	end
	return ok, why
end

--- Takes the suggestion under the cursor into his notes buffer (just that
--- one — `do` in his window takes the whole hunk, which can be several
--- adjacent suggestions). His buffer stays unsaved until he commits.
function M.take(review_buf)
	local s = session_for_review_buf(review_buf)
	if not s then
		return false, "not a desk review buffer"
	end
	local ok, why = diff_act(s, "diffput")
	if ok then
		M.refresh_overview(s)
	end
	return ok, why
end

-- ---------------------------------------------------------------------------
-- Overview: one quickfix entry per remaining hunk
-- ---------------------------------------------------------------------------

M.OVERVIEW_TITLE = "Desk overview"
M.DECLINED_TITLE = "Desk declined recently"
M.DECLINED_WINDOW_DAYS = 14

--- The suggestions still left as hunks right now: shown at open, still
--- proposed in the review buffer, not yet in his notes. Each with the review
--- buffer line to jump to, sorted by position.
function M.remaining(s)
	local review_lines = buf_lines(s.review_buf)
	local notes_lines = buf_lines(s.notes_buf)
	local hunks = vim.diff(
		snippet.join_lines(notes_lines, true),
		snippet.join_lines(review_lines, true),
		{ result_type = "indices" }
	)
	local out = {}
	for _, item in pairs(s.shown) do
		if proposal.proposed_in(item, review_lines, s.base) and not proposal.proposed_in(item, notes_lines, s.base) then
			local lnum = 1
			local after = snippet.split_lines(item.after)
			if #after > 0 then
				local positions = find_all(review_lines, after)
				lnum = positions[1] or 1
				for _, pos in ipairs(positions) do
					for _, h in ipairs(hunks) do
						if pos >= h[3] and pos <= h[3] + math.max(h[4], 1) - 1 then
							lnum = pos
						end
					end
				end
			else
				local positions = find_all(notes_lines, snippet.split_lines(item.before))
				for _, pos in ipairs(positions) do
					for _, h in ipairs(hunks) do
						if pos >= h[1] and pos <= h[1] + math.max(h[2], 1) - 1 then
							lnum = math.max(h[3], 1)
						end
					end
				end
			end
			out[#out + 1] = { item = item, lnum = math.min(lnum, math.max(#review_lines, 1)) }
		end
	end
	table.sort(out, function(a, b)
		if a.lnum ~= b.lnum then
			return a.lnum < b.lnum
		end
		return a.item.id < b.item.id
	end)
	return out
end

local function overview_items(s)
	local qf = {}
	for _, r in ipairs(M.remaining(s)) do
		qf[#qf + 1] = { bufnr = s.review_buf, lnum = r.lnum, col = 1, text = r.item.headline or r.item.id }
	end
	return qf
end

--- Rebuilds an overview list already open for `s` (after a decline or a save).
function M.refresh_overview(s)
	local info = vim.fn.getqflist({ title = 0, context = 0 })
	if info.title ~= M.OVERVIEW_TITLE or not (info.context and info.context.desk_review_buf == s.review_buf) then
		return
	end
	vim.fn.setqflist({}, "r", { title = M.OVERVIEW_TITLE, items = overview_items(s), context = info.context })
end

--- The overview key: opens the review split if needed, then a quickfix list
--- with one headline per remaining hunk.
function M.overview(notes_buf)
	local s = sessions[notes_buf]
	if not s or not vim.api.nvim_buf_is_valid(s.review_buf) then
		local ok, why = M.open_review(notes_buf)
		if not ok then
			return false, why
		end
		s = sessions[notes_buf]
	end
	vim.fn.setqflist({}, " ", {
		title = M.OVERVIEW_TITLE,
		items = overview_items(s),
		context = { desk_review_buf = s.review_buf },
	})
	vim.cmd("copen")
	return true
end

-- ---------------------------------------------------------------------------
-- Quickfix handlers: <CR> jumps (overview) and r restores (declined list)
-- ---------------------------------------------------------------------------

local function is_loclist_win(win)
	local info = vim.fn.getwininfo(win)[1]
	return info ~= nil and info.loclist == 1
end

--- The quickfix `<CR>` handler for every quickfix buffer (installed once,
--- globally): anything that isn't desk's own overview falls through to the
--- ordinary jump. An overview entry jumps in the review split — through the
--- jumplist (`m'` first), so Ctrl-O/Ctrl-I work there afterward — from
--- wherever the overview was opened, including its own split.
function M.qf_jump()
	if is_loclist_win(vim.api.nvim_get_current_win()) then
		vim.cmd(vim.fn.line(".") .. "ll")
		return
	end
	if vim.fn.getqflist({ title = 0 }).title ~= M.OVERVIEW_TITLE then
		vim.cmd(vim.fn.line(".") .. "cc")
		return
	end
	local item = vim.fn.getqflist()[vim.fn.line(".")]
	if not item or not item.bufnr or item.bufnr == 0 then
		return
	end
	local win = vim.fn.bufwinid(item.bufnr)
	if win == -1 then
		vim.notify("desk: the review split is closed — press the review key again", vim.log.levels.WARN)
		return
	end
	vim.api.nvim_set_current_win(win)
	vim.cmd("normal! m'")
	vim.api.nvim_win_set_cursor(win, { math.max(item.lnum, 1), 0 })
end

-- ---------------------------------------------------------------------------
-- Declined recently
-- ---------------------------------------------------------------------------

--- A short, one-word-ish label for where a suggestion came from, never the
--- raw `item.source` verbatim: a URL's own host, a ticket-shaped token as
--- "ticket KEY", a session-shaped one as "session NAME", else "notes".
function M.format_source(source, tokens_config)
	if not source or source == "" then
		return "notes"
	end
	local host = source:match("^https?://([^/]+)")
	if host then
		return host
	end
	local classification = tokens.classify(source, tokens_config or {})
	if classification.kind == "url" then
		return "ticket " .. source
	end
	if classification.kind == "session" then
		return "session " .. source
	end
	return "notes"
end

--- Declines still in force within the last `days`, newest first.
function M.declined_recently(repo, days)
	local cutoff = os.time() - days * 86400
	local out = {}
	for _, rec in ipairs(ledger.declined(ledger.read(repo)).list) do
		if (rec.at or 0) >= cutoff then
			out[#out + 1] = rec
		end
	end
	table.sort(out, function(a, b)
		return (a.at or 0) > (b.at or 0)
	end)
	return out
end

--- Opens a quickfix list of recent declines; `r` on an entry restores it.
function M.list_declined_recently(bufnr, days)
	local repo = M.repo_context(bufnr)
	if not repo then
		return
	end
	local entries = M.declined_recently(repo, days or M.DECLINED_WINDOW_DAYS)
	local tokens_config = tokens.tokens_from((tokens.load()))
	local qf_items = {}
	for _, rec in ipairs(entries) do
		qf_items[#qf_items + 1] =
			{ text = string.format("%s (%s)", rec.headline or rec.id, M.format_source(rec.source, tokens_config)) }
	end
	vim.fn.setqflist({}, " ", {
		title = M.DECLINED_TITLE,
		items = qf_items,
		context = { desk_declined = { repo = repo, ids = vim.tbl_map(function(r)
			return r.id
		end, entries) } },
	})
	vim.cmd("copen")
end

--- Restores a declined item: it leaves the decline ledger, so the next pass
--- proposes it again.
function M.restore(repo, id)
	return ledger.restore_declined(repo, id)
end

--- The quickfix "r" handler: restores the declined entry under the cursor.
function M.qf_restore()
	if is_loclist_win(vim.api.nvim_get_current_win()) then
		return
	end
	local qf = vim.fn.getqflist({ title = 0, context = 0 })
	if qf.title ~= M.DECLINED_TITLE then
		return
	end
	local declined = qf.context and qf.context.desk_declined
	local id = declined and declined.ids[vim.fn.line(".")]
	if not id then
		return
	end
	local ok, err = M.restore(declined.repo, id)
	if ok then
		vim.notify("desk: restored — the next pass proposes it again", vim.log.levels.INFO)
		vim.cmd("cclose")
	else
		vim.notify("desk: " .. tostring(err), vim.log.levels.WARN)
	end
end

-- ---------------------------------------------------------------------------
-- His commit key
-- ---------------------------------------------------------------------------

--- Saves his notes buffer and commits the file as it is, then records any
--- suggestion now in HEAD as taken. A no-op commit when nothing changed.
function M.commit(bufnr)
	local repo, file = M.repo_context(bufnr)
	if not repo then
		return false, file
	end
	if vim.bo[bufnr].modified then
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("silent write")
		end)
	end
	local _, dirty = git.run(repo, { "status", "--porcelain", "--", file })
	if vim.trim(dirty) ~= "" then
		local ok, _, err = git.run(repo, { "add", "--", file })
		if ok then
			ok, _, err = git.run(repo, { "commit", "-q", "-m", "notes", "--", file })
		end
		if not ok then
			return false, "git commit failed: " .. err
		end
	end
	local taken = proposal.sync_taken(repo)
	return true, { taken = #taken }
end

-- ---------------------------------------------------------------------------
-- Status line: the runner's status.json summary in the notes buffer's winbar.
-- ---------------------------------------------------------------------------

function M.status_line()
	return status.summary(status.read())
end

function M.refresh_status_line(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local line = M.status_line()
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		vim.wo[win].winbar = line
	end
end

-- ---------------------------------------------------------------------------
-- Wiring: buffer-local keymaps for a notes buffer, and the once-only global
-- quickfix overrides. The notes files are enabled by a local marker in the
-- notes repo — not a path in dotfiles — so this module never hardcodes
-- where the notes repo lives.
-- ---------------------------------------------------------------------------

M.MARKER = ".desk-notes"

--- True if `dir` or an ancestor (up to the filesystem root) holds the marker.
function M.has_marker(dir)
	local d = dir
	for _ = 1, 32 do
		if vim.uv.fs_stat(d .. "/" .. M.MARKER) then
			return true
		end
		local parent = d:match("^(.*)/[^/]+$")
		if not parent or parent == d then
			return false
		end
		d = parent
	end
	return false
end

--- The keys this module adds, layered over gitsigns' own raw per-hunk keys
--- (<leader>gj/gk/ga/gu/gp/gb, unchanged). `<leader>gD` and `<leader>gA`
--- live in the review split only.
M.KEYMAPS = {
	{ mode = "n", lhs = "<leader>gR", desc = "Review: open the proposal as a diff against your notes" },
	{ mode = "n", lhs = "<leader>gc", desc = "Commit your notes (records taken suggestions)" },
	{ mode = "n", lhs = "<leader>go", desc = "Overview: remaining suggestions" },
	{ mode = "n", lhs = "<leader>gd", desc = "Declined recently: list, restorable with r" },
	{ mode = "n", lhs = "<leader>gD", desc = "Decline the suggestion under the cursor (review split)" },
	{ mode = "n", lhs = "<leader>gA", desc = "Take just the suggestion under the cursor (review split)" },
}

local qf_autocmd_installed = false

local function install_qf_autocmd()
	if qf_autocmd_installed then
		return
	end
	qf_autocmd_installed = true
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "qf",
		callback = function(args)
			vim.keymap.set("n", "<CR>", M.qf_jump, { buffer = args.buf, desc = "Desk: jump (jumplist-safe)" })
			vim.keymap.set("n", "r", M.qf_restore, { buffer = args.buf, desc = "Desk: restore this declined item" })
		end,
	})
end

local function report(ok, err_or_result)
	if not ok then
		vim.notify("desk: " .. tostring(err_or_result), vim.log.levels.WARN)
	end
end

--- Attaches the review keymaps to `bufnr`. Safe to call more than once for
--- the same buffer (idempotent).
function M.attach(bufnr)
	if vim.b[bufnr].desk_attached then
		return
	end
	vim.b[bufnr].desk_attached = true
	install_qf_autocmd()

	local map = function(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = desc })
	end
	map("<leader>gR", function()
		report(M.open_review(bufnr))
	end, "Review: open the proposal as a diff against your notes")
	map("<leader>gc", function()
		report(M.commit(bufnr))
		M.refresh_status_line(bufnr)
	end, "Commit your notes (records taken suggestions)")
	map("<leader>go", function()
		report(M.overview(bufnr))
	end, "Overview: remaining suggestions")
	map("<leader>gd", function()
		M.list_declined_recently(bufnr)
	end, "Declined recently: list, restorable with r")
	vim.api.nvim_buf_create_user_command(bufnr, "DeskDeclined", function()
		M.list_declined_recently(bufnr)
	end, { desc = "Desk: list declined-recently items, restorable with r" })

	vim.api.nvim_create_autocmd("BufEnter", {
		buffer = bufnr,
		callback = function()
			M.refresh_status_line(bufnr)
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = bufnr,
		callback = function()
			-- winbar is a window option, not a real per-buffer one: left set,
			-- it would keep showing this status line over whatever the window
			-- shows next.
			vim.wo[0].winbar = ""
		end,
	})

	M.refresh_status_line(bufnr)
end

return M
