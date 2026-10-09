-- The stateless diff review. A pass leaves ONE proposal commit
-- (desk.proposal): the user's HEAD at pass time as its parent, the files with every
-- suggestion applied as its tree. Nothing in it ever enters the user's notes unless
-- the user takes it, and nothing here tracks a suggestion by position.
--
-- Review key: merges the user's CURRENT buffer text (ours) with the proposal
-- (theirs) against the pass-time version (base) with `git merge-file`, the user's
-- text winning any conflict, and opens the result in a split above the notes
-- as an `acwrite` scratch buffer, both windows in diff mode, the cursor in the
-- split. The user takes a hunk with `dp` there or `do` in the notes window
-- (editing first is fine) and leaves one alone to mean "not now" (the next
-- pass carries it). The decline key makes the hunk under the cursor in the
-- review split equal the user's text — an ordinary edit, so plain `u` undoes
-- it; `u` in the split undoes a take made there too. Nothing is recorded
-- until the user SAVES the review split: that is the commit point, recording every suggestion whose lines are gone
-- from the review buffer and not in the user's notes as declined. A discarded
-- review buffer records nothing. Adjacent suggestions are one diff hunk, so
-- the decline key (and `<leader>gA`, which takes one) act on a single
-- suggestion's own lines rather than the whole hunk.
local apply = require("desk.apply")
local block = require("desk.block")
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

-- A buffer's lines as the file's: an empty file loads as one empty line.
local function buf_lines(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if #lines == 1 and lines[1] == "" then
		return {}
	end
	return lines
end

-- ---------------------------------------------------------------------------
-- The merged view
-- ---------------------------------------------------------------------------

--- The merged view of the user's current text with the proposal (see
--- desk.proposal.merged_lines): the union merge, which keeps a suggestion
--- the user's own nearby edit conflicts with instead of dropping it.
function M.merged_lines(repo, p, file, ours_lines)
	local clean, union = proposal.merged_lines(repo, p, file, ours_lines)
	if not clean then
		return nil, union
	end
	return union
end

-- ---------------------------------------------------------------------------
-- Sessions (one review split per notes buffer)
-- ---------------------------------------------------------------------------

local sessions = {} -- notes bufnr -> session
local preview -- the overview's preview state, below
local complete_halves -- a take of half a move finishes it, below

local function live_session(bufnr)
	local s = bufnr and sessions[bufnr]
	if s and vim.api.nvim_buf_is_valid(s.review_buf) then
		return s
	end
end

--- The review split's buffer while a review is open on `notes_buf`, else
--- nil. The disk merge (nvim/lua/diskmerge.lua) waits for it to go.
function M.open_review_buf(notes_buf)
	local s = live_session(notes_buf)
	return s and s.review_buf
end

local function report(ok, err_or_result)
	if not ok then
		vim.notify("desk: " .. tostring(err_or_result), vim.log.levels.WARN)
	end
end

local function session_for_review_buf(buf)
	for _, s in pairs(sessions) do
		if s.review_buf == buf then
			return s
		end
	end
end

-- ---------------------------------------------------------------------------
-- Taken by decision: when the user takes a suggestion (`do` in the user's notes, or the
-- take key in the review split) its id is remembered, and the next save of
-- either buffer records it as taken by that id — so a suggestion the user edits
-- after taking it is still taken, not re-proposed, and not declined by the
-- review split's save.
-- ---------------------------------------------------------------------------

-- Each shown suggestion that adds lines is tracked in the review buffer by
-- an extmark over its lines, so editing a suggestion's text in the split
-- doesn't lose which suggestion it is.
local MARK_NS = vim.api.nvim_create_namespace("desk_review_items")

--- The lines (first, last, text) the live mark of `item` covers in the
--- review buffer, or nil when it has none or has collapsed.
local function mark_range(s, item)
	local id = s.marks and s.marks[item.id]
	if not id then
		return nil
	end
	local m = vim.api.nvim_buf_get_extmark_by_id(s.review_buf, MARK_NS, id, { details = true })
	if not m or not m[1] or not m[3] or m[3].invalid then
		return nil
	end
	local first, last = m[1] + 1, m[3].end_row
	if m[3].end_col and m[3].end_col > 0 then
		last = last + 1
	end
	if last < first or last > vim.api.nvim_buf_line_count(s.review_buf) then
		return nil
	end
	return first, last, vim.api.nvim_buf_get_lines(s.review_buf, first - 1, last, false)
end

local pending_taken = {} -- notes bufnr -> { repo, ids = id -> { item, base, seq, pre } }

local function undo_seq(buf)
	return vim.api.nvim_buf_call(buf, function()
		return vim.fn.undotree().seq_cur
	end)
end

-- Whether undo state `seq` of `buf` is the current state or one it was
-- reached from: false once `seq` was undone and the buffer moved on along
-- another branch, nil when the tree no longer holds it. Undo numbers can't
-- be compared across branches, since a new branch numbers on from the
-- highest one used.
local function undo_reaches(buf, seq)
	local tree = vim.api.nvim_buf_call(buf, vim.fn.undotree)
	local parent = {}
	local function walk(entries, from)
		local prev = from
		for _, e in ipairs(entries) do
			parent[e.seq] = prev
			if e.alt then
				walk(e.alt, prev)
			end
			prev = e.seq
		end
	end
	walk(tree.entries, 0)
	if seq ~= 0 and parent[seq] == nil then
		return nil
	end
	local at = tree.seq_cur
	while at ~= nil do
		if at == seq then
			return true
		end
		at = parent[at]
	end
	return false
end

local function remember_taken(s, item, pre)
	s.took_into = s.took_into or {}
	s.took_into[s.notes_buf] = true
	local pend = pending_taken[s.notes_buf] or { repo = s.repo, ids = {} }
	pending_taken[s.notes_buf] = pend
	pend.ids[item.id] = { item = item, base = s.base, seq = undo_seq(s.notes_buf), pre = pre }
end

--- Remembers every shown suggestion whose text reached the user's notes buffer
--- since `pre` (the buffer's lines before the take), plus `known` (the
--- item the take key acted on, whatever its edited text).
local function note_takes(s, pre, known)
	local now = buf_lines(s.notes_buf)
	if vim.deep_equal(pre, now) then
		return
	end
	for _, item in pairs(s.shown) do
		local _, _, text = mark_range(s, item)
		local edited_in = text and #text > 0 and proposal.contains(now, text) and not proposal.contains(pre, text)
		if
			(known and known.id == item.id)
			or edited_in
			or (not proposal.proposed_in(item, pre, s.base) and proposal.proposed_in(item, now, s.base))
		then
			remember_taken(s, item, pre)
		end
	end
end

--- Records, as taken, the suggestions the user took since the last flush. One
--- whose take the user has undone (the text is not there, and the buffer's
--- undo state no longer descends from the take) is dropped. Returns how many
--- were recorded, and them.
function M.flush_taken(notes_buf)
	local pend = pending_taken[notes_buf]
	if not pend then
		return 0, {}
	end
	pending_taken[notes_buf] = nil
	if not vim.api.nvim_buf_is_valid(notes_buf) then
		return 0, {}
	end
	local lines, seq = buf_lines(notes_buf), undo_seq(notes_buf)
	local items = {}
	for _, t in pairs(pend.ids) do
		local kept = undo_reaches(notes_buf, t.seq)
		if kept == nil then
			kept = seq >= t.seq
		end
		if proposal.proposed_in(t.item, lines, t.base) or (kept and not vim.deep_equal(lines, t.pre)) then
			items[#items + 1] = t.item
		end
	end
	table.sort(items, function(a, b)
		return a.id < b.id
	end)
	ledger.record_taken(pend.repo, items)
	-- An open review counts these as done from here on, edited or not.
	local s = sessions[notes_buf]
	if s then
		s.taken_saved = s.taken_saved or {}
		for _, item in ipairs(items) do
			s.taken_saved[item.id] = true
		end
	end
	return #items, items
end

local function pending_ids(notes_buf)
	local pend = pending_taken[notes_buf]
	return pend and pend.ids or {}
end

-- ---------------------------------------------------------------------------
-- Undo from the review split: a take made there (`dp`, the take key) changed
-- the notes buffer, not the split's, so plain `u` in the split would skip
-- it. Each such take is stacked with both buffers' undo states. A decline
-- (or any typing) is the split's own edit and so advances the split's undo
-- state: when the split has changed since the newest take, that edit is the
-- more recent one, and plain `u` undoes it.
-- ---------------------------------------------------------------------------

-- Starts a new undo block in `buf`: edits made through the API with no
-- keypress between them otherwise join one block, and one `undo` would
-- take back both acts.
local function undo_break(buf)
	vim.bo[buf].undolevels = vim.bo[buf].undolevels
end

local function begin_take(s)
	undo_break(s.notes_buf)
	undo_break(s.review_buf)
	return {
		tick = vim.api.nvim_buf_get_changedtick(s.notes_buf),
		notes_pre = undo_seq(s.notes_buf),
		review_seq = undo_seq(s.review_buf),
		pending = vim.deepcopy(pending_ids(s.notes_buf)),
	}
end

local function end_take(s, t, stack)
	if vim.api.nvim_buf_get_changedtick(s.notes_buf) == t.tick then
		return
	end
	t.notes_post = undo_seq(s.notes_buf)
	t.ids = {}
	for id, p in pairs(pending_ids(s.notes_buf)) do
		if not t.pending[id] or p.seq ~= t.pending[id].seq then
			t.ids[#t.ids + 1] = id
		end
	end
	t.pending = nil
	stack = stack or s.takes
	stack[#stack + 1] = t
end

local function first_hunk(win)
	vim.api.nvim_win_call(win, function()
		vim.cmd("diffupdate")
		M.first_change(win)
	end)
end

-- `quiet` for a close that hands over to another review rather than ending
-- the user's: the notes the review started from are not put back.
local function close_session(s, quiet)
	s.quiet = quiet
	sessions[s.notes_buf] = nil
	if vim.api.nvim_buf_is_valid(s.review_buf) then
		pcall(vim.api.nvim_buf_delete, s.review_buf, { force = true })
	end
end

--- Records as declined every shown suggestion whose lines are gone from the
--- review buffer and not present in the user's notes — the review split's save.
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
	local taking = pending_ids(s.notes_buf)
	local gone = {}
	for _, item in pairs(s.shown) do
		local _, _, text = mark_range(s, item)
		if taking[item.id] then
			-- taken by decision: edited text is no reason to call it declined
		elseif text and #text > 0 and not proposal.contains(notes_lines, text) then
			-- edited in the split and not taken yet: still waiting
		elseif not proposal.proposed_in(item, review_lines, s.base) and not proposal.proposed_in(item, notes_lines, s.base) then
			gone[#gone + 1] = item
		end
	end
	table.sort(gone, function(a, b)
		return a.id < b.id
	end)
	-- Undo after a save: a suggestion this session declined whose lines are
	-- back in the review buffer or the user's notes is no longer declined.
	s.declined_here = s.declined_here or {}
	for id in pairs(s.declined_here) do
		local item = s.shown[id]
		if item and (proposal.proposed_in(item, review_lines, s.base) or proposal.proposed_in(item, notes_lines, s.base)) then
			ledger.restore_declined(s.repo, id)
			s.declined_here[id] = nil
		end
	end
	if not ledger.record_declines(s.repo, gone) then
		return false, "could not record the declines in the ledger"
	end
	for _, item in ipairs(gone) do
		s.declined_here[item.id] = true
	end
	M.flush_taken(s.notes_buf)
	vim.bo[s.review_buf].modified = false
	return true, #gone
end

-- Maps a row of one side of a diff to the other: `hunks` as vim.diff gives
-- them for (a -> b), `swap` true to map a b-row to the a side instead.
-- A row inside a changed hunk maps to the end of that hunk's other side.
local function map_row(hunks, l, swap)
	local sa, ca, sb, cb = 1, 2, 3, 4
	if swap then
		sa, ca, sb, cb = 3, 4, 1, 2
	end
	local shift = 0
	for _, h in ipairs(hunks) do
		if h[ca] > 0 then
			local last = h[sa] + h[ca] - 1
			if l > last then
				shift = shift + h[cb] - h[ca]
			elseif l >= h[sa] then
				return h[cb] > 0 and h[sb] + h[cb] - 1 or h[sb]
			else
				break
			end
		elseif l >= h[sa] then
			shift = shift + h[cb]
		else
			break
		end
	end
	return l + shift
end

local function diff_indices(a, b)
	return vim.diff(snippet.join_lines(a, true), snippet.join_lines(b, true), { result_type = "indices" })
end

-- ---------------------------------------------------------------------------
-- The other file: the proposal holds suggestions for notes.md and reading.md
-- alike. A review split covers one file, so the key and the overview say
-- what waits in the other and can go there.
-- ---------------------------------------------------------------------------

local function file_ours(repo, file)
	local path = repo .. "/" .. file
	local b = vim.fn.bufnr(path)
	if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
		return buf_lines(b)
	end
	return proposal.lines_at(repo, "HEAD", file)
end

-- The line of `ours` a suggestion's hunk aligns with, for a file with no
-- session of its own.
local function entry_lnum(item, ours, merged)
	local hunks = diff_indices(ours, merged)
	local after = snippet.split_lines(item.after)
	if #after > 0 then
		for _, pos in ipairs(proposal.positions(merged, after)) do
			for _, h in ipairs(hunks) do
				if pos <= h[3] + math.max(h[4], 1) - 1 and pos + #after - 1 >= h[3] then
					return math.max(1, math.min(h[2] > 0 and h[1] or h[1] + 1, #ours))
				end
			end
		end
	else
		for _, pos in ipairs(proposal.positions(ours, snippet.split_lines(item.before))) do
			for _, h in ipairs(hunks) do
				if h[2] > 0 and pos >= h[1] and pos <= h[1] + h[2] - 1 then
					return pos
				end
			end
		end
	end
	return 1
end

--- What waits in the proposal's other files than `file`: a list of
--- { file, count, entries = { { item, lnum, conflict } } }, only files with
--- something to show.
function M.pending_elsewhere(repo, file, p)
	p = p or proposal.read(repo)
	local out = {}
	if not p then
		return out
	end
	local seen = { [file] = true }
	for _, item in ipairs(p.items) do
		local f = item.file
		if f and not seen[f] then
			seen[f] = true
			local ours = file_ours(repo, f)
			local r = proposal.reviewable(repo, p, f, ours)
			if r and next(r.shown) ~= nil then
				local entries = {}
				for _, it in ipairs(p.items) do
					if r.shown[it.id] then
						entries[#entries + 1] = { item = it, lnum = entry_lnum(it, ours, r.merged), conflict = r.conflicts[it.id] }
					end
				end
				out[#out + 1] = { file = f, count = #entries, entries = entries }
			end
		end
	end
	return out
end

local function say_elsewhere(repo, file, p)
	for _, o in ipairs(M.pending_elsewhere(repo, file, p)) do
		vim.notify(string.format("desk: %d more suggestion(s) in %s", o.count, o.file), vim.log.levels.INFO)
	end
end

-- Another nvim's swap file for `path`, as {pid, running}, or nil: what
-- makes loading it here stop on E325 (swap file ATTENTION). swapinfo()
-- gives the pid only while that process runs, 0 once it is gone.
local function swap_elsewhere(path)
	if not vim.o.swapfile then
		return nil
	end
	local want = vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
	local tail = vim.fn.fnamemodify(path, ":t")
	-- swapfilelist() mangles a 'directory' entry ending in //, the default,
	-- so the candidates are globbed here: "%path%to%file.swp" in such a
	-- directory, ".file.swp" in the others, either as .sw? down to .saa.
	for _, dir in ipairs(vim.split(vim.o.directory, ",", { trimempty = true })) do
		dir = dir:gsub("/+$", "")
		if dir == "." or dir:match("^%./") then
			dir = vim.fn.fnamemodify(path, ":h") .. dir:sub(2)
		end
		dir = vim.fn.expand(dir)
		local found = vim.fn.glob(dir .. "/*" .. tail .. ".s??", false, true)
		vim.list_extend(found, vim.fn.glob(dir .. "/." .. tail .. ".s??", false, true))
		for _, f in ipairs(found) do
			local info = vim.fn.swapinfo(f)
			local of = type(info) == "table" and info.fname
			if of and vim.fn.resolve(vim.fn.fnamemodify(of, ":p")) == want and info.pid ~= vim.fn.getpid() then
				local pid = (tonumber(info.pid) or 0) > 0 and info.pid or nil
				return { pid = pid, running = pid ~= nil and vim.uv.kill(pid, 0) == 0 }
			end
		end
	end
	return nil
end

local function swap_message(file, other)
	if other and not other.running then
		return string.format("%s has a swap file from an nvim that is no longer running; recover or delete it first", file)
	end
	local pid = other and other.pid and string.format(" (pid %d)", other.pid) or ""
	return string.format("%s is open in another nvim%s; close it there first", file, pid)
end

--- Loads `file` of the notes repo into a buffer, or returns nil, why when it
--- can't: another nvim has it open, or the load failed. Nothing is left
--- behind on failure, so the caller can leave everything as it was. The
--- swap check runs before loading, since a load that meets the swap file
--- prints the whole ATTENTION text before failing.
function M.load_file_buf(repo, file)
	local path = repo .. "/" .. file
	local existed = vim.fn.bufexists(path) == 1
	local b = vim.fn.bufadd(path)
	if vim.api.nvim_buf_is_loaded(b) then
		return b
	end
	local function drop()
		if not existed and vim.api.nvim_buf_is_valid(b) then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		elseif vim.api.nvim_buf_is_loaded(b) then
			pcall(vim.api.nvim_buf_delete, b, { force = true, unload = true })
		end
	end
	local other = swap_elsewhere(path)
	if other then
		drop()
		return nil, swap_message(file, other)
	end
	local ok, err = pcall(vim.fn.bufload, b)
	if ok then
		return b
	end
	drop()
	if tostring(err):match("E325") then
		return nil, swap_message(file, nil)
	end
	return nil, string.format("couldn't open %s: %s", file, (tostring(err):gsub("^Vim:", "")))
end

--- Opens `file` of the notes repo in a window above the current one (or
--- focuses it) and attaches the review keys. Returns its buffer, or nil,
--- why when it can't be loaded.
local function open_file_buf(repo, file)
	local b, why = M.load_file_buf(repo, file)
	if not b then
		return nil, why
	end
	local win = vim.fn.bufwinid(b)
	if win == -1 then
		vim.cmd("aboveleft split")
		vim.api.nvim_win_set_buf(0, b)
	else
		vim.api.nvim_set_current_win(win)
	end
	M.attach(b)
	return b
end

-- Asks about the split's unsaved declines before it goes; true to go on.
local function settle_declines(s)
	if not vim.bo[s.review_buf].modified then
		return true
	end
	local choice = M.confirm("The review split has unsaved declines.", "&Save them\n&Discard them\n&Cancel")
	if choice == 1 then
		local saved, why = M.save_review(s)
		if not saved then
			return false, why
		end
		return true
	end
	if choice == 2 then
		vim.bo[s.review_buf].modified = false
		return true
	end
	return false, "kept the review split: it has unsaved declines"
end

-- The ends that save (`:wq` in the split, the overview's `Q`, `<leader>gq`)
-- write the notes the review took into too: a take lives only in the notes
-- buffer until that is written, so quitting nvim after ending the review
-- would lose it. Pending takes are recorded first, since a write from an
-- autocmd need not run BufWritePost.
local function write_taken_notes(s)
	local wrote = {}
	for b in pairs(s.took_into or {}) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
			local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t")
			M.flush_taken(b)
			local ok, err = pcall(vim.api.nvim_buf_call, b, function()
				vim.cmd("silent write")
			end)
			if ok then
				wrote[#wrote + 1] = name
			else
				vim.notify(string.format("desk: couldn't save %s: %s", name, (tostring(err):gsub("^Vim:", ""))), vim.log.levels.WARN)
			end
		end
	end
	table.sort(wrote)
	if #wrote > 0 then
		-- After the windows close, whose redraw would hide it.
		local msg = "desk: saved " .. table.concat(wrote, " and ") .. " with your takes"
		vim.schedule(function()
			vim.notify(msg, vim.log.levels.INFO)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- A stale review: the proposal ref moves while a review is open when a pass
-- lands or a session stages with desk-propose, and the split then still
-- shows the old merged text, hunks the overview no longer lists among them.
-- So entering either review window or the overview, and every take or
-- decline, compares the sha the review was built from with the ref. With
-- nothing unsaved the review is rebuilt in its own windows; unsaved
-- declines are work against the old view, never thrown away here, so the
-- view stays and refuses to act until `<leader>gR` has them saved or
-- discarded and reloads it.
-- ---------------------------------------------------------------------------

M.STALE_RELOADED = "the proposal changed: reloaded the review"
M.STALE_HELD = "the proposal changed: ␣gR reloads the review, once your unsaved declines are saved or discarded"

local function same_ids(a, b)
	for id in pairs(a) do
		if not b[id] then
			return false
		end
	end
	for id in pairs(b) do
		if not a[id] then
			return false
		end
	end
	return true
end

-- Rebuilds the open review `s` over proposal `p` in its own buffer and
-- windows, the cursor kept on the line it was on where that line is still
-- there. A proposal that would show the same suggestions as the same text
-- (a pass that changed nothing here) only takes over the sha, so the
-- split's undo history and anything unsaved in it stand; `force` rebuilds
-- it all the same. `need_shown` leaves it as it was when nothing here
-- would show. Returns true and whether the view changed, or false, why.
local function rebuild(s, p, need_shown, force)
	local ours = buf_lines(s.notes_buf)
	local r, err = proposal.reviewable(s.repo, p, s.file, ours)
	if not r then
		return false, err
	end
	if need_shown and next(r.shown) == nil then
		return false, "nothing to review here"
	end
	local old = buf_lines(s.review_buf)
	if not force and same_ids(s.shown, r.shown) and (vim.deep_equal(r.merged, s.merged) or vim.deep_equal(r.merged, old)) then
		s.sha, s.shown, s.conflicts, s.held_sha = p.sha, r.shown, r.conflicts, nil
		s.base = proposal.base_lines(s.repo, p, s.file)
		M.recount_saved(s)
		M.refresh_status_line(s.notes_buf)
		M.refresh_overview(s)
		return true, false
	end
	if vim.bo[s.review_buf].modified then
		return false, M.STALE_HELD
	end
	local rw = vim.fn.bufwinid(s.review_buf)
	local view = rw ~= -1 and vim.api.nvim_win_call(rw, vim.fn.winsaveview)
	-- Outside the undo history, as at open: `u` never brings the old view back.
	local undolevels = vim.bo[s.review_buf].undolevels
	vim.bo[s.review_buf].undolevels = -1
	vim.api.nvim_buf_set_lines(s.review_buf, 0, -1, false, r.merged)
	vim.bo[s.review_buf].undolevels = undolevels
	vim.bo[s.review_buf].modified = false
	vim.api.nvim_buf_clear_namespace(s.review_buf, MARK_NS, 0, -1)
	s.sha, s.shown, s.conflicts, s.merged = p.sha, r.shown, r.conflicts, r.merged
	s.base = proposal.base_lines(s.repo, p, s.file)
	-- Their undo states belong to the old view.
	s.takes, s.notes_acts, s.held_sha = {}, {}, nil
	M.recount_saved(s)
	M.place_marks(s, ours)
	M.place_del_marks(s)
	if view then
		local n = math.max(#r.merged, 1)
		local lnum = math.max(1, math.min(map_row(diff_indices(old, r.merged), view.lnum, false), n))
		view.topline = math.max(1, math.min(view.topline + lnum - view.lnum, n))
		view.lnum = lnum
		vim.api.nvim_win_call(rw, function()
			vim.cmd("diffupdate")
			vim.fn.winrestview(view)
		end)
	end
	M.refresh_status_line(s.notes_buf)
	M.refresh_overview(s)
	return true, true
end

--- Checks that the open review `s` shows the current proposal, rebuilding
--- it in place when it does not and nothing is unsaved. Returns true when
--- the view is current (rebuilt or not), else false, why. On entering a
--- window it says what it did itself, the held case once per proposal;
--- `acting` (a take or decline about to run) leaves the saying to the
--- caller, and returns false after a rebuild too, since the cursor was on
--- what the old view showed.
function M.ensure_current(s, acting)
	if s.reloading or sessions[s.notes_buf] ~= s or not vim.api.nvim_buf_is_valid(s.review_buf) then
		return true
	end
	local sha = git.ref_sha(s.repo, M.PROPOSAL_REF)
	if sha == s.sha then
		return true
	end
	local p = sha and proposal.read(s.repo, sha)
	local ok, changed
	if p then
		s.reloading = true
		ok, changed = rebuild(s, p)
		s.reloading = nil
	else
		ok, changed = false, "the proposal is gone: ␣gq ends this review"
	end
	if not ok then
		if not acting and s.held_sha ~= sha then
			vim.notify("desk: " .. tostring(changed), vim.log.levels.WARN)
		end
		s.held_sha = sha
		return false, changed
	end
	if not changed then
		return true
	end
	if acting then
		return false, M.STALE_RELOADED .. ", so nothing was done: look again and press again"
	end
	vim.notify("desk: " .. M.STALE_RELOADED, vim.log.levels.INFO)
	return true
end

--- Moves the review from `from_buf`'s file to `file` of the same repo, in
--- the window the notes were in: unsaved declines ask first (cancelling
--- keeps the review), and the review opens over the other file. When it
--- ends, that window shows the notes the move started from again, as they
--- were. Returns true, or false, why.
function M.move_review(from_buf, file)
	local repo = M.repo_context(from_buf)
	if not repo then
		return false, "not in a git repo"
	end
	-- Loaded before anything moves, so a file that can't be opened leaves
	-- the review as it was.
	local was_loaded = vim.fn.bufloaded(repo .. "/" .. file) == 1
	local b, load_why = M.load_file_buf(repo, file)
	if not b then
		return false, load_why
	end
	local s = live_session(from_buf)
	if s then
		local ok, why = settle_declines(s)
		if not ok then
			if not was_loaded then
				pcall(vim.api.nvim_buf_delete, b, { unload = true })
			end
			return false, why
		end
	end
	local win = vim.fn.bufwinid(from_buf)
	if win == -1 then
		win = vim.api.nvim_get_current_win()
	end
	local back = s and s.return_to
	if not back then
		back = { buf = from_buf, view = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
	end
	if s then
		close_session(s, true)
	end
	if not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_win_set_buf(win, b)
	vim.api.nvim_set_current_win(win)
	M.attach(b)
	local ok, why = M.open_review(b)
	local ns = sessions[b]
	if ns and back.buf ~= b then
		ns.return_to = back
	end
	if ns and s and s.took_into then
		ns.took_into = vim.tbl_extend("keep", ns.took_into or {}, s.took_into)
	end
	return ok, why
end

-- Puts back the notes a moved review started from, in the window that
-- showed the other file, once the review has ended by the user's hand.
local function return_home(s)
	local back = s.return_to
	if s.quiet or not back or sessions[s.notes_buf] or not vim.api.nvim_buf_is_valid(back.buf) then
		return
	end
	local win = vim.fn.win_findbuf(s.notes_buf)[1]
	if not win or #vim.fn.win_findbuf(back.buf) > 0 then
		return
	end
	vim.api.nvim_win_set_buf(win, back.buf)
	if back.view then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview(back.view)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Colours like git's: diff mode colours each side symmetrically ("this side
-- has it"), so in the notes window a line a suggestion adds shows as a red
-- filler and a line it removes shows green — backwards from a git diff. While
-- a review is open each window maps the diff groups to its own: red always
-- means "goes away if you take it", green "comes in", and the filler rows
-- are a quiet grey. Derived from the active scheme, so a scheme change
-- redefines them.
-- ---------------------------------------------------------------------------

M.REVIEW_WINHL = "DiffAdd:DeskDiffAdd,DiffChange:DeskDiffAddLine,DiffText:DeskDiffAddText,DiffDelete:DeskDiffFiller"
M.NOTES_WINHL = "DiffAdd:DeskDiffRemove,DiffChange:DeskDiffRemoveLine,DiffText:DeskDiffRemoveText,DiffDelete:DeskDiffFiller"

-- A group's background as it shows (a reversed group shows its fg there).
local function shown_bg(name)
	local h = vim.api.nvim_get_hl(0, { name = name, link = false })
	if h.reverse then
		return h.fg
	end
	return h.bg
end

local function channels(c)
	return { math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256 }
end

local function pack(ch)
	local function clamp(v)
		return math.max(0, math.min(255, math.floor(v + 0.5)))
	end
	return clamp(ch[1]) * 65536 + clamp(ch[2]) * 256 + clamp(ch[3])
end

-- `c` moved away from `from` by `t` of their difference (toward it when
-- negative), per channel: toward the background is dimmer on either one.
local function away(c, from, t)
	local a, o = channels(c), channels(from)
	return pack({ a[1] + (a[1] - o[1]) * t, a[2] + (a[2] - o[2]) * t, a[3] + (a[3] - o[3]) * t })
end

-- `c` with its distance from its own grey scaled by `1 + k`: more vivid at
-- about the same lightness.
local function saturate(c, k)
	local a = channels(c)
	local grey = (a[1] + a[2] + a[3]) / 3
	return pack({ a[1] + (a[1] - grey) * k, a[2] + (a[2] - grey) * k, a[3] + (a[3] - grey) * k })
end

function M.define_highlights()
	local set = vim.api.nvim_set_hl
	if not vim.o.termguicolors then
		for _, g in ipairs({ "DeskDiffAdd", "DeskDiffAddLine", "DeskDiffAddText" }) do
			set(0, g, { link = "DiffAdd" })
		end
		for _, g in ipairs({ "DeskDiffRemove", "DeskDiffRemoveLine", "DeskDiffRemoveText" }) do
			set(0, g, { link = "DiffDelete" })
		end
		set(0, "DeskDiffFiller", { link = "NonText" })
		return
	end
	local dark = vim.o.background ~= "light"
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local bg = normal.bg or (dark and 0x1c1c1c or 0xffffff)
	local fg = normal.fg or (dark and 0xd0d0d0 or 0x303030)
	local green = shown_bg("DiffAdd") or (dark and 0x2b4a2b or 0xd0f0d0)
	local red = shown_bg("DiffDelete") or (dark and 0x4a2b2b or 0xf0d0d0)
	-- The changed words: on a dark background more vivid rather than lighter,
	-- which would wash out light text; on a light one deeper.
	local function strong(c)
		return dark and saturate(c, 1) or away(c, bg, 0.5)
	end
	set(0, "DeskDiffAdd", { bg = green })
	set(0, "DeskDiffAddLine", { bg = away(green, bg, -0.45) })
	set(0, "DeskDiffAddText", { bg = strong(green) })
	set(0, "DeskDiffRemove", { bg = red })
	set(0, "DeskDiffRemoveLine", { bg = away(red, bg, -0.45) })
	set(0, "DeskDiffRemoveText", { bg = strong(red) })
	set(0, "DeskDiffFiller", { bg = away(bg, fg, -0.06), fg = away(bg, fg, -0.3) })
end

local colours_installed = false

local function install_colours()
	if colours_installed then
		return
	end
	colours_installed = true
	M.define_highlights()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("desk_review_colours", { clear = true }),
		callback = M.define_highlights,
	})
end

local function set_winhl(win, value)
	vim.api.nvim_set_option_value("winhighlight", value, { scope = "local", win = win })
end

-- Clears what the review set on `win`, leaving a winhighlight of the
-- user's own alone.
local function clear_winhl(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local v = vim.wo[win].winhighlight
	if v == M.REVIEW_WINHL or v == M.NOTES_WINHL then
		set_winhl(win, "")
	end
end

-- Soft wrap while reviewing: `diffthis` turns 'wrap' off, which runs long
-- prose lines off-screen, and bullets wrap under their own text. Diff mode
-- doesn't restore what it never set, and `diffoff` leaves a 'wrap' set after
-- `diffthis` on, so the notes window's own values are kept and put back.
local SOFT_WRAP = { wrap = true, linebreak = true, breakindent = true }

local function wrap_opts(win)
	local t = {}
	for o in pairs(SOFT_WRAP) do
		t[o] = vim.wo[win][o]
	end
	return t
end

local function set_wrap_opts(win, t)
	for o, v in pairs(t) do
		vim.api.nvim_set_option_value(o, v, { scope = "local", win = win })
	end
end

-- Whether `lnum` of the current window is where diff motion lands on a
-- change: a changed line, below a filler, or the last line over a filler
-- after it.
local function at_change(lnum)
	if vim.fn.diff_hlID(lnum, 1) ~= 0 or vim.fn.diff_filler(lnum) > 0 then
		return true
	end
	return lnum == vim.api.nvim_buf_line_count(0) and vim.fn.diff_filler(lnum + 1) > 0
end

--- Puts the cursor of `win` (the current window) on its first change, even
--- one on line 1, which plain `]c` from there skips: from an end of the
--- buffer, one step and one back lands on the first (last) change whether
--- or not it starts on that very line. Returns whether there is one.
function M.first_change(win)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	pcall(vim.cmd, "normal! ]c")
	pcall(vim.cmd, "normal! [c")
	return at_change(vim.api.nvim_win_get_cursor(win)[1])
end

--- `]c` (`forward`) or `[c` in a review window, wrapping around: past the
--- last change to the first, before the first to the last. Native diff
--- motion does the moving, so the cursor lands where `dp` or `do` acts.
function M.next_change(forward)
	local win = vim.api.nvim_get_current_win()
	local before = vim.api.nvim_win_get_cursor(win)
	local key = forward and "]c" or "[c"
	pcall(vim.cmd, "normal! " .. vim.v.count1 .. key)
	if not vim.deep_equal(before, vim.api.nvim_win_get_cursor(win)) then
		return true
	end
	local found
	if forward then
		found = M.first_change(win)
	else
		vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(0), 0 })
		pcall(vim.cmd, "normal! [c")
		pcall(vim.cmd, "normal! ]c")
		found = at_change(vim.api.nvim_win_get_cursor(win)[1])
	end
	if not found then
		vim.api.nvim_win_set_cursor(win, before)
		vim.notify("desk: no suggestions left here", vim.log.levels.INFO)
		return false
	end
	vim.notify(forward and "desk: wrapped to first" or "desk: wrapped to last", vim.log.levels.INFO)
	return true
end

-- `n`/`N` are the same motion, easier to type, while no search is
-- highlighted; with one highlighted they are the search's own.
local function map_next_change(buf)
	for lhs, forward in pairs({ ["]c"] = true, ["[c"] = false }) do
		vim.keymap.set("n", lhs, function()
			M.next_change(forward)
		end, { buffer = buf, desc = forward and "Next suggestion (wraps to the first)" or "Previous suggestion (wraps to the last)" })
	end
	for lhs, forward in pairs({ n = true, N = false }) do
		vim.keymap.set("n", lhs, function()
			if vim.o.hlsearch and vim.v.hlsearch == 1 then
				return lhs
			end
			return string.format("<Cmd>lua require('desk.review').next_change(%s)<CR>", tostring(forward))
		end, { buffer = buf, expr = true, desc = "Next/previous suggestion, or the search's match while one is highlighted" })
	end
end

-- The keys the notes buffer has only while a review of it is open.
local NOTES_REVIEW_KEYS = { "do", "]c", "[c", "n", "N", "u", "<leader>gA", "<leader>gD", "<leader>gq" }

local function unmap_notes_keys(notes_buf)
	if not vim.api.nvim_buf_is_valid(notes_buf) then
		return
	end
	for _, lhs in ipairs(NOTES_REVIEW_KEYS) do
		pcall(vim.keymap.del, "n", lhs, { buffer = notes_buf })
	end
end

-- Turns diff mode, the review's colours and its soft wrap off in every window
-- showing the notes as part of the review, and puts the status line back over
-- them.
local function tidy_notes_windows(s)
	local notes_buf = s.notes_buf
	if not vim.api.nvim_buf_is_valid(notes_buf) then
		return
	end
	for _, win in ipairs(vim.fn.win_findbuf(notes_buf)) do
		local hl = vim.wo[win].winhighlight
		local in_review = vim.wo[win].diff or hl == M.NOTES_WINHL or hl == M.REVIEW_WINHL
		if vim.wo[win].diff then
			vim.api.nvim_win_call(win, function()
				vim.cmd("diffoff")
			end)
		end
		clear_winhl(win)
		if in_review and s.notes_wrap then
			set_wrap_opts(win, s.notes_wrap)
		end
	end
	if sessions[notes_buf] == nil then
		unmap_notes_keys(notes_buf)
	end
	M.refresh_status_line(notes_buf)
end

-- ---------------------------------------------------------------------------
-- Quitting the notes window ends the review too, as `:q` in the split does:
-- the user is left in their notes, shown in the split's window when no other
-- window has them. Unsaved declines ask first; cancelling keeps the review
-- and puts the notes back below it.
-- ---------------------------------------------------------------------------

local watch_notes_window

local function end_from_notes(s)
	if sessions[s.notes_buf] ~= s or not vim.api.nvim_buf_is_valid(s.review_buf) then
		return
	end
	local notes_ok = vim.api.nvim_buf_is_valid(s.notes_buf)
	if notes_ok and vim.api.nvim_win_is_valid(s.notes_win) and vim.api.nvim_win_get_buf(s.notes_win) == s.notes_buf then
		return -- the notes are back where they were: nothing ended
	end
	local review_win = vim.fn.bufwinid(s.review_buf)
	if notes_ok and vim.bo[s.review_buf].modified then
		local choice = M.confirm("The review split has unsaved declines.", "&Save them\n&Discard them\n&Cancel")
		if choice == 1 then
			local saved, why = M.save_review(s)
			if not saved then
				vim.notify("desk: " .. tostring(why), vim.log.levels.WARN)
				choice = 3
			end
		end
		if choice ~= 1 and choice ~= 2 then
			local win = vim.fn.win_findbuf(s.notes_buf)[1]
			if not win and review_win ~= -1 then
				vim.api.nvim_win_call(review_win, function()
					vim.cmd("belowright split")
					win = vim.api.nvim_get_current_win()
				end)
				vim.api.nvim_win_set_buf(win, s.notes_buf)
			end
			if win then
				vim.api.nvim_win_call(win, function()
					vim.cmd("diffthis")
				end)
				set_wrap_opts(win, SOFT_WRAP)
				set_winhl(win, M.NOTES_WINHL)
				s.notes_win = win
				watch_notes_window(s, win)
				M.refresh_status_line(s.notes_buf)
			end
			return
		end
	end
	vim.bo[s.review_buf].modified = false
	if notes_ok and #vim.fn.win_findbuf(s.notes_buf) == 0 and review_win ~= -1 then
		vim.api.nvim_win_set_buf(review_win, s.notes_buf)
	end
	close_session(s)
	tidy_notes_windows(s)
end

-- The events run inside a window being closed, where the layout can't
-- change, so the ending waits for the next tick (once for both events).
watch_notes_window = function(s, win)
	local group = vim.api.nvim_create_augroup("desk_review_notes_" .. s.notes_buf, { clear = true })
	local function soon()
		if s.ending then
			return
		end
		s.ending = true
		vim.schedule(function()
			s.ending = false
			end_from_notes(s)
		end)
	end
	vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(win), callback = soon })
	vim.api.nvim_create_autocmd("BufWinLeave", { group = group, buffer = s.notes_buf, callback = soon })
end

--- Asks a question with choices; the number picked, 0 when cancelled or
--- when nothing can answer. Replaceable, so a headless run can answer.
function M.confirm(msg, choices)
	return vim.fn.confirm(msg, choices, 3)
end

-- The bars put their keys on the left and their count or status line on
-- the right, so the two windows of a review read the same way and the
-- table in the desk guide doesn't have to be open beside them. The review
-- split's keys, kept to about 120 columns with the count, which is why
-- zR/zM are left out. Each bar names only the window key that leaves it.
M.KEY_HINT = "n/N next · dp take · ␣gA one · ␣gD decline · u undo · zo/zc fold · ␣go list · ␣gc commit · C-n down"
-- The notes window's keys while a review is open. ␣gq ends the review from
-- either window, but only this bar has room for it.
M.NOTES_KEY_HINT = "n/N next · do take · ␣gA one · ␣gD decline · u undo · ␣gc commit · ␣gq close · C-t up"
-- And with no review open, the desk keys still being learned.
M.NOTES_IDLE_HINT = "␣gR review · ␣gx open/jump · ␣go list · ␣gc commit"

--- The review key: opens the merged view in a split above the notes window,
--- and focuses it (or focuses the one already open for this proposal).
--- Returns true, or false, why.
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
	local carried, carried_took
	if existing and vim.api.nvim_buf_is_valid(existing.review_buf) then
		if existing.sha == p.sha then
			local win = vim.fn.bufwinid(existing.review_buf)
			if win ~= -1 then
				vim.api.nvim_set_current_win(win)
				return true
			end
		end
		if vim.bo[existing.review_buf].modified then
			-- Unsaved declines would be lost with the old split.
			local choice = M.confirm("The review split has unsaved declines.", "&Save them\n&Discard them\n&Cancel")
			if choice == 1 then
				local saved, why = M.save_review(existing)
				if not saved then
					return false, why
				end
			elseif choice ~= 2 then
				local win = vim.fn.bufwinid(existing.review_buf)
				if win ~= -1 then
					vim.api.nvim_set_current_win(win)
				end
				return false, "kept the review split: it has unsaved declines"
			end
		end
		-- In its own windows, unless nothing would show here: then the
		-- review goes on below as a fresh one, which moves to the other
		-- file or says there is nothing.
		local win = vim.fn.bufwinid(existing.review_buf)
		vim.bo[existing.review_buf].modified = false -- saved or discarded above
		if win ~= -1 and rebuild(existing, p, true, true) then
			vim.api.nvim_set_current_win(win)
			vim.notify("desk: " .. M.STALE_RELOADED, vim.log.levels.INFO)
			return true
		end
		carried, carried_took = existing.return_to, existing.took_into
		close_session(existing, true)
	end

	local ours = buf_lines(notes_buf)
	local r, err = proposal.reviewable(repo, p, file, ours)
	if not r then
		return false, err
	end
	local merged, shown, conflicts = r.merged, r.shown, r.conflicts
	local base = proposal.base_lines(repo, p, file)
	if next(shown) == nil then
		local elsewhere = M.pending_elsewhere(repo, file, p)
		if #elsewhere == 0 then
			return false, "no suggestions to review"
		end
		vim.notify(
			string.format("desk: nothing to review in %s; %d in %s", file, elsewhere[1].count, elsewhere[1].file),
			vim.log.levels.INFO
		)
		return M.move_review(notes_buf, elsewhere[1].file)
	end

	local notes_win = vim.fn.bufwinid(notes_buf)
	if notes_win == -1 then
		notes_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(notes_win, notes_buf)
	end
	vim.api.nvim_set_current_win(notes_win)
	vim.cmd("aboveleft split")
	local review_win = vim.api.nvim_get_current_win()
	local review_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[review_buf].buftype = "acwrite"
	vim.bo[review_buf].bufhidden = "wipe"
	vim.bo[review_buf].swapfile = false
	vim.bo[review_buf].modeline = false
	vim.api.nvim_buf_set_name(review_buf, "desk-review://" .. file)
	vim.bo[review_buf].filetype = vim.bo[notes_buf].filetype
	-- Loaded outside the undo history, so `u` in the split never blanks it.
	local undolevels = vim.bo[review_buf].undolevels
	vim.bo[review_buf].undolevels = -1
	vim.api.nvim_buf_set_lines(review_buf, 0, -1, false, merged)
	vim.bo[review_buf].undolevels = undolevels
	vim.bo[review_buf].modified = false
	vim.api.nvim_win_set_buf(review_win, review_buf)

	local s = {
		notes_buf = notes_buf,
		review_buf = review_buf,
		repo = repo,
		file = file,
		sha = p.sha,
		shown = shown,
		conflicts = conflicts,
		merged = merged,
		base = base,
		takes = {},
		return_to = carried,
		took_into = carried_took,
	}
	sessions[notes_buf] = s
	M.recount_saved(s)
	M.place_marks(s, ours)
	M.place_del_marks(s)

	s.notes_wrap = wrap_opts(notes_win)
	vim.api.nvim_win_call(review_win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(notes_win, function()
		vim.cmd("diffthis")
	end)
	set_wrap_opts(review_win, SOFT_WRAP)
	set_wrap_opts(notes_win, SOFT_WRAP)
	install_colours()
	set_winhl(review_win, M.REVIEW_WINHL)
	set_winhl(notes_win, M.NOTES_WINHL)
	s.notes_win = notes_win
	watch_notes_window(s, notes_win)

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = vim.api.nvim_create_augroup("desk_taken_" .. notes_buf, { clear = true }),
		buffer = notes_buf,
		callback = function()
			M.flush_taken(notes_buf)
			M.refresh_status_line(notes_buf, true)
		end,
	})

	local group = vim.api.nvim_create_augroup("desk_review_" .. review_buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = review_buf,
		callback = function()
			local ok, n_or_err = M.save_review(s)
			if not ok then
				vim.notify("desk: " .. tostring(n_or_err), vim.log.levels.WARN)
			else
				if n_or_err > 0 then
					vim.notify("desk: declined " .. n_or_err .. " suggestion(s)", vim.log.levels.INFO)
				end
				-- `:wq` is this save and a quit in one command: the quit
				-- (QuitPre, below) finds the mark before the next tick clears
				-- it, which a `:q` typed later never does.
				s.saving_quit = true
				vim.schedule(function()
					s.saving_quit = nil
				end)
			end
			M.refresh_overview(s)
			M.refresh_status_line(notes_buf, true)
		end,
	})
	vim.api.nvim_create_autocmd("QuitPre", {
		group = group,
		buffer = review_buf,
		nested = true, -- the notes' own write autocmds run
		callback = function()
			if s.saving_quit and sessions[notes_buf] == s then
				s.saving_quit = nil
				write_taken_notes(s)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "WinEnter", "FocusGained" }, {
		group = group,
		buffer = review_buf,
		callback = function()
			M.ensure_current(s)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinEnter", "FocusGained" }, {
		buffer = notes_buf,
		callback = function()
			if sessions[notes_buf] ~= s then
				return true -- this review is over: drop the autocmd
			end
			M.ensure_current(s)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = review_buf,
		callback = function()
			if sessions[notes_buf] == s then
				sessions[notes_buf] = nil
			end
			if sessions[notes_buf] == nil then
				pcall(vim.api.nvim_del_augroup_by_name, "desk_review_notes_" .. notes_buf)
			end
			tidy_notes_windows(s)
			-- The window layout can't change while a buffer is being wiped.
			vim.schedule(function()
				return_home(s)
			end)
		end,
	})
	-- Plain `do` on the last line does nothing when a suggestion is appended
	-- after it and another hunk precedes it; the range form works, so fall
	-- back to it when `do` changed nothing there.
	vim.keymap.set("n", "do", function()
		local fresh, stale = M.ensure_current(s, true)
		if not fresh then
			return report(false, stale)
		end
		local tick = vim.api.nvim_buf_get_changedtick(notes_buf)
		local pre = buf_lines(notes_buf)
		local count = vim.v.count > 0 and tostring(vim.v.count) or ""
		pcall(vim.cmd, "normal! " .. count .. "do")
		local line = vim.api.nvim_win_get_cursor(0)[1]
		if vim.api.nvim_buf_get_changedtick(notes_buf) == tick and count == "" and line == vim.api.nvim_buf_line_count(notes_buf) then
			pcall(vim.cmd, string.format("%d,%ddiffget", line, line + 1))
		end
		complete_halves(s, pre)
		note_takes(s, pre)
		M.refresh_status_line(notes_buf)
	end, { buffer = notes_buf, desc = "Take the hunk under the cursor (also at the end of the file)" })
	-- The same take from the review side. Plain `dp` takes a removal (lines
	-- only the notes have, grey filler in the split) from the line just below
	-- the filler, and misses it from the line just above, which is the only
	-- one there at the end of the file. The range form is invalid past the
	-- split's end, so from the line above the removal is obtained from the
	-- notes side instead.
	vim.keymap.set("n", "dp", function()
		local fresh, stale = M.ensure_current(s, true)
		if not fresh then
			return report(false, stale)
		end
		local tick = vim.api.nvim_buf_get_changedtick(notes_buf)
		local t = begin_take(s)
		local pre = buf_lines(notes_buf)
		local count = vim.v.count > 0 and tostring(vim.v.count) or ""
		pcall(vim.cmd, "normal! " .. count .. "dp")
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local nwin = vim.fn.bufwinid(notes_buf)
		if vim.api.nvim_buf_get_changedtick(notes_buf) == tick and count == "" and nwin ~= -1 then
			for _, h in ipairs(diff_indices(pre, buf_lines(review_buf))) do
				if h[4] == 0 and h[3] == line and h[2] > 0 then
					vim.api.nvim_win_call(nwin, function()
						pcall(vim.cmd, string.format("%d,%ddiffget", h[1], h[1] + h[2] - 1))
					end)
				end
			end
		end
		complete_halves(s, pre)
		note_takes(s, pre)
		end_take(s, t)
		M.refresh_status_line(notes_buf)
	end, { buffer = review_buf, desc = "Take the hunk under the cursor into your notes (also at the end of the file)" })
	vim.keymap.set("n", "u", function()
		local ok, why = M.undo(review_buf)
		if not ok then
			vim.notify("desk: " .. tostring(why), vim.log.levels.WARN)
		end
	end, { buffer = review_buf, desc = "Undo the latest take or decline" })
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
	vim.keymap.set("n", "<leader>gc", function()
		report(M.commit_from_review(review_buf))
	end, { buffer = review_buf, desc = "Save the declines, then commit your notes" })
	vim.keymap.set("n", "<leader>gR", function()
		report(M.switch_review(review_buf))
	end, { buffer = review_buf, desc = "Move the review to the other file once this one has none left" })
	for _, b in ipairs({ review_buf, notes_buf }) do
		vim.keymap.set("n", "<leader>gq", function()
			report(M.close_review(s))
		end, { buffer = b, desc = "End the review (asks about unsaved declines)" })
	end
	map_next_change(review_buf)
	map_next_change(notes_buf)
	-- The split shows the notes' text, so the hotkey works there too;
	-- without it ␣gx falls through to nvim's own gx, which hands a session
	-- name to the system opener.
	require("desk.hotkey").attach(review_buf, tokens.load() or { tokens = {} })
	for lhs, verb in pairs({ ["<leader>gA"] = "take", ["<leader>gD"] = "decline" }) do
		vim.keymap.set("n", lhs, function()
			report(M.notes_act(notes_buf, verb))
		end, { buffer = notes_buf, desc = verb == "take" and "Take just the suggestion in this hunk" or "Decline the suggestion in this hunk (u undoes; :w in the split records)" })
	end
	vim.keymap.set("n", "u", function()
		M.notes_undo(notes_buf)
	end, { buffer = notes_buf, desc = "Undo the latest take or decline made here, else plain undo" })

	-- Edits by hand move the count too; the keys refresh it themselves.
	vim.api.nvim_create_autocmd("TextChanged", {
		group = group,
		buffer = review_buf,
		callback = function()
			M.refresh_status_line(notes_buf)
		end,
	})
	vim.api.nvim_create_autocmd("TextChanged", {
		buffer = notes_buf,
		callback = function()
			if sessions[notes_buf] ~= s then
				return true -- this review is over: drop the autocmd
			end
			M.refresh_status_line(notes_buf)
		end,
	})

	M.refresh_status_line(notes_buf)
	M.refresh_overview(s)
	vim.api.nvim_set_current_win(review_win)
	first_hunk(review_win)
	say_elsewhere(repo, file, p)
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

--- Puts an extmark over each shown adding suggestion's lines in the review
--- buffer — the occurrence that sits in a diff hunk against `ours`.
function M.place_marks(s, ours)
	s.marks = {}
	local review_lines = buf_lines(s.review_buf)
	local hunks = vim.diff(snippet.join_lines(ours, true), snippet.join_lines(review_lines, true), { result_type = "indices" })
	for _, item in pairs(s.shown) do
		local after = snippet.split_lines(item.after)
		if #after > 0 then
			for _, pos in ipairs(find_all(review_lines, after)) do
				-- Any of its lines in a hunk: an `after` with a blank line at
				-- its edge can have that line matched to one of the notes',
				-- so the hunk starts below its first line.
				local inside = false
				for _, h in ipairs(hunks) do
					inside = inside or (h[4] > 0 and pos <= h[3] + h[4] - 1 and pos + #after - 1 >= h[3])
				end
				if inside then
					s.marks[item.id] = vim.api.nvim_buf_set_extmark(s.review_buf, MARK_NS, pos - 1, 0, {
						end_row = pos - 1 + #after,
						end_col = 0,
						right_gravity = false,
						end_right_gravity = false,
					})
					break
				end
			end
		end
	end
end

-- The first row of the occurrence of `item.before` the proposal anchored,
-- in `lines`: the base text's anchored occurrence carried across the user's edits,
-- else the anchor's own first occurrence. nil if it is not there.
local function anchored_start(s, item, lines)
	local before = snippet.split_lines(item.before)
	if #before == 0 then
		return nil
	end
	local leave = block.parse_target(item.target)
	if not (leave and leave.kind == "at") then
		return nil
	end
	if s.base then
		local at = block.find_anchor(s.base, leave, before)
		if at and snippet.lines_match_at(s.base, at + 1, before) then
			local hunks = diff_indices(s.base, lines)
			local row = map_row(hunks, at + 1, false)
			local last = map_row(hunks, at + #before, false)
			if last - row == #before - 1 and snippet.lines_match_at(lines, row, before) then
				return row
			end
		end
	end
	local at = block.find_anchor(lines, leave, before)
	if at and snippet.lines_match_at(lines, at + 1, before) then
		return at + 1
	end
end

-- Whether `item` removes its `before` (rather than only adding lines or
-- rewriting them in place at its own add range).
local function leaves_before(item)
	return #snippet.split_lines(item.before) > 0 and item.kind ~= "edit"
end

--- Puts a zero-width extmark at each removing suggestion's deletion point
--- in the review buffer: the row after which its `before` lines would sit.
function M.place_del_marks(s)
	s.dels = {}
	if not s.base then
		return
	end
	local review_lines = buf_lines(s.review_buf)
	local hunks = diff_indices(s.base, review_lines)
	for _, item in pairs(s.shown) do
		if leaves_before(item) then
			local leave = block.parse_target(item.target)
			local before = snippet.split_lines(item.before)
			local at = leave and leave.kind == "at" and block.find_anchor(s.base, leave, before)
			if at and snippet.lines_match_at(s.base, at + 1, before) then
				local row = math.min(map_row(hunks, at, false), #review_lines)
				s.dels[item.id] = vim.api.nvim_buf_set_extmark(s.review_buf, MARK_NS, row, 0, { right_gravity = false })
			end
		end
	end
end

local function del_row(s, item)
	local id = s.dels and s.dels[item.id]
	if not id then
		return nil
	end
	local m = vim.api.nvim_buf_get_extmark_by_id(s.review_buf, MARK_NS, id, {})
	return m and m[1]
end

--- The suggestion the cursor line `line` of the review buffer belongs to,
--- and how: `add` (inside its own lines), or `del` (next to the point where
--- it deletes lines — the line below the point, else the line above it
--- unless an adding suggestion owns that one).
function M.item_at(s, line)
	local first, _, item = M.item_range(s, line)
	if first then
		return item, "add"
	end
	local total = vim.api.nvim_buf_line_count(s.review_buf)
	for _, cand in pairs(s.shown) do
		local row = del_row(s, cand)
		if row and math.max(1, math.min(row + 1, total)) == line then
			return cand, "del"
		end
	end
	for _, cand in pairs(s.shown) do
		local row = del_row(s, cand)
		if row and row >= 1 and row == line then
			return cand, "del"
		end
	end
end

-- A move or merge: it takes lines away in one place and puts them in
-- another, so it shows as two hunks, and every take or decline acts on both.
local function two_place(item)
	return item.kind == "move" or item.kind == "merge"
end

-- The review-buffer rows of `item`'s added lines: its mark, else an
-- occurrence of its `after` that a hunk against `notes` overlaps.
local function landing_range(s, item, notes)
	local first, last = mark_range(s, item)
	if first then
		return first, last
	end
	local after = snippet.split_lines(item.after)
	if #after == 0 then
		return nil
	end
	local review_lines = buf_lines(s.review_buf)
	local hunks = diff_indices(notes or buf_lines(s.notes_buf), review_lines)
	for _, pos in ipairs(find_all(review_lines, after)) do
		for _, h in ipairs(hunks) do
			if h[4] > 0 and pos <= h[3] + h[4] - 1 and pos + #after - 1 >= h[3] then
				return pos, pos + #after - 1
			end
		end
	end
end

-- Replaces lines `first`+1..`last` of the notes with `repl`. Changes made
-- within one key press are one undo step, so one `u` takes a take back.
local function set_notes(s, first, last, repl)
	vim.api.nvim_buf_set_lines(s.notes_buf, first, last, false, repl)
end

-- Makes the notes match the review across hunk `h` of (notes -> review),
-- as `dp` there does.
local function take_hunk(s, h, review_lines)
	local first = h[2] > 0 and h[1] - 1 or h[1]
	set_notes(s, first, first + h[2], vim.list_slice(review_lines, h[3], h[3] + h[4] - 1))
end

-- Takes the hunk holding a move's added lines, or the one holding its
-- removal, into the notes. Returns whether there was one.
local function take_landing(s, item)
	local notes, review_lines = buf_lines(s.notes_buf), buf_lines(s.review_buf)
	local first, last = landing_range(s, item, notes)
	if not first then
		return false
	end
	for _, h in ipairs(diff_indices(notes, review_lines)) do
		if h[4] > 0 and first <= h[3] + h[4] - 1 and last >= h[3] then
			take_hunk(s, h, review_lines)
			return true
		end
	end
	return false
end

local function take_removal(s, item)
	local notes, review_lines = buf_lines(s.notes_buf), buf_lines(s.review_buf)
	local start = anchored_start(s, item, notes)
	if not start then
		return false
	end
	local stop = start + #snippet.split_lines(item.before) - 1
	for _, h in ipairs(diff_indices(notes, review_lines)) do
		if h[2] > 0 and start <= h[1] + h[2] - 1 and stop >= h[1] then
			take_hunk(s, h, review_lines)
			return true
		end
	end
	return false
end

-- Takes a whole move or merge as the pass would apply it to the notes
-- now: both places, blank lines fitted as the proposal fits them, and
-- nothing of a neighbouring suggestion.
local function take_whole(s, item)
	local notes = buf_lines(s.notes_buf)
	local new, results = apply.apply_file(notes, { item })
	if results[item.id] ~= "applied" then
		return false
	end
	local hunks = diff_indices(notes, new)
	for i = #hunks, 1, -1 do
		local h = hunks[i]
		local first = h[2] > 0 and h[1] - 1 or h[1]
		set_notes(s, first, first + h[2], vim.list_slice(new, h[3], h[3] + h[4] - 1))
	end
	return #hunks > 0
end

-- Where a move's lines left the notes, going from `pre` to `now`: the line
-- that now stands in their place.
local function removed_line(pre, now)
	for _, h in ipairs(diff_indices(pre, now)) do
		if h[2] > 0 and h[4] == 0 then
			return math.max(1, math.min(h[3] + 1, #now))
		end
	end
	for _, h in ipairs(diff_indices(pre, now)) do
		if h[2] > 0 then
			return math.max(1, h[3])
		end
	end
	return 1
end

local function landing_label(item)
	local _, land = block.parse_target(item.target)
	if not land or land.kind == "top" or not land.quote then
		return "on top"
	end
	local q = vim.trim(land.quote)
	if vim.fn.strchars(q) > 40 then
		q = vim.fn.strcharpart(q, 0, 39) .. "…"
	end
	return (land.kind == "after" and "after " or "under ") .. q
end

-- The one line saying a take of one place took the other too. `side` is
-- the place the key acted on, nil when it named neither (the overview).
local function say_whole(item, side, line)
	local what = "desk: took the whole " .. item.kind .. ": "
	local msg
	if side == "removal" then
		msg = what .. "removed here, added " .. landing_label(item)
	elseif side == "landing" then
		msg = what .. "added here, removed from line " .. line
	else
		msg = what .. "removed from line " .. line .. ", added " .. landing_label(item)
	end
	vim.notify(msg, vim.log.levels.INFO)
end

-- After a hunk take (`dp`, `do`) that went from `pre` to the notes now:
-- a move or merge just taken in one place only is taken in the other
-- too.
complete_halves = function(s, pre)
	for _, item in pairs(s.shown) do
		if two_place(item) then
			local now = buf_lines(s.notes_buf)
			local landed, removed = proposal.proposed_in(item, now, s.base), proposal.removal_done(item, now, s.base)
			if removed and not landed and not proposal.removal_done(item, pre, s.base) then
				if take_landing(s, item) then
					say_whole(item, "removal")
				end
			elseif landed and not removed and not proposal.proposed_in(item, pre, s.base) then
				if take_removal(s, item) then
					say_whole(item, "landing", removed_line(now, buf_lines(s.notes_buf)))
				end
			end
		end
	end
end

-- Declines `item` in the review buffer: its added lines go (an edit's
-- `before` returns in their place) and its deleted lines come back — an
-- ordinary edit, so `u` undoes it. A move that took a blank line along
-- brings it back too, so its old place reads as the notes do.
local function decline_item(s, item)
	local buf = s.review_buf
	local before = snippet.split_lines(item.before)
	local changed = false
	local first, last
	if two_place(item) then
		first, last = landing_range(s, item)
	else
		first, last = mark_range(s, item)
	end
	if first then
		vim.api.nvim_buf_set_lines(buf, first - 1, last, false, item.kind == "edit" and before or {})
		changed = true
	end
	-- A move whose removal is already in the notes, by hand or by an older
	-- take: declining it keeps the notes as they are, so only its landing goes.
	local half = two_place(item) and proposal.removal_done(item, buf_lines(s.notes_buf), s.base)
	if leaves_before(item) and not half then
		local row = del_row(s, item)
		if row then
			local restore = before
			local leave = block.parse_target(item.target)
			local at = item.kind == "move" and s.base and leave and leave.kind == "at" and block.find_anchor(s.base, leave, before)
			local blank = at and apply.bounding_blank(s.base, at + 1, at + #before)
			local review_lines = buf_lines(buf)
			local function is_blank(l)
				return l ~= nil and l:match("^%s*$") ~= nil
			end
			if blank and blank == at + #before + 1 and not is_blank(review_lines[row + 1]) then
				restore = vim.list_extend(vim.deepcopy(before), { "" })
			elseif blank and blank == at and not is_blank(review_lines[row]) then
				restore = vim.list_extend({ "" }, before)
			end
			vim.api.nvim_buf_set_lines(buf, row, row, false, restore)
			changed = true
		end
	end
	return changed
end

-- Takes `item` into the user's notes buffer: its lines go in at the place the
-- review shows them, its deleted lines go out of their anchored occurrence.
-- A move or merge is taken in both places; one already taken in one place
-- gets the other. The second result is whether both went in at once.
local function take_item(s, item)
	local nbuf = s.notes_buf
	local notes = buf_lines(nbuf)
	if two_place(item) then
		local landed, removed = proposal.proposed_in(item, notes, s.base), proposal.removal_done(item, notes, s.base)
		if not landed and not removed then
			return take_whole(s, item), true
		elseif removed and not landed then
			return take_landing(s, item)
		elseif landed and not removed then
			return take_removal(s, item)
		end
		return false
	end
	local before = snippet.split_lines(item.before)
	local after = snippet.split_lines(item.after)
	local changed = false
	-- The suggestion as the split shows it now, so an edit made there first
	-- is what lands.
	local first, _, shown = mark_range(s, item)
	if shown and #shown > 0 then
		after = shown
	end
	local start = #before > 0 and anchored_start(s, item, notes)
	if #before > 0 and not start then
		return false
	end
	if first and #after > 0 then
		if item.kind == "edit" then
			vim.api.nvim_buf_set_lines(nbuf, start - 1, start - 1 + #before, false, after)
			changed = true
			start = nil
		else
			local row = map_row(diff_indices(notes, buf_lines(s.review_buf)), first - 1, true)
			vim.api.nvim_buf_set_lines(nbuf, row, row, false, after)
			changed = true
			if start and row < start then
				start = start + #after
			end
		end
	end
	if start and leaves_before(item) then
		vim.api.nvim_buf_set_lines(nbuf, start - 1, start - 1 + #before, false, {})
		changed = true
	end
	return changed
end

--- The review-buffer line range of the suggestion whose lines contain
--- `line`, or nil (a removal has no lines of its own there, and plain text
--- of the user's own is no suggestion). Adjacent suggestions form ONE diff hunk, so
--- acting on a single suggestion means acting on this range, not the hunk.
function M.item_range(s, line)
	for _, item in pairs(s.shown) do
		local first, last = mark_range(s, item)
		if first and line >= first and line <= last then
			return first, last, item
		end
	end
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

-- Runs `diffget` (obtain from the user's notes) or `diffput` (hand to the user's notes)
-- for the suggestion under the cursor in the review split, or for the whole
-- hunk there when the cursor isn't on a suggestion's own lines. Returns
-- whether either buffer changed.
local function diff_act(s, verb)
	local win = vim.fn.bufwinid(s.review_buf)
	if win == -1 then
		return false, "review buffer has no window"
	end
	local before_review, before_notes = buf_lines(s.review_buf), buf_lines(s.notes_buf)
	local acted
	vim.api.nvim_win_call(win, function()
		local first, last, item = M.item_range(s, vim.api.nvim_win_get_cursor(win)[1])
		acted = item
		if first then
			pcall(vim.cmd, string.format("%d,%d%s", first, last, verb))
		else
			pcall(vim.cmd, "normal! d" .. (verb == "diffget" and "o" or "p"))
		end
	end)
	if vim.deep_equal(before_review, buf_lines(s.review_buf)) and vim.deep_equal(before_notes, buf_lines(s.notes_buf)) then
		return false, "no suggestion under the cursor"
	end
	if verb == "diffput" then
		complete_halves(s, before_notes)
		note_takes(s, before_notes, acted)
	end
	return true
end

-- Declines or takes `item`, as the decline and take-one keys do. `side`
-- is the place of a move or merge the key acted on ("landing" or
-- "removal"), nil when it named neither.
local function act_on(s, item, verb, side)
	if verb == "decline" then
		if not decline_item(s, item) then
			return false, "nothing to decline here"
		end
		return true
	end
	local pre = buf_lines(s.notes_buf)
	local ok, whole = take_item(s, item)
	if not ok then
		return false, "could not take this suggestion: its place in your notes has changed"
	end
	if whole then
		say_whole(item, side, removed_line(pre, buf_lines(s.notes_buf)))
	end
	note_takes(s, pre, item)
	return true
end

-- Declines or takes the one suggestion under the cursor. Returns nil when
-- the cursor is on no known suggestion (the caller falls back to the hunk).
local function act_on_item(s, verb)
	local win = vim.fn.bufwinid(s.review_buf)
	if win == -1 then
		return false, "review buffer has no window"
	end
	local item, how = M.item_at(s, vim.api.nvim_win_get_cursor(win)[1])
	if not item then
		return nil
	end
	return act_on(s, item, verb, how == "add" and "landing" or "removal")
end

--- The decline key: makes the suggestion under the cursor in the review
--- split equal the user's text (it obtains the user's side), so its diff disappears. An
--- ordinary edit — `u` undoes it; nothing is recorded until the review split
--- is saved.
function M.decline(review_buf)
	local s = session_for_review_buf(review_buf)
	if not s then
		return false, "not a desk review buffer"
	end
	local fresh, stale = M.ensure_current(s, true)
	if not fresh then
		return false, stale
	end
	local ok, why = act_on_item(s, "decline")
	if ok == nil then
		ok, why = diff_act(s, "diffget")
	end
	if ok then
		M.refresh_overview(s)
		M.refresh_status_line(s.notes_buf)
	end
	return ok, why
end

--- Takes the suggestion under the cursor into the user's notes buffer (just that
--- one — `do` in the user's window takes the whole hunk, which can be several
--- adjacent suggestions). The user's buffer stays unsaved until the user commits.
function M.take(review_buf)
	local s = session_for_review_buf(review_buf)
	if not s then
		return false, "not a desk review buffer"
	end
	local fresh, stale = M.ensure_current(s, true)
	if not fresh then
		return false, stale
	end
	local t = begin_take(s)
	local ok, why = act_on_item(s, "take")
	if ok == nil then
		ok, why = diff_act(s, "diffput")
	end
	if ok then
		end_take(s, t)
		M.refresh_overview(s)
		M.refresh_status_line(s.notes_buf)
	end
	return ok, why
end

--- `u` in the review split: undoes the latest take made from the split in
--- the notes buffer (and forgets it as a pending take), or, when the split's
--- own latest edit (a decline) came after it, undoes that as plain `u` does.
function M.undo(review_buf)
	local s = session_for_review_buf(review_buf)
	local t = s and s.takes[#s.takes]
	if not (t and undo_seq(review_buf) == t.review_seq) then
		local count = vim.v.count > 0 and tostring(vim.v.count) or ""
		vim.api.nvim_buf_call(review_buf, function()
			vim.cmd("normal! " .. count .. "u")
		end)
		if s then
			M.refresh_overview(s)
			M.refresh_status_line(s.notes_buf)
		end
		return true
	end
	table.remove(s.takes)
	if not vim.api.nvim_buf_is_valid(s.notes_buf) or undo_seq(s.notes_buf) ~= t.notes_post then
		return false, "your notes changed after that take: undo it in the notes window"
	end
	vim.api.nvim_buf_call(s.notes_buf, function()
		vim.cmd("silent undo " .. t.notes_pre)
	end)
	local pend = pending_taken[s.notes_buf]
	for _, id in ipairs(t.ids) do
		if pend and pend.ids[id] and pend.ids[id].seq == t.notes_post then
			pend.ids[id] = nil
		end
	end
	vim.api.nvim_buf_call(review_buf, function()
		vim.cmd("diffupdate")
	end)
	M.refresh_overview(s)
	M.refresh_status_line(s.notes_buf)
	return true
end

--- The review key in the split: once this file has no suggestion left,
--- moves the review to the other file that still has some.
function M.switch_review(review_buf)
	local s = session_for_review_buf(review_buf)
	if not s then
		return false, "not a desk review buffer"
	end
	-- Over a proposal that has moved on the key reloads first, asking about
	-- unsaved declines as the notes' own review key does.
	if git.ref_sha(s.repo, M.PROPOSAL_REF) ~= s.sha then
		return M.open_review(s.notes_buf)
	end
	local other = M.pending_elsewhere(s.repo, s.file)[1]
	local left = M.left(s)
	if not other then
		return false, left > 0 and "nothing waits in the other files" or "no suggestions left"
	end
	if left > 0 then
		return false, string.format("%d left here first; then ␣gR moves to %s", left, other.file)
	end
	return M.move_review(s.notes_buf, other.file)
end

--- Ends the review `s` as `:q` in its split does, and closes the overview
--- when it is this review's list: unsaved declines ask first, and
--- cancelling keeps everything open. Leaves the user in their notes.
--- Returns true, or false, why.
function M.close_review(s)
	if not (s and sessions[s.notes_buf] == s and vim.api.nvim_buf_is_valid(s.review_buf)) then
		return false, "no review open"
	end
	local ok, why = settle_declines(s)
	if not ok then
		return false, why
	end
	write_taken_notes(s)
	local info = vim.fn.getqflist({ title = 0, context = 0 })
	local ctx = type(info.context) == "table" and info.context or {}
	if info.title == M.OVERVIEW_TITLE and (ctx.desk_review_buf == s.review_buf or not session_for_review_buf(ctx.desk_review_buf or -1)) then
		vim.cmd("cclose")
	end
	local review_win = vim.fn.bufwinid(s.review_buf)
	local notes_win = vim.fn.bufwinid(s.notes_buf)
	if notes_win == -1 and review_win ~= -1 then
		vim.api.nvim_win_set_buf(review_win, s.notes_buf)
		notes_win = review_win
	end
	close_session(s)
	if notes_win ~= -1 and vim.api.nvim_win_is_valid(notes_win) then
		vim.api.nvim_set_current_win(notes_win)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- The same keys from the notes window. The cursor there can't sit on a
-- suggestion's own lines (they are filler on that side), so it names a
-- hunk: the one over the cursor line, else the filler just above it (where
-- `do` acts), else just below. Of several adjacent suggestions in that hunk
-- the topmost is acted on, so pressing again walks down them. `u` there
-- undoes the latest take or decline made from that window, then is plain
-- undo, as a `do` take is undone there.
-- ---------------------------------------------------------------------------

--- The suggestion the notes window's cursor line `line` acts on, and how
--- many remain in its hunk; nil when the line is in no hunk.
function M.item_in_notes_hunk(s, line)
	local hunks = diff_indices(buf_lines(s.notes_buf), buf_lines(s.review_buf))
	local hunk
	for _, want in ipairs({ "over", "above", "below" }) do
		for _, h in ipairs(hunks) do
			if
				(want == "over" and h[2] > 0 and line >= h[1] and line <= h[1] + h[2] - 1)
				or (want == "above" and h[2] == 0 and h[1] == line - 1)
				or (want == "below" and h[2] == 0 and h[1] == line)
			then
				hunk = hunk or h
			end
		end
	end
	if not hunk then
		return nil, 0
	end
	-- The hunk's review lines, or for a pure removal the point after h[3]
	-- (a deletion mark's row counts the lines above it).
	local lo, hi = hunk[3], hunk[3] + hunk[4] - 1
	if hunk[4] == 0 then
		lo, hi = hunk[3] + 1, hunk[3]
	end
	local found = {}
	for _, r in ipairs(M.remaining(s)) do
		local first, last = mark_range(s, r.item)
		local row = del_row(s, r.item)
		local pos
		if first and first <= hi and last >= lo then
			pos = first
		elseif row and row >= lo - 1 and row <= hi then
			pos = row + 0.5
		end
		if pos then
			found[#found + 1] = { item = r.item, pos = pos, side = pos % 1 == 0 and "landing" or "removal" }
		end
	end
	table.sort(found, function(a, b)
		if a.pos ~= b.pos then
			return a.pos < b.pos
		end
		return a.item.id < b.item.id
	end)
	return found[1] and found[1].item, #found, found[1] and found[1].side
end

--- `<leader>gA` (`verb` "take") or `<leader>gD` ("decline") in the notes
--- window: acts on the suggestion of the hunk under the cursor as the same
--- key in the split does, recorded the same way. Returns true, or false, why.
function M.notes_act(notes_buf, verb)
	local s = live_session(notes_buf)
	if not s then
		return false, "no review open: ␣gR opens one"
	end
	local fresh, stale = M.ensure_current(s, true)
	if not fresh then
		return false, stale
	end
	local win = vim.fn.bufwinid(notes_buf)
	if win == -1 then
		return false, "your notes are not showing in any window"
	end
	vim.api.nvim_win_call(win, function()
		vim.cmd("diffupdate")
	end)
	local item, n, side = M.item_in_notes_hunk(s, vim.api.nvim_win_get_cursor(win)[1])
	if not item then
		return false, "no suggestion in a hunk here"
	end
	local t = begin_take(s)
	local ok, why = act_on(s, item, verb, side)
	if not ok then
		return false, why
	end
	t.review_post = undo_seq(s.review_buf)
	s.notes_acts = s.notes_acts or {}
	if verb == "take" then
		end_take(s, t, s.notes_acts)
	else
		t.notes_post, t.ids, t.pending = t.notes_pre, {}, nil
		s.notes_acts[#s.notes_acts + 1] = t
	end
	vim.api.nvim_win_call(win, function()
		vim.cmd("diffupdate")
	end)
	if n > 1 then
		vim.notify(string.format("desk: %d more in this hunk", n - 1), vim.log.levels.INFO)
	end
	M.refresh_overview(s)
	M.refresh_status_line(notes_buf)
	return true
end

--- `u` in the notes window: undoes the latest take or decline made from
--- it with `<leader>gA` or `<leader>gD` while nothing has changed in either
--- buffer since, else plain undo.
function M.notes_undo(notes_buf)
	local s = live_session(notes_buf)
	local a = s and s.notes_acts and s.notes_acts[#s.notes_acts]
	if not (a and undo_seq(notes_buf) == a.notes_post and undo_seq(s.review_buf) == a.review_post) then
		local count = vim.v.count > 0 and tostring(vim.v.count) or ""
		vim.api.nvim_buf_call(notes_buf, function()
			vim.cmd("normal! " .. count .. "u")
		end)
		return true
	end
	table.remove(s.notes_acts)
	if a.review_seq ~= a.review_post then
		vim.api.nvim_buf_call(s.review_buf, function()
			vim.cmd("silent undo " .. a.review_seq)
		end)
	end
	if a.notes_pre ~= a.notes_post then
		vim.api.nvim_buf_call(notes_buf, function()
			vim.cmd("silent undo " .. a.notes_pre)
		end)
		local pend = pending_taken[notes_buf]
		for _, id in ipairs(a.ids) do
			if pend and pend.ids[id] and pend.ids[id].seq == a.notes_post then
				pend.ids[id] = nil
			end
		end
	end
	vim.api.nvim_buf_call(notes_buf, function()
		vim.cmd("diffupdate")
	end)
	M.refresh_overview(s)
	M.refresh_status_line(notes_buf)
	return true
end

-- ---------------------------------------------------------------------------
-- Overview: one quickfix entry per remaining hunk
-- ---------------------------------------------------------------------------

-- The title is the list's identity too, and the qf window's status line
-- shows it, so it carries the list's own keys.
M.OVERVIEW_TITLE = "Desk overview: ⏎ jump (other file: switch) · t/dp take · x/gD decline · q close list · Q close review"
M.DECLINED_TITLE = "Desk declined recently"
M.DECLINED_WINDOW_DAYS = 14

--- The suggestions still left as hunks right now: shown at open, still
--- proposed in the review buffer, not yet in the user's notes. Each with the review
--- buffer line (`lnum`, where `dp` takes it) and the line of THE USER'S notes
--- window the hunk aligns with (`notes_lnum`, where `do` takes it), sorted by
--- position.
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
			local lnum, notes_lnum = 1, 1
			local after = snippet.split_lines(item.after)
			if #after > 0 then
				local positions = find_all(review_lines, after)
				lnum = positions[1] or 1
				for _, pos in ipairs(positions) do
					for _, h in ipairs(hunks) do
						if pos <= h[3] + math.max(h[4], 1) - 1 and pos + #after - 1 >= h[3] then
							lnum = pos
							notes_lnum = h[2] > 0 and h[1] or h[1] + 1
						end
					end
				end
			else
				local positions = find_all(notes_lines, snippet.split_lines(item.before))
				for _, pos in ipairs(positions) do
					for _, h in ipairs(hunks) do
						if pos >= h[1] and pos <= h[1] + math.max(h[2], 1) - 1 then
							-- a pure removal sits after review line h[3]; `dp` takes
							-- it from the line below
							lnum = math.max(h[4] == 0 and h[3] + 1 or h[3], 1)
							notes_lnum = pos
						end
					end
				end
			end
			out[#out + 1] = {
				item = item,
				conflict = s.conflicts and s.conflicts[item.id],
				lnum = math.min(lnum, math.max(#review_lines, 1)),
				notes_lnum = math.max(1, math.min(notes_lnum, #notes_lines)),
			}
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

--- An overview entry's text: the headline, prefixed with its file when
--- `other` (an entry in another file than the review's). A headline that
--- already names its file, as a pass may write one, keeps it once.
function M.entry_text(item, conflict, other)
	local text = item.headline or item.id
	local file = item.file
	if file and file ~= "" then
		local prefix = file .. ":"
		if text:sub(1, #prefix) == prefix then
			text = vim.trim(text:sub(#prefix + 1))
		end
	end
	if conflict then
		text = string.format("%s (near your edit at line %d)", text, conflict)
	end
	if other and file then
		text = file .. ": " .. text
	end
	return text
end

local function overview_items(s, repo, file)
	local qf = {}
	if s then
		for _, r in ipairs(M.remaining(s)) do
			local text = M.entry_text(r.item, r.conflict, false)
			qf[#qf + 1] = { bufnr = s.notes_buf, lnum = r.notes_lnum, col = 1, text = text, user_data = { id = r.item.id } }
		end
	end
	for _, o in ipairs(M.pending_elsewhere(repo, file)) do
		local b = vim.fn.bufadd(repo .. "/" .. o.file)
		for _, e in ipairs(o.entries) do
			local text = M.entry_text(e.item, e.conflict, true)
			qf[#qf + 1] = { bufnr = b, lnum = e.lnum, col = 1, text = text, user_data = { file = o.file, id = e.item.id } }
		end
	end
	return qf
end

--- Rebuilds an overview list already open for `s` (after a decline or a save).
--- A list whose own review has ended since it was made (reopened over a new
--- proposal, or moved to the other file and back) is `s`'s now: its entries
--- act on the review that is open, so it follows that one.
function M.refresh_overview(s)
	local info = vim.fn.getqflist({ title = 0, context = 0 })
	if info.title ~= M.OVERVIEW_TITLE then
		return
	end
	local ctx = type(info.context) == "table" and info.context or {}
	local rb = ctx.desk_review_buf
	local stale = not (rb and session_for_review_buf(rb)) and (ctx.desk_repo == nil or ctx.desk_repo == s.repo)
	if rb ~= s.review_buf and not stale then
		return
	end
	vim.fn.setqflist({}, "r", {
		title = M.OVERVIEW_TITLE,
		items = overview_items(s, s.repo, s.file),
		context = { desk_review_buf = s.review_buf, desk_repo = s.repo },
	})
end

--- The overview key: opens the review split if needed, then a quickfix list
--- with one headline per remaining hunk.
function M.overview(notes_buf)
	local s = sessions[notes_buf]
	if not s or not vim.api.nvim_buf_is_valid(s.review_buf) then
		local ok, why = M.open_review(notes_buf)
		s = sessions[notes_buf]
		if not ok then
			return false, why
		end
	end
	local repo, file = M.repo_context(notes_buf)
	local items = overview_items(s, repo, file)
	if #items == 0 then
		return false, "no suggestions to review"
	end
	vim.fn.setqflist({}, " ", {
		title = M.OVERVIEW_TITLE,
		items = items,
		context = { desk_review_buf = s and s.review_buf, desk_repo = repo },
	})
	-- Across the very top, above the split, so the list and the suggestion
	-- it shows are both in view. A list open elsewhere moves there.
	vim.cmd("cclose")
	preview = {}
	vim.cmd("topleft copen " .. math.min(#items, 10))
	M.qf_bars()
	M.qf_preview()
	return true
end

-- ---------------------------------------------------------------------------
-- Quickfix handlers: <CR> jumps (overview) and r restores (declined list)
-- ---------------------------------------------------------------------------

local function is_loclist_win(win)
	local info = vim.fn.getwininfo(win)[1]
	return info ~= nil and info.loclist == 1
end

-- What the overview's preview last did: the window it moved, where that
-- window's cursor was before (`origin`) and where the preview left it
-- (`last`), so a jump records the place the user left, not the preview's.
preview = {}

-- Where an overview entry shows: the review split's line of its suggestion,
-- looked up now (takes and edits since the list was made move the lines),
-- else the line of the entry's file where that file shows. nil when
-- neither is in a window.
local function entry_target(entry)
	local s = sessions[entry.bufnr]
	local id = type(entry.user_data) == "table" and entry.user_data.id
	local rw = s and vim.api.nvim_buf_is_valid(s.review_buf) and vim.fn.bufwinid(s.review_buf) or -1
	if rw ~= -1 and id then
		for _, r in ipairs(M.remaining(s)) do
			if r.item.id == id then
				return rw, r.lnum
			end
		end
	end
	local win = vim.fn.bufwinid(entry.bufnr)
	if win ~= -1 then
		return win, entry.lnum
	end
end

--- The overview list's bars, as every review window has them: its title
--- and keys in a winbar above the list, and a plain status line below
--- (the list's name and position) rather than the title again. Any other
--- list in the window gets its own status line back.
function M.qf_bars(win)
	win = win or vim.fn.getqflist({ winid = 0 }).winid
	if not win or win == 0 or not vim.api.nvim_win_is_valid(win) or is_loclist_win(win) then
		return
	end
	if vim.fn.getqflist({ title = 0 }).title == M.OVERVIEW_TITLE then
		if vim.w[win].desk_stl == nil then
			vim.w[win].desk_stl = vim.wo[win].statusline
		end
		vim.wo[win].winbar = (M.OVERVIEW_TITLE:gsub("%%", "%%%%"))
		vim.wo[win].statusline = "%t%=%l/%L "
	elseif vim.w[win].desk_stl ~= nil then
		vim.wo[win].winbar = ""
		vim.wo[win].statusline = vim.w[win].desk_stl
		vim.w[win].desk_stl = nil
	end
end

--- The overview's preview, on every cursor move in the list: the entry's
--- suggestion is scrolled into view with the cursor on it, in the review
--- split, while the cursor stays in the list.
function M.qf_preview()
	local qwin = vim.api.nvim_get_current_win()
	if is_loclist_win(qwin) or vim.fn.getqflist({ title = 0 }).title ~= M.OVERVIEW_TITLE then
		return
	end
	M.qf_bars(qwin)
	-- The list's current entry (QuickFixLine) is the one the cursor is on,
	-- not the first, which otherwise stays marked wherever you are.
	local row = vim.fn.line(".")
	if vim.fn.getqflist({ idx = 0 }).idx ~= row then
		vim.fn.setqflist({}, "a", { idx = row })
	end
	local entry = vim.fn.getqflist()[row]
	if not entry or not entry.bufnr or entry.bufnr == 0 then
		return
	end
	local win, lnum = entry_target(entry)
	if not win or win == qwin then
		return
	end
	local here = vim.api.nvim_win_get_cursor(win)
	if preview.win ~= win or not vim.deep_equal(here, preview.last) then
		preview = { win = win, origin = here }
	end
	lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))))
	vim.api.nvim_win_set_cursor(win, { lnum, 0 })
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zvzz")
	end)
	preview.last = vim.api.nvim_win_get_cursor(win)
end

--- The quickfix `<CR>` handler for every quickfix buffer (installed once,
--- globally): anything that isn't desk's own overview falls through to the
--- ordinary jump. An overview entry jumps into the review split, where the user
--- works, to the suggestion's line (so `dp` there takes it); with no review
--- open, into THE USER'S NOTES window at the line aligned with the hunk. Either
--- way through the jumplist (`m'` first), so Ctrl-O returns to where the user
--- was in that window. An entry in the other file does not jump: the review
--- moves there and previews the entry, and focus stays in the list.
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
		local ctx = vim.fn.getqflist({ context = 0 }).context
		local repo = ctx and ctx.desk_repo
		local file = type(item.user_data) == "table" and item.user_data.file
		if not (repo and file) then
			vim.notify("desk: your notes are not showing in any window", vim.log.levels.WARN)
			return
		end
		-- The other file: the review moves there, or with none open it
		-- opens above, with its own review split above it. Focus stays in
		-- the list, which is rebuilt around the new review, so the user can
		-- keep going down it; the entry is previewed there.
		local qwin = vim.api.nvim_get_current_win()
		local from = ctx.desk_review_buf and session_for_review_buf(ctx.desk_review_buf)
		local b
		if from then
			local ok, why = M.move_review(from.notes_buf, file)
			if not ok then
				vim.notify("desk: " .. tostring(why), vim.log.levels.WARN)
				return
			end
			b = vim.fn.bufnr(repo .. "/" .. file)
		else
			local why
			b, why = open_file_buf(repo, file)
			if not b then
				vim.notify("desk: " .. tostring(why), vim.log.levels.WARN)
				return
			end
			M.open_review(b)
		end
		if vim.api.nvim_win_is_valid(qwin) then
			vim.api.nvim_set_current_win(qwin)
		end
		local ns = sessions[b]
		if ns then
			local id = type(item.user_data) == "table" and item.user_data.id
			local items = overview_items(ns, repo, file)
			vim.fn.setqflist({}, "r", {
				title = M.OVERVIEW_TITLE,
				items = items,
				context = { desk_review_buf = ns.review_buf, desk_repo = repo },
			})
			for i, e in ipairs(items) do
				if id and e.user_data.id == id then
					vim.api.nvim_win_set_cursor(qwin, { i, 0 })
				end
			end
		end
		preview = {}
		M.qf_preview()
		return
	end
	local lnum
	win, lnum = entry_target(item)
	if not win then
		vim.notify("desk: your notes are not showing in any window", vim.log.levels.WARN)
		return
	end
	vim.api.nvim_set_current_win(win)
	if preview.win == win and preview.origin and vim.deep_equal(vim.api.nvim_win_get_cursor(win), preview.last) then
		vim.api.nvim_win_set_cursor(win, preview.origin)
	end
	preview = {}
	vim.cmd("normal! m'")
	vim.cmd("diffupdate")
	vim.api.nvim_win_set_cursor(win, { math.max(lnum, 1), 0 })
end

--- The overview's take and decline keys (`verb` "take" or "decline"): act
--- on the entry's one suggestion as the review split's take-one and decline
--- keys do, recorded the same way and undone with `u` there, while the
--- cursor stays in the list. The split's cursor moves to it, so the change
--- shows. Returns true, or false, why.
function M.qf_act(verb)
	local info = vim.fn.getqflist({ title = 0, items = 0 })
	if info.title ~= M.OVERVIEW_TITLE then
		return false, "not the desk overview"
	end
	local entry = info.items[vim.fn.line(".")]
	local data = entry and type(entry.user_data) == "table" and entry.user_data or {}
	if not data.id then
		return false, "no suggestion on this line"
	end
	if data.file then
		return false, string.format("that one is in %s: ⏎ opens its review", data.file)
	end
	local s = sessions[entry.bufnr]
	if not (s and vim.api.nvim_buf_is_valid(s.review_buf)) then
		return false, "its review is closed: ⏎ opens it"
	end
	local fresh, stale = M.ensure_current(s, true)
	if not fresh then
		return false, stale
	end
	local found
	for _, r in ipairs(M.remaining(s)) do
		if r.item.id == data.id then
			found = r
		end
	end
	if not found then
		return false, "already taken or declined"
	end
	local rw = vim.fn.bufwinid(s.review_buf)
	if rw ~= -1 then
		vim.api.nvim_win_set_cursor(rw, { found.lnum, 0 })
	end
	local t = verb == "take" and begin_take(s)
	local ok, why = act_on(s, found.item, verb)
	if not ok then
		return false, why
	end
	if t then
		end_take(s, t)
	end
	M.refresh_overview(s)
	M.refresh_status_line(s.notes_buf)
	return true
end

--- Entering the overview: the review its list belongs to is checked
--- against the proposal, as entering the review's windows does.
function M.qf_check()
	if is_loclist_win(vim.api.nvim_get_current_win()) or vim.fn.getqflist({ title = 0 }).title ~= M.OVERVIEW_TITLE then
		return
	end
	local ctx = vim.fn.getqflist({ context = 0 }).context
	local s = type(ctx) == "table" and ctx.desk_review_buf and session_for_review_buf(ctx.desk_review_buf)
	if s then
		M.ensure_current(s)
	end
end

--- The overview's `Q`: ends the review the list belongs to, list and
--- split together, as `<leader>gq` does. With no review open it closes
--- the list. Returns true, or false, why.
function M.qf_close_review()
	local ctx = vim.fn.getqflist({ context = 0 }).context
	local s = type(ctx) == "table" and ctx.desk_review_buf and session_for_review_buf(ctx.desk_review_buf)
	if not s then
		local entry = vim.fn.getqflist()[vim.fn.line(".")]
		s = entry and live_session(entry.bufnr)
	end
	if not s then
		vim.cmd("cclose")
		return true
	end
	return M.close_review(s)
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
	M.qf_bars()
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
-- The user's commit key
-- ---------------------------------------------------------------------------

-- A section's name for the commit message: its head line without list,
-- heading or bold markup, a link's URL, a trailing colon or a parenthetical
-- aside, and kept short.
local function section_label(line)
	local t = line:gsub("^#+%s*", ""):gsub("^[-*+]%s+%[.?%]%s*", ""):gsub("^[-*+]%s+", "")
	t = t:gsub("%[([^%]]*)%]%b()", "%1"):gsub("%*%*", "")
	t = vim.trim((t:gsub("%s+%(.*$", ""))):gsub(":$", "")
	if t == "" then
		t = vim.trim(line)
	end
	return t
end

-- A body line of the commit message: one per item, capped at 72 columns
-- rather than wrapped.
local function body_item(text)
	local line = "- " .. text
	if vim.fn.strchars(line) > 72 then
		line = vim.fn.strcharpart(line, 0, 71) .. "…"
	end
	return line
end

-- The section heading at or above `row` of `lines`, or nil at the top
-- (desk.block.is_heading).
local is_heading = block.is_heading

local function section_head(lines, row)
	for i = math.min(row, #lines), 1, -1 do
		if is_heading(lines, i) then
			return lines[i]
		end
	end
end

-- Marks used, in `lines` (a list of { text, used }), the first unused run
-- matching each block of `blocks`.
local function consume(lines, blocks)
	for _, b in ipairs(blocks) do
		for pos = 1, #lines - #b + 1 do
			local hit = #b > 0
			for k = 1, #b do
				hit = hit and not lines[pos + k - 1].used and lines[pos + k - 1].text == b[k]
			end
			if hit then
				for k = 1, #b do
					lines[pos + k - 1].used = true
				end
				break
			end
		end
	end
end

--- The `<leader>gc` commit message for a file going from `head` to `now`
--- with `taken` (the suggestions this commit takes, in proposal order) in
--- it: a subject under 50 columns counting the takes and the sections the
--- user's own edits touched, and a body naming both, one line per item.
--- A section is the heading at or above a changed line (`section_head`),
--- which is also where a session's name heads its notes; lines a taken
--- suggestion brought in or took out are not the user's edits. Returns the
--- message.
-- The sections the user's own edits touched going from `head` to `now`,
-- in order, with `taken` (the suggestions the commit takes) not counted.
local function edited_sections(head, now, taken)
	local afters, befores = {}, {}
	for _, item in ipairs(taken) do
		afters[#afters + 1] = snippet.split_lines(item.after)
		if leaves_before(item) or item.kind == "edit" then
			befores[#befores + 1] = snippet.split_lines(item.before)
		end
	end
	local sections, seen = {}, {}
	for _, h in ipairs(diff_indices(head, now)) do
		local added, removed = {}, {}
		for i = h[3], h[3] + h[4] - 1 do
			added[#added + 1] = { text = now[i], row = i, side = now }
		end
		for i = h[1], h[1] + h[2] - 1 do
			-- A heading changed into another heading is a rename: named once,
			-- by its new name.
			local j = h[3] + math.min(i - h[1], h[4] - 1)
			local renamed = h[4] > 0 and is_heading(head, i) and is_heading(now, j)
			removed[#removed + 1] = { text = head[i], row = i, side = head, used = renamed }
		end
		consume(added, afters)
		consume(removed, befores)
		-- Each line of the user's own is named from its own side, so a
		-- section deleted whole is named as itself.
		for _, l in ipairs(vim.list_extend(added, removed)) do
			if not l.used and l.text:match("%S") then
				local line = section_head(l.side, l.row)
				local name = line and section_label(line) or "top"
				if not seen[name] then
					seen[name] = true
					sections[#sections + 1] = name
				end
			end
		end
	end
	return sections
end

function M.commit_message(head, now, taken)
	return M.commit_message_files({ { head = head, now = now, taken = taken } })
end

--- The message for a commit of several files at once, `changes` a list of
--- { file, head, now, taken } in file order: the subject sums them, and the
--- body names each item's file when there is more than one.
function M.commit_message_files(changes)
	local takes, sections = {}, {}
	local several = #changes > 1
	for _, c in ipairs(changes) do
		for _, item in ipairs(c.taken) do
			local text = M.entry_text(item, nil, false)
			takes[#takes + 1] = several and c.file .. ": " .. text or text
		end
		for _, name in ipairs(edited_sections(c.head, c.now, c.taken)) do
			sections[#sections + 1] = several and c.file .. ": " .. name or name
		end
	end
	local function count(n, one)
		return string.format("%d %s%s", n, one, n == 1 and "" or "s")
	end
	local parts = {}
	if #takes > 0 then
		parts[#parts + 1] = "take " .. count(#takes, "suggestion")
	end
	if #sections > 0 then
		parts[#parts + 1] = "edit " .. count(#sections, "section")
	end
	local subject = #parts > 0 and table.concat(parts, ", ") or "update notes"
	subject = subject:sub(1, 1):upper() .. subject:sub(2)
	local body = {}
	if #takes > 0 then
		body[#body + 1] = "Taken:"
		for _, text in ipairs(takes) do
			body[#body + 1] = body_item(text)
		end
	end
	if #sections > 0 then
		if #body > 0 then
			body[#body + 1] = ""
		end
		body[#body + 1] = "Edited:"
		for _, name in ipairs(sections) do
			body[#body + 1] = body_item(name)
		end
	end
	if #body == 0 then
		return subject
	end
	return subject .. "\n\n" .. table.concat(body, "\n")
end

-- The suggestions a commit of `file` from `head` to `now` takes, in
-- proposal order: the pending takes just recorded (`flushed`, edited or
-- not), and any whose change is in `now` but not in `head`.
local function taken_in_commit(repo, file, head, now, flushed)
	local ids = {}
	for _, item in ipairs(flushed) do
		ids[item.id] = true
	end
	local p = proposal.read(repo)
	if not p then
		return flushed
	end
	local out = {}
	local base = proposal.base_lines(repo, p, file)
	for _, item in ipairs(p.items) do
		if
			item.file == file
			and not item.deferred
			and (ids[item.id] or (proposal.proposed_in(item, now, base) and not proposal.proposed_in(item, head, base)))
		then
			out[#out + 1] = item
			ids[item.id] = nil
		end
	end
	for _, item in ipairs(flushed) do
		if ids[item.id] then
			out[#out + 1] = item
		end
	end
	return out
end

--- The notes files of the instance, as the config's `files` names them
--- (notes.md and reading.md by default).
function M.notes_files()
	local cfg = tokens.load()
	if type(cfg) == "table" and type(cfg.files) == "table" and #cfg.files > 0 then
		return cfg.files
	end
	return { "notes.md", "reading.md" }
end

--- The commit key: saves every open buffer of the notes files and commits
--- each file that has changes, in one commit with a message saying what
--- changed in each (`commit_message_files`), then records any suggestion
--- now in HEAD as taken. A no-op when nothing changed.
function M.commit(bufnr)
	local repo, file = M.repo_context(bufnr)
	if not repo then
		return false, file
	end
	local bufs, flushed = {}, {}
	for _, f in ipairs(M.notes_files()) do
		local b = vim.fn.bufnr(repo .. "/" .. f)
		if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
			bufs[#bufs + 1] = b
			-- Recorded before the save, which would otherwise record them unseen.
			flushed[f] = select(2, M.flush_taken(b))
			if vim.bo[b].modified then
				vim.api.nvim_buf_call(b, function()
					vim.cmd("silent write")
				end)
			end
		end
	end
	local changes, paths = {}, {}
	for _, f in ipairs(M.notes_files()) do
		local _, dirty = git.run(repo, { "status", "--porcelain", "--", f })
		if vim.trim(dirty) ~= "" then
			local head = proposal.lines_at(repo, "HEAD", f)
			local now = vim.fn.filereadable(repo .. "/" .. f) == 1 and vim.fn.readfile(repo .. "/" .. f) or {}
			changes[#changes + 1] = { file = f, head = head, now = now, taken = taken_in_commit(repo, f, head, now, flushed[f] or {}) }
			paths[#paths + 1] = f
		end
	end
	if #paths > 0 then
		local args = vim.list_extend({ "add", "--" }, paths)
		local ok, _, err = git.run(repo, args)
		if ok then
			ok, _, err = git.run(repo, vim.list_extend({ "commit", "-q", "-m", M.commit_message_files(changes), "--" }, paths))
		end
		if not ok then
			return false, "git commit failed: " .. err
		end
	end
	for _, b in ipairs(bufs) do
		M.flush_taken(b)
	end
	local taken = proposal.sync_taken(repo)
	for _, b in ipairs(bufs) do
		M.refresh_status_line(b, true)
	end
	return true, { taken = #taken }
end

--- The commit key in the review split: saves the split (its declines), then
--- commits the notes as the key there does, so the user can commit from
--- where they work.
function M.commit_from_review(review_buf)
	local s = session_for_review_buf(review_buf)
	if not s then
		return false, "not a desk review buffer"
	end
	if vim.bo[review_buf].modified then
		local ok, n_or_err = M.save_review(s)
		if not ok then
			return false, n_or_err
		end
		if n_or_err > 0 then
			vim.notify("desk: declined " .. n_or_err .. " suggestion(s)", vim.log.levels.INFO)
		end
	end
	local ok, res = M.commit(s.notes_buf)
	M.refresh_overview(s)
	return ok, res
end

-- ---------------------------------------------------------------------------
-- Status line: the runner's status.json summary in the notes buffer's winbar.
-- ---------------------------------------------------------------------------

--- How many suggestions still wait in the open review `s`: neither taken
--- (in the notes, or taken and since edited) nor declined (gone from the
--- split), saved or not. The live number both of the review's bars show.
function M.left(s)
	local pend = pending_ids(s.notes_buf)
	local saved = s.taken_saved or {}
	local n = 0
	for _, r in ipairs(M.remaining(s)) do
		if not (pend[r.item.id] or saved[r.item.id]) then
			n = n + 1
		end
	end
	return n
end

--- The recorded count for the open review `s`'s file: what a review of
--- HEAD would show, given the ledger. Kept on the session, since it moves
--- only on a save or a commit and costs git calls to work out.
function M.recount_saved(s)
	local n = 0
	local p = proposal.read(s.repo)
	local r = p and proposal.reviewable(s.repo, p, s.file, proposal.lines_at(s.repo, "HEAD", s.file))
	for _ in pairs(r and r.shown or {}) do
		n = n + 1
	end
	s.saved = n
	s.elsewhere = M.pending_elsewhere(s.repo, s.file, p)[1]
	return n
end

--- The notes buffer's status line. While a review of it is open the
--- proposal's count is that review's, live and recorded (`status.live_count`);
--- otherwise it is the recorded one over every file, which moves only on a
--- save or a commit.
function M.status_line(bufnr, left)
	local opts
	local s = live_session(bufnr)
	if s then
		opts = { left = left or M.left(s), saved = s.saved or M.recount_saved(s) }
	else
		local repo = bufnr and M.repo_context(bufnr)
		if repo then
			opts = { untaken = #proposal.open_items(repo) }
		end
	end
	return status.summary(status.read(), opts)
end

-- Text for a winbar, which reads `%` as statusline syntax.
local function bar_text(text)
	return (text:gsub("%%", "%%%%"))
end

--- The bars over a notes buffer's windows and, while a review is open, over
--- its split: the notes window's keys and the status line below, the review
--- keys and the count above. `recount` after a save or a commit, which
--- moves the recorded count.
function M.refresh_status_line(bufnr, recount)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local s = live_session(bufnr)
	if s and recount then
		M.recount_saved(s)
	end
	local left = s and M.left(s)
	local line = (s and M.NOTES_KEY_HINT or M.NOTES_IDLE_HINT) .. "%=" .. bar_text(M.status_line(bufnr, left))
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		vim.wo[win].winbar = line
	end
	if s then
		local rw = vim.fn.bufwinid(s.review_buf)
		if rw ~= -1 then
			local other = s.elsewhere and string.format("%s: %d more ␣gR · ", s.elsewhere.file, s.elsewhere.count) or ""
			vim.wo[rw].winbar = M.KEY_HINT .. "%=" .. bar_text(other .. status.live_count(left, s.saved))
		end
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
--- exist only while a review is open, in both of its windows.
M.KEYMAPS = {
	{ mode = "n", lhs = "<leader>gR", desc = "Review: open the proposal as a diff against your notes" },
	{ mode = "n", lhs = "<leader>gc", desc = "Commit your notes (records taken suggestions)" },
	{ mode = "n", lhs = "<leader>go", desc = "Overview: remaining suggestions" },
	{ mode = "n", lhs = "<leader>gd", desc = "Declined recently: list, restorable with r" },
	{ mode = "n", lhs = "<leader>gD", desc = "Decline the suggestion under the cursor (while a review is open)" },
	{ mode = "n", lhs = "<leader>gA", desc = "Take just the suggestion under the cursor (while a review is open)" },
}

local qf_autocmd_installed = false

local function install_qf_autocmd()
	if qf_autocmd_installed then
		return
	end
	qf_autocmd_installed = true
	-- A :grep or :make into the overview's window gives it its own bars back.
	vim.api.nvim_create_autocmd("QuickFixCmdPost", {
		callback = function()
			M.qf_bars()
		end,
	})
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "qf",
		callback = function(args)
			vim.keymap.set("n", "<CR>", M.qf_jump, { buffer = args.buf, desc = "Desk: jump (jumplist-safe)" })
			local group = vim.api.nvim_create_augroup("desk_qf_preview_" .. args.buf, { clear = true })
			vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = args.buf, callback = M.qf_preview })
			vim.api.nvim_create_autocmd({ "WinEnter", "FocusGained" }, {
				group = group,
				buffer = args.buf,
				callback = function()
					M.qf_check()
				end,
			})
			vim.keymap.set("n", "r", M.qf_restore, { buffer = args.buf, desc = "Desk: restore this declined item" })
			-- The overview's own keys; in any other list they keep their meaning.
			local verbs = { t = "take", dp = "take", x = "decline", gD = "decline", q = "close list", Q = "close review" }
			for lhs, verb in pairs(verbs) do
				vim.keymap.set("n", lhs, function()
					if vim.fn.getqflist({ title = 0 }).title ~= M.OVERVIEW_TITLE or is_loclist_win(vim.api.nvim_get_current_win()) then
						vim.api.nvim_feedkeys(vim.v.count > 0 and vim.v.count .. lhs or lhs, "n", false)
						return
					end
					-- Said after the key's own redraw, so the reason is not lost
					-- under it.
					local function say(ok, why)
						if not ok then
							vim.schedule(function()
								report(ok, why)
							end)
						end
					end
					if verb == "close list" then
						vim.cmd("cclose")
					elseif verb == "close review" then
						say(M.qf_close_review())
					else
						say(M.qf_act(verb))
					end
				end, { buffer = args.buf, desc = "Desk overview: " .. verb .. (verb:match("^close") and "" or " this suggestion") })
			end
		end,
	})
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
			-- shows next. BufLeave also fires on merely moving to another
			-- window, so this waits to see whether the window still has the notes.
			local win = vim.api.nvim_get_current_win()
			local mine = vim.wo[win].winbar
			vim.schedule(function()
				if
					vim.api.nvim_win_is_valid(win)
					and vim.api.nvim_win_get_buf(win) ~= bufnr
					and vim.wo[win].winbar == mine
				then
					vim.wo[win].winbar = ""
				end
			end)
		end,
	})

	M.refresh_status_line(bufnr)
end

return M
