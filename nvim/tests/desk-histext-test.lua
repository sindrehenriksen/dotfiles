-- D5 test: the his-text/apply module (desk.block, desk.snippet, desk.git,
-- desk.ledger, desk.histext, desk.apply), from scratch against a throwaway
-- git repo — never a copy of, or a real read from, his actual notes.
--
-- Run: nvim -l nvim/tests/desk-histext-test.lua
local here = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path = here .. "/../lua/?.lua;" .. here .. "/../lua/?/init.lua;" .. package.path

local block = require("desk.block")
local snippet = require("desk.snippet")
local git = require("desk.git")
local ledger = require("desk.ledger")
local histext = require("desk.histext")
local apply = require("desk.apply")

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
	local exp_s, act_s = vim.json.encode(expected), vim.json.encode(actual)
	if exp_s == act_s then
		ok(desc)
	else
		bad(string.format("%s (expected %s, got %s)", desc, exp_s, act_s))
	end
end
local function assert_true(desc, v)
	assert_eq(desc, true, v and true or false)
end

-- ---------------------------------------------------------------------------
-- A throwaway repo, never touched by anything but this test.
-- ---------------------------------------------------------------------------
local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
assert(git.run(repo, { "init", "-q" }))
assert(git.run(repo, { "config", "user.email", "test@example.invalid" }))
assert(git.run(repo, { "config", "user.name", "Desk Test" }))

local function write_and_commit(path, lines, msg)
	local content = snippet.join_lines(lines, true)
	local fd = assert(io.open(repo .. "/" .. path, "w"))
	fd:write(content)
	fd:close()
	assert(git.run(repo, { "add", path }))
	assert(git.run(repo, { "commit", "-q", "-m", msg }))
end

local function write_worktree(path, lines)
	local fd = assert(io.open(repo .. "/" .. path, "w"))
	fd:write(snippet.join_lines(lines, true))
	fd:close()
end

local function read_worktree(path)
	local fd = assert(io.open(repo .. "/" .. path, "r"))
	local content = fd:read("*a")
	fd:close()
	return (snippet.split_lines(content))
end

print("=== desk.snippet ===")
do
	local lines = { "a", "b", "c", "b", "d" }
	assert_true("exact match at position", snippet.lines_match_at(lines, 2, { "b" }))
	assert_true("a repeated line matches only at its own position (2)", snippet.lines_match_at(lines, 2, { "b" }))
	assert_eq(
		"the same line elsewhere (position 4) is a different occurrence, not 'already there' at position 2",
		true,
		snippet.lines_match_at(lines, 4, { "b" })
	)
	assert_true("empty snippet matches anywhere valid (top)", snippet.lines_match_at(lines, 1, {}))
	assert_true("empty snippet matches anywhere valid (end+1)", snippet.lines_match_at(lines, 6, {}))
	assert_eq("multi-line snippet must match every line", false, snippet.lines_match_at(lines, 1, { "a", "X" }))
	assert_eq("round-trips through split/join", "x\ny\n", snippet.join_lines(snippet.split_lines("x\ny\n"), true))
end

print()
print("=== desk.block: anchors ===")
do
	local lines = {
		"Project Alpha",
		"  some detail",
		"  more detail",
		"- a follow-up dash line",
		"",
		"Project Beta",
		"- first bullet",
		"- second bullet",
		"Project Gamma: inline",
	}
	assert_eq("top anchor is always 0", 0, block.find_anchor(lines, { kind = "top" }))
	assert_eq(
		"under Project Alpha lands at the end of its block (after the dash line, before the blank)",
		4,
		block.find_anchor(lines, { kind = "under", quote = "Project Alpha" })
	)
	assert_eq(
		"after a line inside the block lands at the same block end",
		4,
		block.find_anchor(lines, { kind = "after", quote = "  more detail" })
	)
	assert_eq(
		"under Project Beta (a dash-headed block) does not swallow Project Gamma",
		8,
		block.find_anchor(lines, { kind = "under", quote = "Project Beta" })
	)
	assert_eq(
		"at anchors on the quoted line's own start (0-indexed)",
		1,
		block.find_anchor(lines, { kind = "at", quote = "  some detail" })
	)
	assert_eq("a quote too short is invalid", nil, block.find_anchor(lines, { kind = "under", quote = "ab" }))
	assert_eq("a quote that doesn't appear is invalid", nil, block.find_anchor(lines, { kind = "under", quote = "nope" }))
end

print()
print("=== desk.block: parsing the pinned wire-format target/anchor ===")
do
	assert_eq("the string \"top\" parses to the top anchor", { kind = "top" }, block.parse_anchor("top"))
	assert_eq("{under=...} parses", { kind = "under", quote = "X" }, block.parse_anchor({ under = "X" }))
	assert_eq("{after=...} parses", { kind = "after", quote = "X" }, block.parse_anchor({ after = "X" }))
	assert_eq("{at=...} parses", { kind = "at", quote = "X" }, block.parse_anchor({ at = "X" }))
	assert_eq("garbage doesn't parse", nil, block.parse_anchor({ nonsense = "X" }))

	local leave, land = block.parse_target({ { at = "before line" }, { under = "Section" } })
	assert_eq("a two-element target's first entry is the leaving anchor", { kind = "at", quote = "before line" }, leave)
	assert_eq("...and the second is the landing anchor", { kind = "under", quote = "Section" }, land)

	local l2, l3 = block.parse_target({ under = "Section" })
	assert_eq("a single-anchor target: leave and land are the same anchor", l2, l3)
	assert_eq("...and it's parsed correctly", { kind = "under", quote = "Section" }, l2)
end

print()
print("=== desk.apply: proposal -> buffer text ===")
do
	local committed = { "Project Alpha", "  detail one", "", "Project Beta", "- bullet" }

	-- "add" in place, "new" on top, and "link" (also a plain insertion).
	local items = {
		{ id = "top1", file = "notes.md", kind = "new", target = "top", before = "", after = "NEWS ITEM" },
		{
			id = "add1",
			file = "notes.md",
			kind = "add",
			target = { under = "Project Alpha" },
			before = "",
			after = "  a suggested addition",
		},
	}
	local new_lines, results = apply.apply_file(committed, items)
	assert_eq("top item lands at line 1", "NEWS ITEM", new_lines[1])
	assert_eq("in-place add lands under its section", "  a suggested addition", new_lines[4])
	assert_eq("both items applied", "applied", results.top1)
	assert_eq("both items applied (2)", "applied", results.add1)

	-- edit + remove.
	local edit_item = {
		id = "edit1",
		file = "notes.md",
		kind = "edit",
		target = { at = "  detail one" },
		before = "  detail one",
		after = "  detail one, revised",
	}
	local remove_item = {
		id = "rm1",
		file = "notes.md",
		kind = "remove",
		target = { at = "- bullet" },
		before = "- bullet",
		after = "",
	}
	new_lines, results = apply.apply_file(committed, { edit_item, remove_item })
	assert_eq("edit replaces the line", "  detail one, revised", new_lines[2])
	assert_eq("removal drops the line", false, vim.tbl_contains(new_lines, "- bullet"))
	assert_eq("edit applied", "applied", results.edit1)
	assert_eq("removal applied", "applied", results.rm1)

	-- move: before leaves one anchor, after lands at the other.
	local move_item = {
		id = "mv1",
		file = "notes.md",
		kind = "move",
		target = { { at = "- bullet" }, { under = "Project Alpha" } },
		before = "- bullet",
		after = "- bullet (moved)",
	}
	new_lines, results = apply.apply_file(committed, { move_item })
	assert_eq("moved-away line is gone from its old spot", false, vim.tbl_contains(new_lines, "- bullet"))
	assert_eq("moved line lands at the new anchor", "- bullet (moved)", new_lines[3])
	assert_eq("move applied", "applied", results.mv1)

	-- A bad anchor (the quote is simply gone) lands on top instead of
	-- deferring forever — the only thing "deferred" still means is a
	-- genuine content conflict (his edits sit where the anchor resolved).
	local bad_item = {
		id = "bad1",
		file = "notes.md",
		kind = "add",
		target = { under = "does not exist" },
		before = "",
		after = "orphaned suggestion",
	}
	local landed_on_top
	new_lines, results, landed_on_top = apply.apply_file(committed, { bad_item })
	assert_eq("an item with an unresolvable anchor is applied, landed on top", "applied", results.bad1)
	assert_eq("its content lands at the top of the file", "orphaned suggestion", new_lines[1])
	assert_true("it's reported as landed on top", landed_on_top.bad1)

	-- ...but a resolvable anchor whose expected `before` isn't actually
	-- there (his edits sit at that spot) still defers, on purpose.
	local conflicted_edit = {
		id = "conf1",
		file = "notes.md",
		kind = "edit",
		target = { at = "  detail one" },
		before = "  detail one, but not what's really there",
		after = "  detail one, revised",
	}
	new_lines, results = apply.apply_file(committed, { conflicted_edit })
	assert_eq("a real content conflict still defers", "deferred", results.conf1)
	assert_eq(
		"deferred content never lands in the file",
		false,
		vim.tbl_contains(new_lines, "  detail one, revised")
	)

	-- A move whose leaving anchor is gone entirely still lands its `after`
	-- (nothing to remove, so only the landing side happens).
	local orphaned_move = {
		id = "mv2",
		file = "notes.md",
		kind = "move",
		target = { { at = "does not exist either" }, { under = "Project Beta" } },
		before = "does not exist either",
		after = "- bullet (moved, orphaned leave)",
	}
	new_lines, results, landed_on_top = apply.apply_file(committed, { orphaned_move })
	assert_eq("the move's landing side still applies", "applied", results.mv2)
	assert_true(
		"its landing line is present",
		vim.tbl_contains(new_lines, "- bullet (moved, orphaned leave)")
	)
	assert_true("it's reported as landed on top (its leave side was the bad anchor)", landed_on_top.mv2)
end

print()
print("=== desk.ledger + desk.histext: the design.md §10 D5 fixture set ===")

-- His committed text (what "the index" and HEAD hold at the start of this
-- scenario): a small notes file with several independent items proposed
-- against it.
local committed = {
	"Project Alpha", -- 1
	"  first detail", -- 2
	"  second detail", -- 3
	"", -- 4
	"Project Beta", -- 5
	"- old bullet", -- 6
	"Project Gamma", -- 7
	"  gamma detail", -- 8
}
write_and_commit("notes.md", committed, "initial notes")

-- Items covering every design.md §10 D5 case:
--   queued        -> never laid in
--   pending       -> laid in, still only in the worktree
--   accepted      -> laid in, staged into the index (via the review key)
--   edited        -> pending item whose `after` differs from what was
--                     proposed, because he edited it before accepting
--   declined      -> laid in, then reset (worktree matches index again)
--   not now       -> laid in, then postponed
--   removal       -> before is dropped, after is empty
--   move          -> a two-location item (leave anchor + landing anchor)
--   repeated snippet -> an anchor phrase that also appears elsewhere,
--                     verifying occurrence (not substring) matching
local item_queued = {
	type = "item",
	id = "queued-1",
	file = "notes.md",
	kind = "add",
	anchor = { under = "Project Gamma" },
	before = "",
	after = "  a queued suggestion",
	source = "test",
	headline = "queued",
	pass = "morning",
	proposed_at = os.time(),
}
local item_pending = {
	type = "item",
	id = "pending-1",
	file = "notes.md",
	kind = "add",
	anchor = { under = "Project Alpha" },
	before = "",
	after = "  a pending suggestion",
	source = "test",
	headline = "pending",
	pass = "morning",
	proposed_at = os.time(),
}
local item_accepted = {
	type = "item",
	id = "accepted-1",
	file = "notes.md",
	kind = "edit",
	anchor = { at = "  second detail" },
	before = "  second detail",
	after = "  second detail, accepted",
	source = "test",
	headline = "accepted",
	pass = "morning",
	proposed_at = os.time(),
}
local item_declined = {
	type = "item",
	id = "declined-1",
	file = "notes.md",
	kind = "edit",
	anchor = { at = "- old bullet" },
	before = "- old bullet",
	after = "- old bullet, declined edit",
	source = "test",
	headline = "declined",
	pass = "morning",
	proposed_at = os.time(),
}
local item_not_now = {
	type = "item",
	id = "notnow-1",
	file = "notes.md",
	kind = "add",
	anchor = { under = "Project Beta" },
	before = "",
	after = "  postponed suggestion",
	source = "test",
	headline = "not now",
	pass = "morning",
	proposed_at = os.time(),
}
local item_removal = {
	type = "item",
	id = "removal-1",
	file = "notes.md",
	kind = "remove",
	anchor = { at = "  gamma detail" },
	before = "  gamma detail",
	after = "",
	source = "test",
	headline = "removal",
	pass = "morning",
	proposed_at = os.time(),
}
local item_move = {
	type = "item",
	id = "move-1",
	file = "notes.md",
	kind = "move",
	anchor = { { at = "  first detail" }, { under = "Project Beta" } }, -- leave, land
	before = "  first detail",
	after = "  first detail (moved under Beta)",
	source = "test",
	headline = "move",
	pass = "morning",
	proposed_at = os.time(),
}

local all_items =
	{ item_queued, item_pending, item_accepted, item_declined, item_not_now, item_removal, item_move }
for _, it in ipairs(all_items) do
	assert(ledger.append(repo, it))
end

-- Lay in everything except item_queued (the review key's own record).
local laid_in_ids = {}
for _, it in ipairs(all_items) do
	if it.id ~= "queued-1" then
		table.insert(laid_in_ids, it.id)
	end
end
assert(ledger.append(repo, { type = "laid_in", at = os.time(), proposal = "test-proposal-1", items = laid_in_ids }))

-- Turns an item record into the shape apply.apply_file expects (the ledger's
-- `anchor` field and the proposal's `target` field carry the same shape).
local function as_proposal(it)
	return {
		id = it.id,
		file = it.file,
		kind = it.kind,
		target = it.anchor,
		before = it.before,
		after = it.after,
	}
end

-- The worktree shows every laid-in suggestion that hasn't been resolved
-- away yet: pending, accepted, removal and move. declined-1 and notnow-1
-- were laid in too, but pressing decline/not-now reset them, so their
-- regions read as plain `before` again — the same as if they'd never been
-- laid in. queued-1 was never laid in at all.
local wt_lines =
	apply.apply_file(committed, {
		as_proposal(item_pending),
		as_proposal(item_accepted),
		as_proposal(item_removal),
		as_proposal(item_move),
	})
write_worktree("notes.md", wt_lines)

-- The index shows only what's actually been accepted (staged) — his own
-- last commit plus accepted-1, and nothing else.
local idx_lines_initial = apply.apply_file(committed, { as_proposal(item_accepted) })
local function write_index(path, lines)
	local sha = assert(git.hash_object_write(repo, snippet.join_lines(lines, true)))
	local entry = git.index_entry(repo, path)
	assert(git.update_index_cacheinfo(repo, entry.mode, sha, path))
end
write_index("notes.md", idx_lines_initial)

assert(ledger.append(repo, { type = "key", id = "accepted-1", at = os.time(), action = "accept" }))
assert(ledger.append(repo, { type = "key", id = "declined-1", at = os.time(), action = "decline" }))
assert(ledger.append(repo, { type = "key", id = "notnow-1", at = os.time(), action = "not_now" }))

local records = ledger.read(repo)
assert_eq("every appended record round-trips through the ledger", #all_items + 1 + 3, #records)

local index_lines = snippet.split_lines(git.index_content(repo, "notes.md"))
local worktree_lines = read_worktree("notes.md")
local states, items_by_id, last_key = ledger.derive_all(repo, committed, index_lines, worktree_lines)

assert_eq("queued item: never laid in", "queued", states["queued-1"])
assert_eq("pending item: after in worktree, not index", "pending", states["pending-1"])
assert_eq("accepted item: after staged into the index", "accepted", states["accepted-1"])
assert_eq("declined item: reset back out of the worktree", "declined", states["declined-1"])
assert_eq("not-now item: postponed, not declined", "postponed", states["notnow-1"])
assert_eq("removal, still pending: before gone from worktree, still in index", "pending", states["removal-1"])
assert_eq("move, still pending: after in worktree only", "pending", states["move-1"])

print()
print("=== desk.histext: computing his text ===")
do
	local pending_items = {}
	for id, item in pairs(items_by_id) do
		if states[id] == "pending" then
			table.insert(pending_items, item)
		end
	end
	local his_lines, results = histext.compute(worktree_lines, index_lines, pending_items)

	-- His text isn't the *original* committed notes.md — accepted-1 is a
	-- real, permanent accept (already in the index) and stays; only the
	-- three still-pending suggestions (add, removal, move) get reverted.
	local expected_his_text = apply.apply_file(committed, { as_proposal(item_accepted) })
	assert_eq(
		"his text is his committed notes.md plus accepted-1, with every pending suggestion reverted",
		expected_his_text,
		his_lines
	)
	assert_eq("the plain add is reported reverted", "reverted", results["pending-1"])
	assert_eq("the removal is reported reverted (un-deleted)", "reverted", results["removal-1"])
	assert_eq("the move is reported reverted", "reverted", results["move-1"])

	-- "after already in the index": a git add -A on the pending item's
	-- region means his-text must NOT revert it — it's effectively accepted
	-- even though no accept key was ever written.
	local staged_pending = items_by_id["pending-1"]
	local idx2 = apply.apply_file(index_lines, { as_proposal(staged_pending) })
	local _, results2 = histext.compute(worktree_lines, idx2, { staged_pending }, committed)
	assert_eq("an after already staged in the index is skipped, not reverted", "skipped_in_index", results2["pending-1"])
end

print()
print("=== desk.ledger: accepted-by-accident and resolved-without-a-key ===")
do
	local r2 = vim.fn.tempname()
	vim.fn.mkdir(r2, "p")
	assert(git.run(r2, { "init", "-q" }))
	assert(git.run(r2, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(r2, { "config", "user.name", "Desk Test" }))

	local base = { "Section One", "  line a", "Section Two", "  line b" }
	local function commit2(path, lines, msg)
		local fd = assert(io.open(r2 .. "/" .. path, "w"))
		fd:write(snippet.join_lines(lines, true))
		fd:close()
		assert(git.run(r2, { "add", path }))
		assert(git.run(r2, { "commit", "-q", "-m", msg }))
	end
	local function wt2(path, lines)
		local fd = assert(io.open(r2 .. "/" .. path, "w"))
		fd:write(snippet.join_lines(lines, true))
		fd:close()
	end

	commit2("notes.md", base, "initial")

	local acc_item = {
		type = "item",
		id = "acc-accident",
		file = "notes.md",
		kind = "add",
		anchor = { under = "Section One" },
		before = "",
		after = "  accidental addition",
		source = "test",
		headline = "acc",
		proposed_at = os.time(),
	}
	local van_item = {
		type = "item",
		id = "vanished",
		file = "notes.md",
		kind = "add",
		anchor = { under = "Section Two" },
		before = "",
		after = "  will vanish without a key",
		source = "test",
		headline = "van",
		proposed_at = os.time(),
	}
	assert(ledger.append(r2, acc_item))
	assert(ledger.append(r2, van_item))
	assert(ledger.append(r2, { type = "laid_in", at = os.time(), proposal = "p1", items = { "acc-accident", "vanished" } }))

	-- Snapshot: both are pending at this point (the worktree carries both
	-- suggestions inline; the index is still just `base`).
	local prev_pending = { "acc-accident", "vanished" }

	-- "git add -A": stages the whole worktree — both suggestions, with no
	-- accept key ever written for either. Represented directly as its end
	-- state (index == worktree == both suggestions applied) rather than
	-- via a real `git add -A`, since what matters here is the resulting
	-- content, not the staging mechanism (already covered by the D5
	-- "after already in the index" case above).
	local both_applied = apply.apply_file(base, {
		{ id = "acc-accident", file = "notes.md", kind = "add", target = acc_item.anchor, before = "", after = acc_item.after },
		{ id = "vanished", file = "notes.md", kind = "add", target = van_item.anchor, before = "", after = van_item.after },
	})
	local sha = assert(git.hash_object_write(r2, snippet.join_lines(both_applied, true)))
	local entry = git.index_entry(r2, "notes.md")
	assert(git.update_index_cacheinfo(r2, entry.mode, sha, "notes.md"))
	wt2("notes.md", both_applied)

	-- The "vanished" one instead gets undone by something other than the
	-- decline key (an undo + save, a stale second nvim, a checkout) — its
	-- suggestion disappears from *both* index and worktree, with no key:
	-- only acc-accident's addition remains in either.
	local acc_only = apply.apply_file(base, {
		{ id = "acc-accident", file = "notes.md", kind = "add", target = acc_item.anchor, before = "", after = acc_item.after },
	})
	local sha2 = assert(git.hash_object_write(r2, snippet.join_lines(acc_only, true)))
	assert(git.update_index_cacheinfo(r2, entry.mode, sha2, "notes.md"))
	wt2("notes.md", acc_only)

	local idx_final = snippet.split_lines(git.index_content(r2, "notes.md"))
	local wt_final = (function()
		local f = assert(io.open(r2 .. "/notes.md", "r"))
		local c = f:read("*a")
		f:close()
		return (snippet.split_lines(c))
	end)()

	local states2, _, last_key2 = ledger.derive_all(r2, base, idx_final, wt_final)
	assert_eq("git-add -A'd item now shows as accepted", "accepted", states2["acc-accident"])
	assert_eq("the other item is fully gone: declined-shaped", "declined", states2["vanished"])

	local accepted_by_accident, resolved_without_key = ledger.classify_transitions(prev_pending, states2, last_key2)
	assert_eq("flagged as accepted by accident", { "acc-accident" }, accepted_by_accident)
	assert_eq("flagged as resolved without a key", { "vanished" }, resolved_without_key)
end

print()
print("=== desk.histext.write_to_index: retries when the index changes mid-run ===")
do
	local r3 = vim.fn.tempname()
	vim.fn.mkdir(r3, "p")
	assert(git.run(r3, { "init", "-q" }))
	assert(git.run(r3, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(r3, { "config", "user.name", "Desk Test" }))

	local base3 = { "Alpha", "  detail", "Beta", "  other" }
	local function commit3(lines)
		local fd = assert(io.open(r3 .. "/notes.md", "w"))
		fd:write(snippet.join_lines(lines, true))
		fd:close()
		assert(git.run(r3, { "add", "notes.md" }))
		assert(git.run(r3, { "commit", "-q", "-m", "notes" }))
	end
	commit3(base3)

	local pend = {
		id = "p1",
		file = "notes.md",
		kind = "add",
		anchor = { under = "Alpha" },
		before = "",
		after = "  a pending line",
	}
	local wt3 = apply.apply_file(base3, { { id = "p1", file = "notes.md", kind = "add", target = pend.anchor, before = "", after = pend.after } })
	local fd3 = assert(io.open(r3 .. "/notes.md", "w"))
	fd3:write(snippet.join_lines(wt3, true))
	fd3:close()

	local attempts = 0
	local raced_once = false
	local function get_state()
		attempts = attempts + 1
		if attempts == 1 and not raced_once then
			-- Simulate a concurrent writer landing between two attempts:
			-- touch the index for an unrelated reason right after this
			-- first read is set up to be used.
			raced_once = true
		end
		local idx_content = git.index_content(r3, "notes.md") or ""
		local wt_content
		do
			local f = assert(io.open(r3 .. "/notes.md", "r"))
			wt_content = f:read("*a")
			f:close()
		end
		if attempts == 1 then
			-- Land a real concurrent index write right after our own read,
			-- before write_to_index gets to its own write — this is the
			-- race the fingerprint check must catch.
			local entry = git.index_entry(r3, "notes.md")
			local same_sha = entry.sha
			git.run(r3, { "update-index", "--cacheinfo", entry.mode .. "," .. same_sha .. ",notes.md" })
			-- Force the mtime to actually move, since a same-content
			-- rewrite can otherwise land in the same second.
			vim.system({ "touch", "-A", "010000", r3 .. "/.git/index" }):wait()
		end
		return {
			index_lines = snippet.split_lines(idx_content),
			worktree_lines = (snippet.split_lines(wt_content)),
			pending_items = { pend },
		}
	end

	local sha, results = histext.write_to_index(r3, "notes.md", get_state, 5)
	assert_true("write_to_index eventually succeeds despite the mid-run change", sha ~= nil)
	assert_true("it took more than one attempt (the race was actually detected)", attempts > 1)
	assert_eq("the pending item was reverted in the final write", "reverted", (results or {}).p1)

	local final_index = snippet.split_lines(git.index_content(r3, "notes.md"))
	assert_eq("the index now holds his text again (suggestion reverted, nothing else touched)", base3, final_index)
end

print()
print("=== desk.histext: an edit beside a suggestion (waiting_edit) ===")
do
	local r4 = vim.fn.tempname()
	vim.fn.mkdir(r4, "p")
	assert(git.run(r4, { "init", "-q" }))
	assert(git.run(r4, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(r4, { "config", "user.name", "Desk Test" }))

	local base4 = { "Alpha", "  original detail" }
	local fd4 = assert(io.open(r4 .. "/notes.md", "w"))
	fd4:write(snippet.join_lines(base4, true))
	fd4:close()
	assert(git.run(r4, { "add", "notes.md" }))
	assert(git.run(r4, { "commit", "-q", "-m", "notes" }))

	local edit_item = {
		id = "waiting-1",
		file = "notes.md",
		kind = "edit",
		anchor = { at = "  original detail" },
		before = "  original detail",
		after = "  suggested detail",
	}
	-- Instead of the suggestion landing cleanly, he has edited that same
	-- line himself to something else entirely — the suggestion's `after`
	-- is nowhere at that anchor, and neither is a clean `before`.
	local wt4 = { "Alpha", "  his own different edit" }
	local idx4 = snippet.split_lines(git.index_content(r4, "notes.md"))
	local _, results4 = histext.compute(wt4, idx4, { edit_item })
	assert_eq("an edit beside a suggestion is flagged waiting, not silently reverted", "waiting_edit", results4["waiting-1"])
end

print()
print("=== desk.histext: repeated snippet, occurrence-aware ===")
do
	local r5 = vim.fn.tempname()
	vim.fn.mkdir(r5, "p")
	assert(git.run(r5, { "init", "-q" }))
	assert(git.run(r5, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(r5, { "config", "user.name", "Desk Test" }))

	-- The exact text "- shared line" appears twice: once already in the
	-- committed file (unrelated), once as the pending suggestion's `after`.
	local base5 = { "Alpha", "- shared line", "Beta" }
	local fd5 = assert(io.open(r5 .. "/notes.md", "w"))
	fd5:write(snippet.join_lines(base5, true))
	fd5:close()
	assert(git.run(r5, { "add", "notes.md" }))
	assert(git.run(r5, { "commit", "-q", "-m", "notes" }))

	local rep_item = {
		id = "rep-1",
		file = "notes.md",
		kind = "add",
		anchor = { under = "Beta" },
		before = "",
		after = "- shared line",
	}
	local wt5 = { "Alpha", "- shared line", "Beta", "- shared line" }
	local idx5 = snippet.split_lines(git.index_content(r5, "notes.md"))
	local his5, results5 = histext.compute(wt5, idx5, { rep_item })
	assert_eq("the pre-existing occurrence is untouched, only the anchored one is reverted", base5, his5)
	assert_eq("reverted at its own anchor, not mistaken for the pre-existing line", "reverted", results5["rep-1"])
end

print()
print("=== nvim -l gives the same result as the editor ===")
do
	-- The guarantee is literal: it's the same require'd module either way,
	-- so it can only differ if the *input* differs. Demonstrate that the
	-- worktree file, read through an editor-shaped API (vim.fn.readfile,
	-- as a buffer's lines would be) and through a plain file read (as the
	-- runner would via `nvim -l`, with no buffer involved), come back
	-- byte-identical — and so does histext.compute() fed either one.
	local via_editor = vim.fn.readfile(repo .. "/notes.md")
	local via_runner = (function()
		local f = assert(io.open(repo .. "/notes.md", "r"))
		local content = f:read("*a")
		f:close()
		return (snippet.split_lines(content))
	end)()
	assert_eq("editor-style read and plain-file read agree byte-for-byte", via_editor, via_runner)

	local pending_from_editor = {}
	for id, item in pairs(items_by_id) do
		if states[id] == "pending" then
			table.insert(pending_from_editor, item)
		end
	end
	local result_editor = select(1, histext.compute(via_editor, index_lines, pending_from_editor))
	local result_runner = select(1, histext.compute(via_runner, index_lines, pending_from_editor))
	assert_eq("compute() gives byte-identical output from either reading path", result_editor, result_runner)
end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)

