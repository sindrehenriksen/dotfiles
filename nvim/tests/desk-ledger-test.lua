-- Ledger tests for the surfaces a neutral review found wired to nothing:
-- desk.ledger.namespace_ids (id collisions across passes/days),
-- desk.ledger.write_pending_snapshot/read_pending_snapshot (the §9(g)
-- round trip), and desk.ledger.classify_transitions/declined_recently as
-- pure functions in isolation (desk-review-test.lua covers them wired into
-- the interactive review key/declined-recently list; this file covers
-- their own direct behavior).
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-ledger-test.lua
local ledger = require("desk.ledger")
local git = require("desk.git")
local git_safety_here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local git_safety = dofile(git_safety_here .. "/../../tests/lib/git-safety.lua")

-- Sandboxed: desk.ledger.pending_snapshot_path resolves under
-- $DESK_STATE_DIR (real default ~/.local/state/desk), same as every other
-- desk-lib state file — never the real one from a test run.
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

local function new_repo()
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	git_safety.assert_repo_under_tmp(repo)
	assert(git.run(repo, { "init", "-q" }))
	assert(git.run(repo, { "config", "user.email", "test@example.invalid" }))
	assert(git.run(repo, { "config", "user.name", "Desk Test" }))
	local fd = assert(io.open(repo .. "/notes.md", "w"))
	fd:write("Alpha\n")
	fd:close()
	assert(git.run(repo, { "add", "notes.md" }))
	assert(git.run(repo, { "commit", "-q", "-m", "initial" }))
	return repo
end

print("=== desk.ledger.namespace_ids: model ids namespaced, unique across the ledger ===")
do
	local repo = new_repo()

	-- Two same-pass items that both call themselves "c1" (two 16:30
	-- closure captures on the same day) get distinct namespaced ids.
	local out = ledger.namespace_ids(repo, "close", "2026-09-29", {
		{ id = "c1", file = "notes.md", kind = "new", target = "top", before = "", after = "first" },
		{ id = "c1", file = "notes.md", kind = "new", target = "top", before = "", after = "second" },
	})
	assert_eq("first item's id", "close-2026-09-29-1-c1", out[1].id)
	assert_eq("second item's id (same model id, different seq)", "close-2026-09-29-2-c1", out[2].id)
	assert_true("everything but id is untouched", out[1].after == "first" and out[2].after == "second")

	-- Record the first day's "j1" as a real ledger item (as if a prior
	-- pass had already namespaced and appended it) — Tuesday's own "j1"
	-- must not inherit it: a different (pass, date) is already a
	-- different namespaced id, so there's nothing to even collide on.
	ledger.append(repo, { type = "item", id = "morning-2026-09-29-1-j1", file = "notes.md" })
	local tuesday = ledger.namespace_ids(repo, "morning", "2026-09-30", {
		{ id = "j1", file = "notes.md", kind = "new", target = "top", before = "", after = "tuesday's own" },
	})
	assert_eq("a new day's j1 gets its own namespaced id, no collision", "morning-2026-09-30-1-j1", tuesday[1].id)

	-- A retried pass that would otherwise reproduce the exact same
	-- candidate id bumps seq past whatever's already in the ledger.
	ledger.append(repo, { type = "item", id = "morning-2026-09-30-1-j1", file = "notes.md" })
	local retried = ledger.namespace_ids(repo, "morning", "2026-09-30", {
		{ id = "j1", file = "notes.md", kind = "new", target = "top", before = "", after = "retried" },
	})
	assert_eq(
		"a colliding candidate is skipped past, staying unique across the whole ledger",
		"morning-2026-09-30-2-j1",
		retried[1].id
	)
end

print()
print("=== desk.ledger pending-set snapshot: round-trips atomically ===")
do
	local repo = new_repo()
	local path = ledger.pending_snapshot_path(repo, "notes.md")
	assert_true("nothing written yet: nil, not an error", ledger.read_pending_snapshot(path) == nil)

	ledger.write_pending_snapshot(path, "deadbeef", { "p1", "p2" })
	local snap = ledger.read_pending_snapshot(path)
	assert_true("a snapshot was written and reads back", snap ~= nil)
	assert_eq("its head sha round-trips", "deadbeef", snap.head)
	assert_eq("its pending ids round-trip", { "p1", "p2" }, snap.items)

	-- Two different (repo, file) pairs never share a path.
	local other_path = ledger.pending_snapshot_path(repo, "reading.md")
	assert_true("a different file gets a different snapshot path", other_path ~= path)
end

print()
print("=== desk.ledger.classify_transitions: accepted-by-accident vs. resolved-without-a-key ===")
do
	local prev_pending = { "acc1", "dec1", "clean1" }
	local states = { acc1 = "accepted", dec1 = "declined", clean1 = "declined" }
	local last_key = { clean1 = { action = "decline" } } -- dec1 has no key at all; acc1 has no accept key
	local accepted_by_accident, resolved_without_key = ledger.classify_transitions(prev_pending, states, last_key)
	assert_eq("acc1 is accepted with no accept key: accepted by accident", { "acc1" }, accepted_by_accident)
	assert_eq("dec1 is declined with no decline key: resolved without a key", { "dec1" }, resolved_without_key)
end

print()
print("=== desk.ledger.declined_recently: within the window, restorable ===")
do
	local repo = new_repo()
	local head = { "Alpha" }
	local long_ago = os.time() - 30 * 86400
	local item = {
		id = "p1",
		file = "notes.md",
		kind = "add",
		anchor = { under = "Alpha" },
		before = "",
		after = "  a declined suggestion",
		proposed_at = long_ago,
	}
	ledger.append(repo, {
		type = "item",
		id = item.id,
		file = item.file,
		kind = item.kind,
		anchor = item.anchor,
		before = item.before,
		after = item.after,
		headline = "a declined suggestion",
		proposed_at = item.proposed_at,
	})
	ledger.append(repo, { type = "laid_in", at = long_ago, proposal = "seed", items = { "p1" } })
	ledger.append(repo, { type = "key", id = "p1", at = long_ago, action = "decline" })

	-- After the decline, the content is gone from both index and worktree.
	-- Its decline key is 30 days old: outside a 14-day window, inside a
	-- 60-day one.
	local outside_window = ledger.declined_recently(repo, head, head, head, 14)
	assert_eq("a 14-day window doesn't reach a 30-day-old decline", 0, #outside_window)

	local inside_window = ledger.declined_recently(repo, head, head, head, 60)
	assert_eq("exactly one declined-recently item in a 60-day window", 1, #inside_window)
	assert_eq("its id is p1", "p1", inside_window[1].item.id)
	assert_eq("its reason is 'declined' (there IS a decline key)", "declined", inside_window[1].reason)
end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
