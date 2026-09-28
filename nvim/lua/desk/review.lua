-- D6: review keys, review mode, virtual text, and the overview — the
-- interactive layer built on desk.ledger/desk.histext/desk.apply (D5).
--
-- A note on the proposal ref (design.md §9(e)): the runner (not built by
-- this piece) writes `refs/desk/proposal` as a commit chain, but its exact
-- tree layout isn't pinned anywhere yet. This module reads it as: the
-- ref's HEAD commit's tree holds one blob, `proposal.json`, containing
-- exactly the judge's own `{"items": [...]}` output (design.md §9(e) /
-- morning-j.md's "Output" section) — the simplest shape, needing no
-- translation on the runner's side. If the runner ends up writing
-- something else, `read_proposal` below is the one place to change.
local apply = require("desk.apply")
local git = require("desk.git")
local histext = require("desk.histext")
local ledger = require("desk.ledger")
local snippet = require("desk.snippet")

local M = {}

M.PROPOSAL_REF = "refs/desk/proposal"

-- ---------------------------------------------------------------------------
-- Repo/file context and state reading
-- ---------------------------------------------------------------------------

--- The notes repo root and the buffer's file name relative to it (assumed
--- to live at the repo root, per design.md §6 — notes.md / reading.md),
--- or nil, "not in a git repo" if the buffer isn't inside one.
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

--- HEAD's content for `file` in `repo`, or {} if HEAD has no such blob yet
--- (a brand-new repo before its first commit of this file).
function M.head_lines(repo, file)
	local exists = git.run(repo, { "cat-file", "-e", "HEAD:" .. file })
	if not exists then
		return {}
	end
	local ok, out = git.run(repo, { "show", "HEAD:" .. file })
	if not ok then
		return {}
	end
	return (snippet.split_lines(out))
end

--- Reads head/index/worktree lines plus every id's derived state, items,
--- last-key records and pending ranges for `bufnr` in one call.
function M.read_state(bufnr)
	local repo, file = M.repo_context(bufnr)
	if not repo then
		return nil, file
	end
	local head = M.head_lines(repo, file)
	local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
	local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local states, items, last_key, ranges = ledger.derive_all(repo, head, index_lines, worktree_lines)
	return {
		repo = repo,
		file = file,
		head_lines = head,
		index_lines = index_lines,
		worktree_lines = worktree_lines,
		states = states,
		items = items,
		last_key = last_key,
		ranges = ranges,
	}
end

-- ---------------------------------------------------------------------------
-- Item under cursor
-- ---------------------------------------------------------------------------

--- The pending item whose current worktree range contains `line` (1-
--- indexed), plus the read_state() table it was found in — or nil, a
--- message if nothing pending sits there.
function M.item_at_line(bufnr, line)
	local st, err = M.read_state(bufnr)
	if not st then
		return nil, err
	end
	for id, rs in pairs(st.ranges) do
		for _, r in ipairs(rs) do
			local hit = (r.count > 0 and line >= r.line and line <= r.line + r.count - 1) or (r.count == 0 and line == r.line)
			if hit then
				return st.items[id], st
			end
		end
	end
	return nil, "no pending suggestion under the cursor"
end

-- ---------------------------------------------------------------------------
-- Accept / decline / not-now (whole-item actions)
-- ---------------------------------------------------------------------------

--- The item's live content at its "after"-bearing range(s) right now — what
--- accept should stage, honoring an edit he made before pressing it
--- ("accept edited" is just edit, then accept — design.md §2).
local function live_after(bufnr, item, ranges)
	for _, r in ipairs(ranges or {}) do
		if r.count > 0 then
			return snippet.join_lines(vim.api.nvim_buf_get_lines(bufnr, r.line - 1, r.line - 1 + r.count, false), false)
		end
	end
	return item.after
end

--- Stages `item`'s current buffer content into the index and records an
--- `accept` key. Returns true, or false, an error message.
function M.accept(bufnr, line)
	line = line or vim.api.nvim_win_get_cursor(0)[1]
	local item, st = M.item_at_line(bufnr, line)
	if not item then
		return false, st
	end
	local after = live_after(bufnr, item, st.ranges[item.id])
	local proposal_item = { id = item.id, file = st.file, kind = item.kind, target = item.anchor, before = item.before, after = after }
	local new_index = apply.apply_file(st.index_lines, { proposal_item })
	local sha = git.hash_object_write(st.repo, snippet.join_lines(new_index, true))
	if not sha then
		return false, "could not write the staged blob"
	end
	local entry = git.index_entry(st.repo, st.file) or { mode = "100644" }
	if not git.update_index_cacheinfo(st.repo, entry.mode, sha, st.file) then
		return false, "could not update the index"
	end
	local ok = ledger.append(st.repo, { type = "key", id = item.id, at = os.time(), action = "accept" })
	if not ok then
		return false, "could not record the accept in the ledger"
	end
	vim.cmd("silent! noautocmd write")
	return true
end

--- Resets `item`'s lines in the buffer back to `before` — occurrence-aware
--- via desk.histext, so an edit of his beside it is never touched — and
--- records a `decline` or `not_now` key.
-- Resets `item` at its known-correct current buffer range(s) (from
-- desk.ledger's `ranges`, already offset-adjusted for every OTHER pending
-- item sharing the file — unlike resolving the anchor fresh via
-- desk.histext with just this one item, which would be wrong the moment a
-- sibling suggestion sits between it and the top of the file: its content
-- would still be sitting in the worktree, uncounted, throwing off every
-- position after it). A move/merge's gap-shaped (leaving) range gets
-- `before` re-inserted; its content-shaped (landing) range, like a plain
-- add/edit/new/link, gets replaced with `before` (empty for a pure
-- insertion, meaning removed outright).
local function reset_item(bufnr, line, action)
	line = line or vim.api.nvim_win_get_cursor(0)[1]
	local item, st = M.item_at_line(bufnr, line)
	if not item then
		return false, st
	end
	local before_lines = snippet.split_lines(item.before)
	local two_location = item.kind == "move" or item.kind == "merge"
	local ranges = vim.deepcopy(st.ranges[item.id] or {})
	table.sort(ranges, function(a, b)
		return a.line > b.line -- bottom to top, so an earlier edit never shifts a later lookup
	end)
	for _, r in ipairs(ranges) do
		if r.count == 0 then
			vim.api.nvim_buf_set_lines(bufnr, r.line - 1, r.line - 1, false, before_lines)
		else
			local replacement = two_location and {} or before_lines
			vim.api.nvim_buf_set_lines(bufnr, r.line - 1, r.line - 1 + r.count, false, replacement)
		end
	end
	local ok = ledger.append(st.repo, { type = "key", id = item.id, at = os.time(), action = action })
	if not ok then
		return false, "could not record the " .. action .. " in the ledger"
	end
	vim.cmd("silent! noautocmd write")
	return true
end

function M.decline(bufnr, line)
	return reset_item(bufnr, line, "decline")
end

function M.not_now(bufnr, line)
	return reset_item(bufnr, line, "not_now")
end

--- Restores `item` (a ledger item record, from desk.ledger.declined_recently
--- — a genuinely declined one, or one resolved without ever going through a
--- key) into `bufnr` at its own anchor, via the same desk.apply.apply_file
--- machinery the review key uses to lay items in, against the buffer's
--- CURRENT content — never against head, so it never disturbs anything
--- else already sitting there. Records a `restore` key for provenance —
--- never one derive_all's own bucketing consults (an item's state is
--- content-derived, so what makes it "pending" again is `after` landing
--- back in the worktree, not this key), same reasoning as `accept`/
--- `decline`/`not_now`'s own key records. design.md §2's "A 'declined
--- recently' listing".
function M.restore(bufnr, item)
	local repo, file = M.repo_context(bufnr)
	if not repo then
		return false, file
	end
	local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local proposal_item =
		{ id = item.id, file = file, kind = item.kind, target = item.anchor, before = item.before, after = item.after }
	local new_lines, results = apply.apply_file(worktree_lines, { proposal_item })
	if results[item.id] ~= "applied" then
		return false, "could not restore: its anchor no longer resolves cleanly"
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	vim.cmd("silent! noautocmd write")
	local ok = ledger.append(repo, { type = "key", id = item.id, at = os.time(), action = "restore" })
	if not ok then
		return false, "could not record the restore in the ledger"
	end
	return true
end

-- ---------------------------------------------------------------------------
-- His commit key / the review key
-- ---------------------------------------------------------------------------

--- Commits his text (design.md §2): computes it (reverting only genuinely
--- pending items) and writes it to the index via desk.histext, then turns
--- that index state into a real commit — his own identity, nothing
--- special. A no-op (no commit) if his text already matches HEAD.
---
--- Every run also (re)writes the pending-set snapshot (§9(g)): the ids
--- this run derived as "pending", against the repo's resulting HEAD sha —
--- the baseline a later `ledger-classify` reads back to tell "resolved
--- through the review key" apart from "resolved some other way" between
--- this run and the next one.
function M.commit_his_text(bufnr)
	local repo, file = M.repo_context(bufnr)
	if not repo then
		return false, file
	end
	local head = M.head_lines(repo, file)

	local pending_ids = {}
	local sha, results, err = histext.write_to_index(repo, file, function()
		local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
		local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local states, items = ledger.derive_all(repo, head, index_lines, worktree_lines)
		local pending_items = {}
		pending_ids = {}
		for id, item in pairs(items) do
			if states[id] == "pending" then
				table.insert(pending_items, item)
				table.insert(pending_ids, id)
			end
		end
		return {
			worktree_lines = worktree_lines,
			index_lines = index_lines,
			pending_items = pending_items,
			head_lines = head,
		}
	end)
	if not sha then
		return false, err
	end

	local diff_ok = git.run(repo, { "diff", "--cached", "--quiet", "HEAD", "--", file })
	local commit_err
	if not diff_ok then
		local commit_ok
		commit_ok, _, commit_err = git.run(repo, { "commit", "-m", "notes" })
		if not commit_ok then
			return false, "git commit failed: " .. commit_err
		end
	end

	local head_ok, head_out = git.run(repo, { "rev-parse", "HEAD" })
	ledger.write_pending_snapshot(
		ledger.pending_snapshot_path(repo, file),
		head_ok and vim.trim(head_out) or "",
		pending_ids
	)

	return true, results
end

--- Reads the latest proposal from refs/desk/proposal (see the file-level
--- comment on its assumed shape). Returns a list of items, or {} if the
--- ref doesn't exist.
function M.read_proposal(repo)
	local sha = git.ref_sha(repo, M.PROPOSAL_REF)
	if not sha then
		return {}
	end
	local ok, out = git.run(repo, { "show", sha .. ":proposal.json" })
	if not ok then
		return {}
	end
	local decode_ok, parsed = pcall(vim.json.decode, out)
	if not decode_ok or type(parsed) ~= "table" then
		return {}
	end
	return parsed.items or {}
end

--- Writes `items` (the pinned proposal shape, design.md §9(e)) as the new
--- tip of refs/desk/proposal: a commit whose tree holds one blob,
--- `proposal.json`, parented on the ref's current tip (design.md's own
--- "Proposal ref layout" — "Each pass commits a new proposal commit whose
--- parent is the previous one"). This is the runner's own write path (via
--- `nvim -l`, per design.md §6): it never touches the working file or the
--- index, only this ref, through the same compare-and-swap-with-retry
--- helper every other desk ref write uses. Returns the new commit sha, or
--- nil, an error message.
function M.write_proposal(repo, items)
	return git.cas_retry(repo, M.PROPOSAL_REF, function(old_sha)
		local blob = git.hash_object_write(repo, vim.json.encode({ items = items }))
		if not blob then
			return nil
		end
		local mktree_ok, tree_out =
			git.run(repo, { "mktree" }, string.format("100644 blob %s\tproposal.json\n", blob))
		if not mktree_ok then
			return nil
		end
		local args = { "commit-tree", vim.trim(tree_out), "-m", "proposal" }
		if old_sha then
			table.insert(args, "-p")
			table.insert(args, old_sha)
		end
		local commit_ok, commit_out = git.run(repo, args)
		if not commit_ok then
			return nil
		end
		return vim.trim(commit_out)
	end)
end

--- The review key: commits his text, lays the currently queued slice of the
--- proposal into the buffer as unstaged hunks against the fresh commit,
--- records which items it laid in, and turns on review mode.
---
--- Only an item the ledger derives as "queued" (never laid in before), or
--- "postponed" AND re-proposed by a newer pass (its own `postponed_from`
--- marker — this module's convention, see the virtual-text section below)
--- gets laid in. Without this filter, every press blindly re-applies the
--- WHOLE proposal blob against head regardless of what's already
--- accepted/declined/still pending in the buffer — a second press
--- duplicates whatever's already there (an accepted item's `after` is
--- still in the proposal, and head hasn't advanced to absorb it yet) and
--- resurrects a declined one (its content is gone from the buffer, but
--- nothing stopped it being re-inserted).
---
--- An item whose anchor doesn't apply cleanly (a real content conflict —
--- his edits sit where it expected to find its own `before`) is deferred
--- (left out, stays queued) — design.md §2. An item whose anchor doesn't
--- resolve AT ALL instead lands on top and counts as applied (see
--- desk.apply.apply_file); `landed_on_top` in the returned stats is how
--- many of this press's own lay-ins took that path.
function M.review(bufnr)
	local ok, err = M.commit_his_text(bufnr)
	if not ok then
		return false, err
	end
	local repo, file = M.repo_context(bufnr)
	local head = M.head_lines(repo, file)
	local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
	local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local states = ledger.derive_all(repo, head, index_lines, worktree_lines)

	local proposal_items = M.read_proposal(repo)
	local by_file = {}
	for _, item in ipairs(proposal_items) do
		if item.file == file then
			local state = states[item.id]
			if state == "queued" or (state == "postponed" and item.postponed_from) then
				table.insert(by_file, item)
			end
		end
	end
	local new_lines, results, landed_on_top = apply.apply_file(head, by_file)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	vim.cmd("silent! noautocmd write")

	local laid_in_ids = {}
	local deferred = 0
	local landed_on_top_count = 0
	for _, item in ipairs(by_file) do
		if results[item.id] == "applied" then
			table.insert(laid_in_ids, item.id)
			if landed_on_top[item.id] then
				landed_on_top_count = landed_on_top_count + 1
			end
		else
			deferred = deferred + 1
		end
	end
	local proposal_sha = git.ref_sha(repo, M.PROPOSAL_REF) or "unknown"
	ledger.append(repo, { type = "laid_in", at = os.time(), proposal = proposal_sha, items = laid_in_ids })

	M.enable_review_mode(bufnr)
	return true, { laid_in = #laid_in_ids, deferred = deferred, landed_on_top = landed_on_top_count }
end

-- ---------------------------------------------------------------------------
-- Review mode: gitsigns inline deleted lines + word diff. Both are global
-- gitsigns settings (its `config` table has no per-buffer notion), so this
-- turns them on for as long as focus stays in a notes buffer and off the
-- moment it leaves one — approximating "on for this buffer" with the only
-- lever gitsigns actually exposes. See desk.review's BufEnter/BufLeave wiring
-- in M.attach.
-- ---------------------------------------------------------------------------

function M.enable_review_mode(bufnr)
	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok then
		return
	end
	gitsigns.toggle_deleted(true)
	gitsigns.toggle_word_diff(true)
	if bufnr then
		vim.b[bufnr].desk_review_mode = true
	end
end

function M.disable_review_mode()
	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok then
		return
	end
	gitsigns.toggle_deleted(false)
	gitsigns.toggle_word_diff(false)
end

-- ---------------------------------------------------------------------------
-- Virtual text: headline, source, "suggested · age", and (when the runner
-- marks a re-proposed item as superseding an earlier postponed one — its
-- own `postponed_from` field, this module's convention, since the runner
-- isn't built yet) "postponed from <day>".
-- ---------------------------------------------------------------------------

M.ns = vim.api.nvim_create_namespace("desk_review")

local function format_age(proposed_at)
	if not proposed_at then
		return "unknown age"
	end
	local days = math.floor((os.time() - proposed_at) / 86400)
	if days <= 0 then
		return "today"
	elseif days == 1 then
		return "1 day"
	end
	return days .. " days"
end

--- Redraws every pending item's virtual text in `bufnr` from scratch.
function M.refresh_virtual_text(bufnr)
	local st = M.read_state(bufnr)
	if not st then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	for id, rs in pairs(st.ranges) do
		local item = st.items[id]
		local line = rs[1].line
		local parts = {}
		if item.headline and item.headline ~= "" then
			table.insert(parts, item.headline)
		end
		if item.source and item.source ~= "" then
			table.insert(parts, item.source)
		end
		table.insert(parts, "suggested · " .. format_age(item.proposed_at))
		if item.postponed_from then
			table.insert(parts, "postponed from " .. item.postponed_from)
		end
		vim.api.nvim_buf_set_extmark(bufnr, M.ns, math.max(line - 1, 0), 0, {
			virt_text = { { table.concat(parts, "  ·  "), "Comment" } },
			virt_text_pos = "eol",
		})
	end
end

-- ---------------------------------------------------------------------------
-- Overview: a quickfix list of pending suggestions — news first, then in-
-- place items by position, then a deferred count — plus his own unstaged
-- edits, labelled "yours". Every jump goes through the jumplist (design.md
-- §2), including from an overview opened in its own split: the jump moves
-- the cursor (and sets the ' mark) in the *notes* window, never the qf one.
-- ---------------------------------------------------------------------------

M.OVERVIEW_TITLE = "Desk overview"
M.DECLINED_TITLE = "Desk declined recently"
M.DECLINED_WINDOW_DAYS = 14

--- Lines that differ between his text (all pending items reverted) and the
--- index, outside of any pending item's own range — a best-effort "his own
--- edit" detector: exact for a same-length buffer (position-by-position),
--- which covers an in-place edit; it doesn't attempt a full line-level diff
--- for an edit that also inserts or deletes lines, which would need a real
--- diff algorithm this module doesn't have.
function M.unowned_hunks(bufnr, st)
	local his_lines = (histext.compute(st.worktree_lines, st.index_lines, (function()
		local pending = {}
		for id, item in pairs(st.items) do
			if st.states[id] == "pending" then
				table.insert(pending, item)
			end
		end
		return pending
	end)(), st.head_lines))
	local hunks = {}
	if #his_lines ~= #st.index_lines then
		return hunks -- can't safely position-compare; leave detection to gitsigns' own display
	end
	for i = 1, #his_lines do
		if his_lines[i] ~= st.index_lines[i] then
			table.insert(hunks, { line = i })
		end
	end
	return hunks
end

local function is_qf_buf(bufnr)
	return vim.bo[bufnr].filetype == "qf"
end

local function find_target_window()
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if not is_qf_buf(vim.api.nvim_win_get_buf(w)) then
			return w
		end
	end
	return nil
end

--- The quickfix `<CR>` handler for every quickfix buffer (installed once,
--- globally): falls through to the ordinary quickfix jump for any list that
--- isn't ours, and otherwise jumps in the target window with `m'` set
--- first, so Ctrl-O/Ctrl-I work there afterward.
function M.qf_jump()
	local title = vim.fn.getqflist({ title = 0 }).title
	if title ~= M.OVERVIEW_TITLE then
		vim.cmd(vim.fn.line(".") .. "cc")
		return
	end
	local idx = vim.fn.line(".")
	local item = vim.fn.getqflist()[idx]
	if not item or not item.bufnr or item.bufnr == 0 then
		return -- a header-only line (the deferred count): nothing to jump to
	end
	local target_win = find_target_window()
	if not target_win then
		vim.cmd("botright vsplit")
		target_win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("normal! m'")
	vim.api.nvim_win_set_buf(target_win, item.bufnr)
	vim.api.nvim_win_set_cursor(target_win, { math.max(item.lnum, 1), 0 })
end

--- Builds and opens the overview for `bufnr`'s notes file.
function M.overview(bufnr)
	local st = M.read_state(bufnr)
	if not st then
		return
	end

	local news, in_place = {}, {}
	for id, rs in pairs(st.ranges) do
		local item = st.items[id]
		local entry = { bufnr = bufnr, lnum = rs[1].line, col = 1, text = item.headline or item.id }
		if item.anchor == "top" then
			table.insert(news, { pos = rs[1].line, entry = entry })
		else
			table.insert(in_place, { pos = rs[1].line, entry = entry })
		end
	end
	table.sort(news, function(a, b)
		return a.pos < b.pos
	end)
	table.sort(in_place, function(a, b)
		return a.pos < b.pos
	end)

	local qf_items = {}
	for _, n in ipairs(news) do
		table.insert(qf_items, n.entry)
	end
	for _, n in ipairs(in_place) do
		table.insert(qf_items, n.entry)
	end

	local deferred = 0
	for id in pairs(st.items) do
		if st.states[id] == "postponed" then
			deferred = deferred + 1
		end
	end
	if deferred > 0 then
		table.insert(qf_items, { text = deferred .. " deferred" })
	end

	for _, hunk in ipairs(M.unowned_hunks(bufnr, st)) do
		table.insert(qf_items, { bufnr = bufnr, lnum = hunk.line, col = 1, text = "yours" })
	end

	vim.fn.setqflist({}, " ", { title = M.OVERVIEW_TITLE, items = qf_items })
	vim.cmd("copen")
end

--- Builds and opens a quickfix list of items declined, or resolved without
--- ever going through a key, within the last `days` (default
--- M.DECLINED_WINDOW_DAYS) — desk.ledger.declined_recently, design.md §2's
--- "A 'declined recently' listing". Newest first. Each entry is
--- restorable: press "r" on it (M.qf_restore, wired the same way as
--- M.qf_jump — by the list's own title, so it's a no-op on any other
--- quickfix list).
function M.list_declined_recently(bufnr, days)
	local st = M.read_state(bufnr)
	if not st then
		return
	end
	local entries = ledger.declined_recently(
		st.repo,
		st.head_lines,
		st.index_lines,
		st.worktree_lines,
		days or M.DECLINED_WINDOW_DAYS
	)
	table.sort(entries, function(a, b)
		return (a.item.proposed_at or 0) > (b.item.proposed_at or 0)
	end)
	local qf_items = {}
	for _, e in ipairs(entries) do
		local reason = e.reason == "declined" and "declined" or "resolved without a key"
		table.insert(qf_items, { text = string.format("%s (%s)", e.item.headline or e.item.id, reason) })
	end
	vim.fn.setqflist({}, " ", {
		title = M.DECLINED_TITLE,
		items = qf_items,
		context = { desk_declined = { bufnr = bufnr, entries = entries } },
	})
	vim.cmd("copen")
end

--- The quickfix "r" handler for every quickfix buffer (installed once,
--- globally, alongside M.qf_jump): a no-op for any list that isn't ours,
--- and otherwise restores the item under the cursor (M.restore) back into
--- the notes buffer the list was built from.
function M.qf_restore()
	local qf = vim.fn.getqflist({ title = 0, context = 0 })
	if qf.title ~= M.DECLINED_TITLE then
		return
	end
	local declined = qf.context and qf.context.desk_declined
	if not declined then
		return
	end
	local entry = declined.entries[vim.fn.line(".")]
	if not entry then
		return
	end
	local ok, err = M.restore(declined.bufnr, entry.item)
	if ok then
		vim.notify("desk: restored " .. (entry.item.headline or entry.item.id), vim.log.levels.INFO)
		M.refresh_virtual_text(declined.bufnr)
		vim.cmd("cclose")
	else
		vim.notify("desk: " .. tostring(err), vim.log.levels.WARN)
	end
end

-- ---------------------------------------------------------------------------
-- Wiring: buffer-local keymaps for a notes buffer, and the once-only global
-- quickfix <CR> override. The notes files are enabled by a local marker in
-- the notes repo (design.md §6) — not a path in dotfiles — so this module
-- never hardcodes where the notes repo lives.
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

--- The whole-item keys this piece adds, layered over gitsigns' own raw
--- per-hunk keys (<leader>gj/gk/ga/gu/gp/gb, unchanged): capitals so they
--- read as "the same letter, but for the whole item" rather than a new,
--- unrelated mnemonic.
M.KEYMAPS = {
	{ mode = "n", lhs = "<leader>gR", desc = "Review: lay in the pending proposal" },
	{ mode = "n", lhs = "<leader>gc", desc = "Commit his text (no lay-in)" },
	{ mode = "n", lhs = "<leader>gA", desc = "Accept the whole item under cursor" },
	{ mode = "n", lhs = "<leader>gD", desc = "Decline the whole item under cursor" },
	{ mode = "n", lhs = "<leader>gN", desc = "Not now: postpone the whole item under cursor" },
	{ mode = "n", lhs = "<leader>go", desc = "Overview: pending suggestions" },
	{ mode = "n", lhs = "<leader>gd", desc = "Declined recently: list, restorable with r" },
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
	if ok then
		return
	end
	vim.notify("desk: " .. tostring(err_or_result), vim.log.levels.WARN)
end

--- Attaches the review keymaps and review-mode toggling to `bufnr`. Safe to
--- call more than once for the same buffer (idempotent).
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
		report(M.review(bufnr))
		M.refresh_virtual_text(bufnr)
	end, "Review: lay in the pending proposal")
	map("<leader>gc", function()
		report(M.commit_his_text(bufnr))
	end, "Commit his text (no lay-in)")
	map("<leader>gA", function()
		report(M.accept(bufnr))
		M.refresh_virtual_text(bufnr)
	end, "Accept the whole item under cursor")
	map("<leader>gD", function()
		report(M.decline(bufnr))
		M.refresh_virtual_text(bufnr)
	end, "Decline the whole item under cursor")
	map("<leader>gN", function()
		report(M.not_now(bufnr))
		M.refresh_virtual_text(bufnr)
	end, "Not now: postpone the whole item under cursor")
	map("<leader>go", function()
		M.overview(bufnr)
	end, "Overview: pending suggestions")
	map("<leader>gd", function()
		M.list_declined_recently(bufnr)
	end, "Declined recently: list, restorable with r")
	vim.api.nvim_buf_create_user_command(bufnr, "DeskDeclined", function()
		M.list_declined_recently(bufnr)
	end, { desc = "Desk: list declined-recently items, restorable with r" })

	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		buffer = bufnr,
		callback = function()
			if vim.b[bufnr].desk_review_mode then
				M.enable_review_mode(bufnr)
			end
			M.refresh_virtual_text(bufnr)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufLeave" }, {
		buffer = bufnr,
		callback = function()
			M.disable_review_mode()
		end,
	})

	M.refresh_virtual_text(bufnr)
end

return M
