-- Ledger tests: desk.ledger.namespace_ids (id collisions across passes/days
-- and against carried items) and the decision records (decline / restore /
-- taken) in isolation. desk-proposal-test.lua and desk-review-test.lua cover
-- them wired into the proposal build and the review split.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-ledger-test.lua
local ledger = require("desk.ledger")
local git = require("desk.git")
local git_safety_here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local git_safety = dofile(git_safety_here .. "/../../tests/lib/git-safety.lua")


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
print("=== namespace_ids: carried items' ids are never reused ===")
do
	local repo = new_repo()
	local out = ledger.namespace_ids(
		repo,
		"morning",
		"2026-10-01",
		{ { id = "x", file = "notes.md", kind = "new", target = "top", before = "", after = "a" } },
		{ "morning-2026-10-01-1-x" }
	)
	assert_eq("bumped past the carried id", "morning-2026-10-01-2-x", out[1].id)
end

print()
print("=== decisions: decline, restore and taken records ===")
do
	local repo = new_repo()
	local a = { id = "d1", file = "notes.md", kind = "new", before = "", after = "A text", source = "https://example.invalid/a", headline = "A" }
	local b = { id = "d2", file = "notes.md", kind = "remove", before = "B text", after = "", source = "", headline = "B" }

	assert_true("declining records", ledger.record_declines(repo, { a, b }))
	local declined = ledger.declined(ledger.read(repo))
	assert_true("both are declined by id", declined.ids.d1 ~= nil and declined.ids.d2 ~= nil)
	assert_true("the URL source is blocked", declined.sources["https://example.invalid/a"] == true)
	assert_true("an empty source blocks nothing", declined.sources[""] == nil)

	assert_true("restoring a declined id works", ledger.restore_declined(repo, "d1"))
	declined = ledger.declined(ledger.read(repo))
	assert_true("it is no longer declined", declined.ids.d1 == nil and declined.ids.d2 ~= nil)
	assert_true("nor is its source blocked", declined.sources["https://example.invalid/a"] == nil)
	assert_eq("the restored item waits for the next pass", { "d1" }, vim.tbl_map(function(it)
		return it.id
	end, ledger.restored(ledger.read(repo))))
	ledger.append(repo, { type = "restore_applied", id = "d1" })
	assert_eq("a pass that re-proposed it clears the wait", 0, #ledger.restored(ledger.read(repo)))
	assert_true("declining it again works", ledger.record_declines(repo, { a }))
	assert_true("and it is declined again", ledger.declined(ledger.read(repo)).ids.d1 ~= nil)

	assert_true("taken records", ledger.record_taken(repo, { a, b }))
	assert_true("again records nothing new", ledger.record_taken(repo, { a }))
	local taken = ledger.taken_by_id(ledger.read(repo))
	assert_eq("a hash of the after text", ledger.content_hash(a), taken.d1.hash)
	assert_eq("a removal hashes its before", vim.fn.sha256("B text"), taken.d2.hash)
	local n = 0
	for _, r in ipairs(ledger.read(repo)) do
		if r.type == "taken" then
			n = n + 1
		end
	end
	assert_eq("one record per item", 2, n)
end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
