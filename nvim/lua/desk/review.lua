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

local function remember_taken(s, item, pre)
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
--- whose take the user has undone (the text is not there, and the buffer is back
--- before the take) is dropped. Returns how many were recorded.
function M.flush_taken(notes_buf)
	local pend = pending_taken[notes_buf]
	if not pend then
		return 0
	end
	pending_taken[notes_buf] = nil
	if not vim.api.nvim_buf_is_valid(notes_buf) then
		return 0
	end
	local lines, seq = buf_lines(notes_buf), undo_seq(notes_buf)
	local items = {}
	for _, t in pairs(pend.ids) do
		if proposal.proposed_in(t.item, lines, t.base) or (seq >= t.seq and not vim.deep_equal(lines, t.pre)) then
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
	return #items
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

local function begin_take(s)
	return {
		tick = vim.api.nvim_buf_get_changedtick(s.notes_buf),
		notes_pre = undo_seq(s.notes_buf),
		review_seq = undo_seq(s.review_buf),
		pending = vim.deepcopy(pending_ids(s.notes_buf)),
	}
end

local function end_take(s, t)
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
	s.takes[#s.takes + 1] = t
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
		if taking[item.id] then
			-- taken by decision: edited text is no reason to call it declined
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
				if pos >= h[3] and pos <= h[3] + math.max(h[4], 1) - 1 then
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

--- Opens `file` of the notes repo in a window above the current one (or
--- focuses it) and attaches the review keys. Returns its buffer.
local function open_file_buf(repo, file)
	local b = vim.fn.bufadd(repo .. "/" .. file)
	vim.fn.bufload(b)
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

-- The review split's winbar: the live count, then the keys in one line, so
-- the table in the desk guide doesn't have to be open beside it. Kept to
-- about 120 columns with the count, which is why plain diff motion (]c/[c)
-- is left out. Each bar names only the window key that leaves it.
M.KEY_HINT = "dp take · ␣gA one · ␣gD decline · u undo · zo/zc fold · zR/zM all · C-n down · ␣go list · :wq done"
-- The notes window's keys while a review is open, right-aligned after its
-- status line. `u` there is plain undo, which is right in that buffer.
M.NOTES_KEY_HINT = "do take · u undo · C-t up"
-- And with no review open, the desk keys still being learned.
M.NOTES_IDLE_HINT = "␣gR review · ␣gx open/jump · ␣go list"

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
		close_session(existing)
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
		local other = open_file_buf(repo, elsewhere[1].file)
		return M.open_review(other)
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
		base = base,
		takes = {},
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
			elseif n_or_err > 0 then
				vim.notify("desk: declined " .. n_or_err .. " suggestion(s)", vim.log.levels.INFO)
			end
			M.refresh_overview(s)
			M.refresh_status_line(notes_buf, true)
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
		end,
	})
	-- Plain `do` on the last line does nothing when a suggestion is appended
	-- after it and another hunk precedes it; the range form works, so fall
	-- back to it when `do` changed nothing there.
	vim.keymap.set("n", "do", function()
		local tick = vim.api.nvim_buf_get_changedtick(notes_buf)
		local pre = buf_lines(notes_buf)
		local count = vim.v.count > 0 and tostring(vim.v.count) or ""
		pcall(vim.cmd, "normal! " .. count .. "do")
		local line = vim.api.nvim_win_get_cursor(0)[1]
		if vim.api.nvim_buf_get_changedtick(notes_buf) == tick and count == "" and line == vim.api.nvim_buf_line_count(notes_buf) then
			pcall(vim.cmd, string.format("%d,%ddiffget", line, line + 1))
		end
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
				local inside = false
				for _, h in ipairs(hunks) do
					inside = inside or (h[4] > 0 and pos >= h[3] and pos <= h[3] + h[4] - 1)
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
		local at = block.find_anchor(s.base, leave)
		if at and snippet.lines_match_at(s.base, at + 1, before) then
			local hunks = diff_indices(s.base, lines)
			local row = map_row(hunks, at + 1, false)
			local last = map_row(hunks, at + #before, false)
			if last - row == #before - 1 and snippet.lines_match_at(lines, row, before) then
				return row
			end
		end
	end
	local at = block.find_anchor(lines, leave)
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
			local at = leave and leave.kind == "at" and block.find_anchor(s.base, leave)
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

-- Declines `item` in the review buffer: its added lines go (an edit's
-- `before` returns in their place) and its deleted lines come back — an
-- ordinary edit, so `u` undoes it.
local function decline_item(s, item)
	local buf = s.review_buf
	local before = snippet.split_lines(item.before)
	local changed = false
	local first, last = mark_range(s, item)
	if first then
		vim.api.nvim_buf_set_lines(buf, first - 1, last, false, item.kind == "edit" and before or {})
		changed = true
	end
	if leaves_before(item) then
		local row = del_row(s, item)
		if row then
			vim.api.nvim_buf_set_lines(buf, row, row, false, before)
			changed = true
		end
	end
	return changed
end

-- Takes `item` into the user's notes buffer: its lines go in at the place the
-- review shows them, its deleted lines go out of their anchored occurrence.
local function take_item(s, item)
	local nbuf = s.notes_buf
	local notes = buf_lines(nbuf)
	local before = snippet.split_lines(item.before)
	local after = snippet.split_lines(item.after)
	local changed = false
	local first = mark_range(s, item)
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
		note_takes(s, before_notes, acted)
	end
	return true
end

-- Declines or takes `item`, as the decline and take-one keys do.
local function act_on(s, item, verb)
	if verb == "decline" then
		if not decline_item(s, item) then
			return false, "nothing to decline here"
		end
		return true
	end
	local pre = buf_lines(s.notes_buf)
	if not take_item(s, item) then
		return false, "could not take this suggestion"
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
	local item = M.item_at(s, vim.api.nvim_win_get_cursor(win)[1])
	if not item then
		return nil
	end
	return act_on(s, item, verb)
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

-- ---------------------------------------------------------------------------
-- Overview: one quickfix entry per remaining hunk
-- ---------------------------------------------------------------------------

-- The title is the list's identity too, and the qf window's status line
-- shows it, so it carries the list's own keys.
M.OVERVIEW_TITLE = "Desk overview: ⏎ jump · t/dp take · x/gD decline"
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
						if pos >= h[3] and pos <= h[3] + math.max(h[4], 1) - 1 then
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

local function overview_items(s, repo, file)
	local qf = {}
	if s then
		for _, r in ipairs(M.remaining(s)) do
			local text = r.item.headline or r.item.id
			if r.conflict then
				text = string.format("%s (near your edit at line %d)", text, r.conflict)
			end
			qf[#qf + 1] = { bufnr = s.notes_buf, lnum = r.notes_lnum, col = 1, text = text, user_data = { id = r.item.id } }
		end
	end
	for _, o in ipairs(M.pending_elsewhere(repo, file)) do
		local b = vim.fn.bufadd(repo .. "/" .. o.file)
		for _, e in ipairs(o.entries) do
			local text = e.item.headline or e.item.id
			if e.conflict then
				text = string.format("%s (near your edit at line %d)", text, e.conflict)
			end
			qf[#qf + 1] = { bufnr = b, lnum = e.lnum, col = 1, text = o.file .. ": " .. text, user_data = { file = o.file, id = e.item.id } }
		end
	end
	return qf
end

--- Rebuilds an overview list already open for `s` (after a decline or a save).
function M.refresh_overview(s)
	local info = vim.fn.getqflist({ title = 0, context = 0 })
	if info.title ~= M.OVERVIEW_TITLE or not (info.context and info.context.desk_review_buf == s.review_buf) then
		return
	end
	vim.fn.setqflist({}, "r", { title = M.OVERVIEW_TITLE, items = overview_items(s, s.repo, s.file), context = info.context })
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
--- ordinary jump. An overview entry jumps into the review split, where the user
--- works, to the suggestion's line (so `dp` there takes it); with no review
--- open, into THE USER'S NOTES window at the line aligned with the hunk. Either
--- way through the jumplist (`m'` first), so Ctrl-O returns to where the user
--- was in that window.
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
		-- The other file: open it above, with its own review split above it.
		local b = open_file_buf(repo, file)
		M.open_review(b)
		win = vim.fn.bufwinid(b)
		item.bufnr = b
	end
	local lnum = item.lnum
	local s = sessions[item.bufnr]
	local id = type(item.user_data) == "table" and item.user_data.id
	local review_win = s and vim.api.nvim_buf_is_valid(s.review_buf) and vim.fn.bufwinid(s.review_buf) or -1
	if review_win ~= -1 and id then
		-- looked up now, not when the list was made: takes and edits since
		-- then move the lines
		for _, r in ipairs(M.remaining(s)) do
			if r.item.id == id then
				win, lnum = review_win, r.lnum
			end
		end
	end
	if win == -1 then
		vim.notify("desk: your notes are not showing in any window", vim.log.levels.WARN)
		return
	end
	vim.api.nvim_set_current_win(win)
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
-- The user's commit key
-- ---------------------------------------------------------------------------

--- Saves the user's notes buffer and commits the file as it is, then records any
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
	M.flush_taken(bufnr)
	local taken = proposal.sync_taken(repo)
	M.refresh_status_line(bufnr, true)
	return true, { taken = #taken }
end

-- ---------------------------------------------------------------------------
-- Status line: the runner's status.json summary in the notes buffer's winbar.
-- ---------------------------------------------------------------------------

local function live_session(bufnr)
	local s = bufnr and sessions[bufnr]
	if s and vim.api.nvim_buf_is_valid(s.review_buf) then
		return s
	end
end

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
--- its split: the status line plus the notes window's keys below, the count
--- and the review keys above. `recount` after a save or a commit, which
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
	local line = bar_text(M.status_line(bufnr, left)) .. "%=" .. (s and M.NOTES_KEY_HINT or M.NOTES_IDLE_HINT)
	for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
		vim.wo[win].winbar = line
	end
	if s then
		local rw = vim.fn.bufwinid(s.review_buf)
		if rw ~= -1 then
			vim.wo[rw].winbar = bar_text(status.live_count(left, s.saved)) .. " · " .. M.KEY_HINT
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

local function report(ok, err_or_result)
	if not ok then
		vim.notify("desk: " .. tostring(err_or_result), vim.log.levels.WARN)
	end
end

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
			-- The overview's own keys; in any other list they keep their meaning.
			for lhs, verb in pairs({ t = "take", dp = "take", x = "decline", gD = "decline" }) do
				vim.keymap.set("n", lhs, function()
					if vim.fn.getqflist({ title = 0 }).title ~= M.OVERVIEW_TITLE or is_loclist_win(vim.api.nvim_get_current_win()) then
						vim.api.nvim_feedkeys(vim.v.count > 0 and vim.v.count .. lhs or lhs, "n", false)
						return
					end
					report(M.qf_act(verb))
				end, { buffer = args.buf, desc = "Desk overview: " .. verb .. " this suggestion" })
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
