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
local round = require("desk.round")
local snippet = require("desk.snippet")
local tokens = require("desk.tokens")

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
	local states, items, last_key, ranges = ledger.derive_all(repo, file, index_lines, worktree_lines)
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

--- Where a gap-shaped range (`r.count == 0` — a removal, or a move/merge's
--- leaving side) is actually reachable/visible in `bufnr` right now: `r.line`
--- itself, except when the content it stands for was the file's own very
--- last lines — desk.round.derive correctly computes that gap as sitting
--- one PAST the current last line (`#lines + 1`, the exact spot
--- reset_item's own re-insertion needs: appending after the true last line
--- restores the removed tail to where it belongs), but a cursor can never
--- sit on a line that doesn't exist, and neither can a quickfix entry or an
--- extmark row meant to look like it's attached to real content. Display/
--- hit-test callers clamp through this; reset_item (the one place that
--- actually re-inserts content there) uses `r.line` unclamped.
local function display_line(bufnr, line)
	return math.min(line, vim.api.nvim_buf_line_count(bufnr))
end

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
			local at = display_line(bufnr, r.line)
			local hit = (r.count > 0 and line >= r.line and line <= r.line + r.count - 1) or (r.count == 0 and line == at)
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
--- `accept` key. Returns true, or false, an error message. The index write
--- goes through desk.histext's own guard (design.md's own instruction:
--- reuse the retry-on-drift check `write_to_index` already had here too),
--- so a concurrent writer touching the index between the read and the
--- write is retried rather than silently overwritten or clobbering.
function M.accept(bufnr, line)
	line = line or vim.api.nvim_win_get_cursor(0)[1]
	local item, st = M.item_at_line(bufnr, line)
	if not item then
		return false, st
	end
	local after = live_after(bufnr, item, st.ranges[item.id])
	local proposal_item = { id = item.id, file = st.file, kind = item.kind, target = item.anchor, before = item.before, after = after }
	local sha, _, err = histext.write_index_guarded(st.repo, st.file, function()
		return { index_lines = snippet.split_lines(git.index_content(st.repo, st.file) or "") }
	end, function(state)
		local new_index = apply.apply_file(state.index_lines, { proposal_item })
		return snippet.join_lines(new_index, true)
	end)
	if not sha then
		return false, err or "could not write the staged blob"
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
	local new_lines, results, _, ranges = apply.apply_file(worktree_lines, { proposal_item })
	if results[item.id] ~= "applied" then
		return false, "could not restore: its anchor no longer resolves cleanly"
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	vim.cmd("silent! noautocmd write")
	-- Extends the round (design.md: "restore ... uses the same extend
	-- step") so the restored item — and every other still-pending item
	-- from the round before it — is tracked from here, never re-derived
	-- against a stale anchor.
	M.extend_round(repo, file, worktree_lines, { item }, new_lines, ranges)
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
--- pending items, at their own round-derived ranges) and writes it to the
--- index via desk.histext, then turns that index state into a real commit
--- — his own identity, nothing special. A no-op (no commit) if his text
--- already matches HEAD.
---
--- Freezes every resolved (accepted/declined) laid-in item not already
--- frozen (design.md's "Review rounds": "each commit freezes resolved
--- items ... so they are never re-derived against a moved HEAD") — the
--- commit is the one moment desk.ledger.derive_all's content-derived state
--- is trusted as final for anything no longer pending; postponed/queued
--- items are still active and are never frozen.
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

	local pending_ids = {}
	local to_freeze = {}
	local sha, results, err = histext.write_to_index(repo, file, function()
		local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
		local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local states, items, _, ranges = ledger.derive_all(repo, file, index_lines, worktree_lines)
		local resolved = round.resolved_states(ledger.read(repo))
		local pending_items = {}
		pending_ids = {}
		to_freeze = {}
		for id, item in pairs(items) do
			local state = states[id]
			if state == "pending" then
				table.insert(pending_items, item)
				table.insert(pending_ids, id)
			elseif (state == "accepted" or state == "declined") and not resolved[id] then
				table.insert(to_freeze, { id = id, state = state })
			end
		end
		return {
			worktree_lines = worktree_lines,
			pending_items = pending_items,
			pending_ranges = ranges,
		}
	end)
	if not sha then
		return false, err
	end

	if #to_freeze > 0 then
		local freeze_records = {}
		for _, f in ipairs(to_freeze) do
			freeze_records[#freeze_records + 1] = round.build_resolved(f.id, f.state)
		end
		ledger.append_many(repo, freeze_records)
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

--- Extends the round for `file` (design.md's "Review rounds": "a second
--- review press extends the round ... it never rebuilds from HEAD" — also
--- used by restore, "using the same extend step"). Appends a new "round"
--- ledger record whose text is `new_lines` — the buffer after
--- `added_items` were laid into `pre_lines` via desk.apply.apply_file,
--- which also supplies `added_ranges` for them — plus every item still
--- "pending" as of the round *before* this one (derived against
--- `pre_lines`, i.e. the buffer as it stood just before `added_items` went
--- in), carried forward with its ranges remapped from the OLD round's own
--- text into `new_lines` via desk.round.remap_ranges — the same content-
--- diff mapping every read already uses, never a fresh anchor resolution
--- against head.
function M.extend_round(repo, file, pre_lines, added_items, new_lines, added_ranges)
	local records = ledger.read(repo)
	local old_round = round.latest(records, file)
	local items_by_id = ledger.items_by_id(records)

	local round_items = {}
	for _, item in ipairs(added_items) do
		round_items[#round_items + 1] = item
	end
	local merged_ranges = vim.deepcopy(added_ranges)

	if old_round then
		local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
		local resolved = round.resolved_states(records)
		local states = select(1, ledger.derive_all(repo, file, index_lines, pre_lines))
		-- pairs() iterates old_round.items in an arbitrary order; carried
		-- items are appended after the freshly-added ones, so ties at one
		-- anchor between an OLD carried item and a brand-new one still
		-- favor the new one's own (already-correct) lay-in-order tie-break
		-- — a carried item was, by definition, already laid in before this
		-- press, so it never competes for input order with what's new.
		for id, entry in pairs(old_round.items) do
			if states[id] == "pending" and not resolved[id] and not merged_ranges[id] then
				merged_ranges[id] = round.remap_ranges(old_round.text, entry.ranges, new_lines)
				round_items[#round_items + 1] = items_by_id[id]
			end
		end
	end

	return ledger.append(repo, round.build(file, new_lines, round_items, merged_ranges))
end

--- The review key: commits his text, lays the currently queued (or
--- re-proposed postponed) slice of the proposal into the buffer against
--- the CURRENT WORKTREE — never head — so whatever the round before this
--- press is already carrying (every still-pending item, wherever his own
--- editing has since left it) stays exactly where it is; this press only
--- adds to it. Extends the round (M.extend_round), records which items it
--- laid in, and turns on review mode.
---
--- Only an item the ledger derives as "queued" (never laid in before) or
--- "postponed" (a "not now"'d item still present in the current proposal —
--- design.md's "Review rounds": "a postponed item is laid in again on its
--- postponed state alone") gets laid in. Without this filter, every press
--- would blindly re-apply the WHOLE proposal regardless of what's already
--- accepted/declined/still pending — duplicating what's already there and
--- resurrecting a declined item whose content is gone from the buffer.
---
--- An item whose anchor doesn't apply cleanly against the current worktree
--- (a real content conflict — his edits sit where it expected to find its
--- own `before`) is deferred (left out, stays queued) — design.md §2. An
--- item whose anchor doesn't resolve AT ALL instead lands on top and
--- counts as applied (see desk.apply.apply_file); `landed_on_top` in the
--- returned stats is how many of this press's own lay-ins took that path.
function M.review(bufnr)
	local ok, err = M.commit_his_text(bufnr)
	if not ok then
		return false, err
	end
	local repo, file = M.repo_context(bufnr)
	local index_lines = snippet.split_lines(git.index_content(repo, file) or "")
	local worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local states = ledger.derive_all(repo, file, index_lines, worktree_lines)

	local proposal_items = M.read_proposal(repo)
	local by_file = {}
	for _, item in ipairs(proposal_items) do
		if item.file == file then
			local state = states[item.id]
			if state == "queued" or state == "postponed" then
				table.insert(by_file, item)
			end
		end
	end
	local new_lines, results, landed_on_top, new_ranges = apply.apply_file(worktree_lines, by_file)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
	vim.cmd("silent! noautocmd write")

	local laid_in_ids = {}
	local applied_items = {}
	local deferred = 0
	local landed_on_top_count = 0
	for _, item in ipairs(by_file) do
		if results[item.id] == "applied" then
			table.insert(laid_in_ids, item.id)
			table.insert(applied_items, item)
			if landed_on_top[item.id] then
				landed_on_top_count = landed_on_top_count + 1
			end
		else
			deferred = deferred + 1
		end
	end
	M.extend_round(repo, file, worktree_lines, applied_items, new_lines, new_ranges)

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
-- Virtual text: headline, source, "suggested · age", and — for an item
-- laid in on its postponed state alone (design.md's "Review rounds": "a
-- postponed item is laid in again on its postponed state alone
-- ('postponed from <day>' comes from the not_now key's time)") —
-- "postponed from <day>", read straight from that item's own last `key`
-- record rather than a marker field on the item itself.
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

--- A short, one-word-ish label for where a suggestion came from, never the
--- raw `item.source` verbatim (which could be a full URL, a bare ticket key,
--- a bare session name, or nothing at all): a URL's own host ("github.com"),
--- a ticket-shaped token as "ticket KEY", a session-shaped one as "session
--- NAME", and "notes" — never blank — for anything else, empty/absent
--- included (found directly in his own notes, no external source at all).
--- `tokens_config` (desk.tokens shape) is what tells a ticket key and a
--- session name apart; without one (or with neither classifying it), the
--- honest label is still "notes" rather than a guess.
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

--- Redraws every pending item's virtual text in `bufnr` from scratch.
function M.refresh_virtual_text(bufnr)
	local st = M.read_state(bufnr)
	if not st then
		return
	end
	local tokens_config = tokens.tokens_from(select(1, tokens.load()))
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	for id, rs in pairs(st.ranges) do
		local item = st.items[id]
		local line = display_line(bufnr, rs[1].line)
		local parts = {}
		if item.headline and item.headline ~= "" then
			table.insert(parts, item.headline)
		end
		table.insert(parts, M.format_source(item.source, tokens_config))
		table.insert(parts, "suggested · " .. format_age(item.proposed_at))
		local last_key = st.last_key[id]
		if last_key and last_key.action == "not_now" and last_key.at then
			table.insert(parts, "postponed from " .. os.date("%A", last_key.at))
		end
		vim.api.nvim_buf_set_extmark(bufnr, M.ns, math.max(line - 1, 0), 0, {
			virt_text = { { table.concat(parts, " · "), "Comment" } },
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
	local pending = {}
	for id, item in pairs(st.items) do
		if st.states[id] == "pending" then
			table.insert(pending, item)
		end
	end
	local his_lines = (histext.compute(st.worktree_lines, pending, st.ranges))
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

--- True if `win` is showing a location list rather than a quickfix list —
--- both share filetype "qf", so this is the only reliable way to tell them
--- apart. Desk never opens a location list (M.overview/M.list_declined_recently
--- both go through setqflist), so the override below has no business acting
--- on one at all: LSP references, `:grep` piped to a loclist, or anything
--- else's own loclist window must fall through to the ordinary default.
local function is_loclist_win(win)
	local info = vim.fn.getwininfo(win)[1]
	return info ~= nil and info.loclist == 1
end

--- The quickfix `<CR>` handler for every quickfix buffer (installed once,
--- globally): a no-op override for a location list or any quickfix list
--- that isn't desk's own (falls through to the ordinary jump), and
--- otherwise jumps in the *previous* window (`wincmd p` — wherever he was
--- before opening the overview, never just "the first non-quickfix window
--- in the tab", which could be an unrelated split) with `m'` set first, so
--- Ctrl-O/Ctrl-I work there afterward.
function M.qf_jump()
	if is_loclist_win(vim.api.nvim_get_current_win()) then
		vim.cmd(vim.fn.line(".") .. "ll")
		return
	end
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
	local qf_win = vim.api.nvim_get_current_win()
	vim.cmd("wincmd p")
	local target_win = vim.api.nvim_get_current_win()
	if target_win == qf_win then
		-- No previous window to return to (the overview was opened as the
		-- only window in the tab): make one, same fallback as before.
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
		local entry = { bufnr = bufnr, lnum = display_line(bufnr, rs[1].line), col = 1, text = item.headline or item.id }
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
		st.file,
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
--- globally, alongside M.qf_jump): a no-op for a location list or any
--- quickfix list that isn't ours (checked by title, same as M.qf_jump —
--- desk's own lists are never location lists, so a loclist window is
--- rejected before even reading getqflist(), which would otherwise read
--- the unrelated *global* quickfix list instead of whatever the current
--- window is actually showing), and otherwise restores the item under the
--- cursor (M.restore) back into the notes buffer the list was built from.
function M.qf_restore()
	if is_loclist_win(vim.api.nvim_get_current_win()) then
		return
	end
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
