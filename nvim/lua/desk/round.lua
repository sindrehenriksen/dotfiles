-- Review rounds (design.md's final section, "Review rounds — supersedes
-- the positional tracking described in §2 'His text' and the ledger
-- states"): tracking a laid-in proposal's items by CONTENT, never by
-- re-resolving each item's own anchor quote against a possibly-moved HEAD.
-- That positional approach broke on his own ordinary editing: a line added
-- above a pending item shifted its anchor's resolved position without
-- moving the item, so the next read found unrelated content there and
-- called it "declined"; accepting a line-adding item left everything below
-- it unreverted; two items sharing one anchor could re-resolve in a
-- different order than they were laid in; an accepted add or a declined
-- remove could read back wrong once his next commit erased the very text
-- the anchor quoted.
--
-- A round is recorded (see M.build, appended by desk.review) at lay-in:
-- the full buffer text as laid in, plus each item's own exact range(s) in
-- THAT text (desk.apply.apply_file's own ranges output — see there for the
-- "ties at one anchor are laid in input order" tie-break). Every later read
-- maps those ranges into the CURRENT index/worktree with a generic content
-- diff (vim.diff, or vim.text.diff on an nvim old enough to lack it) rather
-- than recomputing a position from the item's own anchor — so an edit
-- anywhere else in the file just shows up as an ordinary diff hunk the
-- mapping steps over, never as a reason to mis-set this item's own state.
--
-- Once an item's round-derived state is no longer "pending" (his commit —
-- desk.review.commit_his_text — is the one moment that's checked), it's
-- frozen (M.build_resolved, a "resolved" ledger record): every future read
-- trusts that recorded state outright rather than re-deriving it against a
-- HEAD that has since moved past the very text its own round entry quotes.
--
-- Not implemented here: design.md's own noted fallback, "if alignment
-- proves flaky: `git merge-file` against the round's text" — the content-
-- diff mapping below is the primary (and, so far, sufficient) path; the
-- 3-way-merge backstop for a genuinely misaligned round is future work.
local snippet = require("desk.snippet")

local M = {}

M.TYPE = "round"
M.RESOLVED_TYPE = "resolved"

-- ---------------------------------------------------------------------------
-- Building round / resolved ledger records (not appended here — the caller,
-- desk.review, owns the actual ledger write, so this module never depends
-- on desk.ledger and desk.ledger can freely depend on this one).
-- ---------------------------------------------------------------------------

--- Builds a "round" ledger record (design.md: "record a round at lay-in").
--- `lines` is the full laid-in buffer text; `items` is every item this
--- round covers (this press's freshly laid-in ones, plus every still-
--- pending item carried forward from the previous round — desk.review's
--- job to assemble, in lay-in order for the tie-break above); `ranges` is
--- item.id -> its ranges IN `lines` (desk.apply.apply_file's own output for
--- fresh items; desk.round.remap_ranges' output for carried ones). An item
--- with no entry in `ranges` (deferred at lay-in, or unmappable on carry-
--- forward) is silently left out of the round.
function M.build(file, lines, items, ranges)
	local item_ranges = {}
	for _, item in ipairs(items) do
		if item and ranges[item.id] then
			item_ranges[item.id] = { kind = item.kind, ranges = ranges[item.id] }
		end
	end
	return {
		type = M.TYPE,
		file = file,
		at = os.time(),
		text = lines,
		items = item_ranges,
	}
end

--- Builds a "resolved" (freeze) ledger record for one item — design.md:
--- "each commit freezes resolved items (appends their final state)".
function M.build_resolved(id, state)
	return { type = M.RESOLVED_TYPE, id = id, at = os.time(), state = state }
end

--- The latest "round" record for `file` in `records` (the full ledger,
--- already read by the caller — desk.ledger.read), or nil if `file` has
--- never had one laid in. Only the latest matters: each round's own
--- `items` already carries forward everything still pending from the one
--- before it (M.build's caller does this — design.md: "never rebuilds from
--- HEAD"), so there is never a need to walk the chain.
function M.latest(records, file)
	local latest
	for _, rec in ipairs(records) do
		if rec.type == M.TYPE and rec.file == file then
			latest = rec
		end
	end
	return latest
end

--- Every id -> its frozen ("accepted"/"declined") state, last record wins
--- (append-only ledger, so list order is chronological).
function M.resolved_states(records)
	local out = {}
	for _, rec in ipairs(records) do
		if rec.type == M.RESOLVED_TYPE and rec.id then
			out[rec.id] = rec.state
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Content-diff mapping: the one primitive design.md calls for ("map those
-- ranges to the current worktree and the index with one content-diff
-- primitive").
-- ---------------------------------------------------------------------------

--- `vim.diff` on a version of nvim old enough to lack it (design.md's own
--- named fallback, "vim.text.diff") — same call shape assumed.
local function diff_fn()
	return vim.diff or (vim.text and vim.text.diff)
end

--- The `vim.diff` "indices" hunks between `a_lines` and `b_lines`
--- (histogram algorithm — design.md names it explicitly), each
--- `{start_a, count_a, start_b, count_b}`, ascending by `start_a`. `{}` for
--- identical text (vim.diff itself returns `{}` here, but is skipped
--- entirely as a small optimization — the common case once nothing between
--- the round and this target has changed at all).
---
--- Exported (not just this module's own internal use): desk.review's own
--- overview reuses this same line-shift-robust primitive to tell his own
--- edits apart from a pending item's — a plain position-by-position
--- comparison (which desk.review used before) only works for a same-length
--- buffer, breaking the moment his edit adds or removes a line.
local function diff_hunks(a_lines, b_lines)
	local a_text = snippet.join_lines(a_lines, true)
	local b_text = snippet.join_lines(b_lines, true)
	if a_text == b_text then
		return {}
	end
	local fn = diff_fn()
	if not fn then
		return {} -- no diff primitive at all: treat as unmapped (see map_pos)
	end
	return fn(a_text, b_text, { result_type = "indices", algorithm = "histogram" }) or {}
end
M.diff_hunks = diff_hunks

--- Maps a 0-indexed "position" `p` in `a` (design.md ranges' own
--- convention throughout this codebase: the count of `a`-lines strictly
--- before the point of interest — content at 1-indexed line N has p = N-1;
--- a zero-width gap "after line N" also has p = N) into the corresponding
--- 0-indexed position in `b`, via `hunks` (ascending).
---
--- A hunk that ends at or before `p` shifts the result. One that starts AT
--- `p` exactly is more delicate: for a content-shaped range (`is_gap`
--- false), `p` is only ever the position immediately before that range's
--- own first line, so a hunk starting there is a genuinely separate,
--- preceding insertion (e.g. a sibling item's own suggestion landing right
--- above this one) and still shifts the result. For a gap-shaped range
--- (`is_gap` true — a removal, or a move/merge's leaving side), `p` IS the
--- gap itself: a hunk starting exactly there is usually the gap's OWN
--- resolution (its content coming back on a decline, or the reverse on an
--- accept), so it's left for the caller's own content check instead of
--- being folded into the offset — folding it in would make an accepted
--- removal at the very end of the file (nothing beyond it to anchor
--- against) read as its own preceding shift and misplace the check
--- entirely (see design.md's own accepted residual: "repeated identical
--- lines can misalign").
local function map_pos(hunks, p, is_gap)
	local offset = 0
	for _, h in ipairs(hunks) do
		local a_start, a_count, b_count = h[1], h[2], h[4]
		-- 0-indexed count of a-lines before this hunk's own content —
		-- vim.diff's own convention already matches this for a pure
		-- insertion/deletion (count_a == 0: start_a IS that count), and
		-- start_a - 1 gets there for an ordinary (count_a > 0) hunk.
		local before_a = (a_count > 0) and (a_start - 1) or a_start
		if before_a + a_count <= p and not (is_gap and before_a == p) then
			offset = offset + (b_count - a_count)
		else
			break -- hunks are ascending; nothing further is fully before p
		end
	end
	return p + offset
end

-- ---------------------------------------------------------------------------
-- Deriving state + carrying ranges forward
-- ---------------------------------------------------------------------------

local CONTENT_ROLE = { edit = true, land = true }

--- True if `expected` (a snippet, already split into lines) sits at the
--- 1-indexed position `pos1` in `lines` — occurrence-aware, never a bare
--- substring (desk.snippet's own rule, applied here at a diff-mapped
--- position rather than a re-resolved anchor).
local function present(lines, pos1, expected)
	return snippet.lines_match_at(lines, pos1, expected)
end

--- Derives every round-tracked item's state from its own range(s), mapped
--- via content diff from `round.text` into `index_lines` and
--- `worktree_lines` independently (design.md: "state by content: item
--- lines in the worktree but not the index = pending; in both = accepted;
--- in neither = declined; a removal flips at its gap"). `items` is id ->
--- item record (desk.ledger.items_by_id); `round` is M.latest's result (or
--- nil — nothing laid in for this file yet, in which case both returns are
--- empty); `resolved` is M.resolved_states' result — a frozen item's state
--- is trusted outright, no mapping attempted.
---
--- Returns id -> state ("pending"/"accepted"/"declined") for every id the
--- round (or a freeze record) knows about, plus id -> worktree ranges
--- (1-indexed `{line, count, role}`, same shape desk.apply.apply_file
--- returns) for "pending" items only — the ones a review key's whole-item
--- action, or desk.histext, can actually act on.
function M.derive(items, round, resolved, index_lines, worktree_lines)
	local states, ranges = {}, {}
	if not round then
		return states, ranges
	end

	local idx_hunks, wt_hunks
	for id, entry in pairs(round.items or {}) do
		if resolved[id] then
			states[id] = resolved[id]
		else
			local item = items[id]
			if item then
				idx_hunks = idx_hunks or diff_hunks(round.text, index_lines)
				wt_hunks = wt_hunks or diff_hunks(round.text, worktree_lines)

				local before_lines = snippet.split_lines(item.before)
				local after_lines = snippet.split_lines(item.after)
				local partial = {}
				local pend_ranges = {}

				for _, r in ipairs(entry.ranges) do
					local p = r.line - 1
					local content_shaped = CONTENT_ROLE[r.role]
					local idx_pos1 = map_pos(idx_hunks, p, not content_shaped) + 1
					local wt_pos1 = map_pos(wt_hunks, p, not content_shaped) + 1
					local expected = content_shaped and after_lines or before_lines
					local in_index = present(index_lines, idx_pos1, expected)
					local in_wt = present(worktree_lines, wt_pos1, expected)
					local state

					if content_shaped then
						if in_wt and not in_index then
							state = "pending"
							table.insert(pend_ranges, { line = wt_pos1, count = #expected, role = r.role })
						elseif in_wt and in_index then
							state = "accepted"
						elseif (not in_wt) and (not in_index) then
							state = "declined"
						else
							state = "pending" -- in index but not worktree: unresolved drift
						end
					else -- gap-shaped (leave/removal): before-shaped, presence means "not yet accepted"
						if in_index and not in_wt then
							state = "pending"
							table.insert(pend_ranges, { line = wt_pos1, count = 0, role = r.role })
						elseif (not in_index) and (not in_wt) then
							state = "accepted"
						else
							state = "declined" -- content's back in both: reset
						end
					end
					partial[r.role] = state
				end

				local bucket
				if partial.removal then
					bucket = partial.removal
				elseif partial.leave and partial.land then
					bucket = (partial.leave == partial.land) and partial.leave or "pending" -- disagreement: still needs review
				else
					bucket = partial.edit
				end
				states[id] = bucket
				if bucket == "pending" then
					ranges[id] = pend_ranges
				end
			end
		end
	end

	return states, ranges
end

--- Remaps `old_ranges` (an item's ranges in `old_text`) into `new_text` via
--- the same content-diff mapping M.derive uses — desk.review's own "carried
--- ranges remapped" step on a second review press or a restore (design.md:
--- "it never rebuilds from HEAD, so pending items survive restarts and new
--- passes").
function M.remap_ranges(old_text, old_ranges, new_text)
	local hunks = diff_hunks(old_text, new_text)
	local out = {}
	for _, r in ipairs(old_ranges) do
		out[#out + 1] = { line = map_pos(hunks, r.line - 1, r.count == 0) + 1, count = r.count, role = r.role }
	end
	return out
end

return M
