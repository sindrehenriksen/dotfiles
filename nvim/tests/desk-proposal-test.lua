-- The proposal commit (desk.proposal) and the decision ledger (desk.ledger),
-- headless against throwaway repos: one proposal commit per pass, built from
-- his newest HEAD plus untaken/undeclined items from the previous one, taken
-- and declined tracked without positions.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-proposal-test.lua
local proposal = require("desk.proposal")
local ledger = require("desk.ledger")
local git = require("desk.git")
local snippet = require("desk.snippet")
local git_safety = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or ".") .. "/../../tests/lib/git-safety.lua")

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

local FILES = { "notes.md", "reading.md" }

local function write(repo, file, lines)
	local fd = assert(io.open(repo .. "/" .. file, "w"))
	fd:write(snippet.join_lines(lines, true))
	fd:close()
end

local function commit_all(repo, msg)
	assert(git.run(repo, { "add", "-A" }))
	assert(git.run(repo, { "commit", "-q", "-m", msg }))
end

local function new_repo(notes)
	local repo = vim.fn.tempname()
	vim.fn.mkdir(repo, "p")
	git_safety.assert_repo_under_tmp(repo)
	assert(git.run(repo, { "init", "-q" }))
	write(repo, "notes.md", notes)
	write(repo, "reading.md", {})
	commit_all(repo, "initial")
	return repo
end

local function item(id, over)
	return vim.tbl_extend("force", {
		id = id,
		file = "notes.md",
		kind = "new",
		target = "top",
		before = "",
		after = "NEWS " .. id,
		source = "https://example.invalid/" .. id,
		headline = "headline " .. id,
	}, over or {})
end

local function ids(items)
	local out = {}
	for _, it in ipairs(items) do
		out[#out + 1] = it.id
	end
	table.sort(out)
	return out
end

local function tip_lines(repo, file)
	return proposal.lines_at(repo, proposal.REF, file)
end

print("=== one proposal commit: parent is his HEAD, tree has applied files + proposal.json ===")
local repo = new_repo({ "Section A", "  existing" })
local head = vim.trim(select(2, git.run(repo, { "rev-parse", "HEAD" })))
local sha, stats = proposal.build(repo, "morning", "2026-10-01", {
	item("n1"),
	item("a1", { kind = "add", target = { under = "Section A" }, after = "  added", source = "" }),
	item("r1", { file = "reading.md", kind = "new", after = "READ r1" }),
}, FILES)
assert_true("build returns a sha", sha ~= nil)
local p = proposal.read(repo)
assert_eq("parent is his HEAD at pass time", head, p.parent)
assert_eq("notes.md has news on top and the add under its section", { "NEWS n1", "Section A", "  existing", "  added" }, {
	(tip_lines(repo, "notes.md")[1]:gsub("^(NEWS n1).*", "%1")),
	tip_lines(repo, "notes.md")[2],
	tip_lines(repo, "notes.md")[3],
	tip_lines(repo, "notes.md")[4],
})
assert_eq("reading item goes into reading.md", { "READ r1" }, tip_lines(repo, "reading.md"))
assert_eq("his HEAD is untouched", { "Section A", "  existing" }, proposal.lines_at(repo, "HEAD", "notes.md"))
assert_eq("three open items", 3, #proposal.open_items(repo))
assert_eq("items carry id/kind/file/headline/source/before/after", { "headline n1", "https://example.invalid/n1", "", "NEWS n1" },
	(function()
		for _, it in ipairs(p.items) do
			if it.headline == "headline n1" then
				return { it.headline, it.source, it.before, it.after }
			end
		end
	end)()
)

print("\n=== a second pass before review: carries the untaken items, batched with new ones ===")
local first_ids = ids(p.items)
local sha2 = proposal.build(repo, "1630", "2026-10-01", { item("n2") }, FILES)
local p2 = proposal.read(repo)
assert_true("the ref moved to a new commit", sha2 ~= sha)
assert_eq("still exactly one commit on his HEAD", head, p2.parent)
assert_eq("carried (same ids) plus the new one", 4, #p2.items)
for _, id in ipairs(first_ids) do
	local found = false
	for _, it in ipairs(p2.items) do
		found = found or it.id == id
	end
	assert_true("carried id still present: " .. id, found)
end
assert_eq("the morning news stays above the 16:30 item", "1630-2026-10-01-1-n2", p2.items[#p2.items].id)

print("\n=== taken: after content in HEAD marks it taken, recorded once, and it is not carried ===")
write(repo, "notes.md", { "NEWS n1", "Section A", "  existing" })
-- his taken text is the proposal's `after`, namespaced ids notwithstanding
local n1 = vim.tbl_filter(function(it)
	return it.headline == "headline n1"
end, p2.items)[1]
write(repo, "notes.md", { n1.after, "Section A", "  existing" })
commit_all(repo, "notes")
local newly = proposal.sync_taken(repo)
assert_eq("sync records the taken item", { n1.id }, ids(newly))
assert_eq("a second sync records nothing new", 0, #proposal.sync_taken(repo))
local taken = ledger.taken_by_id(ledger.read(repo))
assert_eq("taken record keeps the content hash", ledger.content_hash(n1), taken[n1.id].hash)
assert_eq("open items no longer include it", 3, #proposal.open_items(repo))

print("\n=== his own edits after the pass are not proposal content ===")
local sha3 = proposal.build(repo, "morning", "2026-10-02", {}, FILES)
local p3 = proposal.read(repo)
assert_eq("the taken item is not carried", 3, #p3.items)
assert_eq("parent is his newest HEAD", vim.trim(select(2, git.run(repo, { "rev-parse", "HEAD" }))), p3.parent)
assert_true("tip notes keep his committed line", vim.tbl_contains(tip_lines(repo, "notes.md"), n1.after))

print("\n=== declined: by id and by source, never re-proposed; restore brings it back ===")
local victim
for _, it in ipairs(p3.items) do
	victim = victim or (it.headline == "headline n2" and it) or nil
end
victim = victim or p3.items[1]
assert_true("decline recorded", ledger.record_declines(repo, { victim }))
assert_eq("declining twice records once", true, ledger.record_declines(repo, { victim }))
local declines = 0
for _, r in ipairs(ledger.read(repo)) do
	if r.type == "decline" then
		declines = declines + 1
	end
end
assert_eq("one decline record", 1, declines)
proposal.build(repo, "morning", "2026-10-03", { item("again", { source = victim.source, after = "NEWS again" }) }, FILES)
local p4 = proposal.read(repo)
local function has_headline(items, h)
	for _, it in ipairs(items) do
		if it.headline == h then
			return true
		end
	end
	return false
end
assert_true("the declined item is not carried", not has_headline(p4.items, victim.headline))
assert_true("a new item with the same source URL is not proposed", not has_headline(p4.items, "headline again"))
assert_true("the other items are still carried", #p4.items == 2)

assert_true("restore succeeds", ledger.restore_declined(repo, victim.id))
assert_eq("restore of a non-declined id fails", false, (ledger.restore_declined(repo, victim.id)))
proposal.build(repo, "morning", "2026-10-04", {}, FILES)
local p5 = proposal.read(repo)
assert_true("the restored item is proposed again", has_headline(p5.items, victim.headline))
proposal.build(repo, "morning", "2026-10-05", {}, FILES)
local p6 = proposal.read(repo)
local count = 0
for _, it in ipairs(p6.items) do
	if it.id == victim.id then
		count = count + 1
	end
end
assert_eq("and exactly once, carried thereafter", 1, count)
assert_true("a source declined earlier is allowed again after restore", ledger.declined(ledger.read(repo)).sources[victim.source] == nil)

print("\n=== a same-source new item replaces the carried one; supersedes drops it ===")
local repo2 = new_repo({ "Section A" })
proposal.build(repo2, "morning", "2026-10-01", { item("x", { source = "https://example.invalid/same", after = "OLD" }) }, FILES)
proposal.build(repo2, "morning", "2026-10-02", { item("y", { source = "https://example.invalid/same", after = "NEW" }) }, FILES)
local q = proposal.read(repo2)
assert_eq("one item left, the new version", { "NEW" }, vim.tbl_map(function(it)
	return it.after
end, q.items))
local carried_id = q.items[1].id
proposal.build(repo2, "morning", "2026-10-03", { item("z", { source = "", after = "ZED", supersedes = carried_id }) }, FILES)
assert_eq("explicit supersedes drops it", { "ZED" }, vim.tbl_map(function(it)
	return it.after
end, proposal.read(repo2).items))

print("\n=== an item that does not apply cleanly is carried flagged deferred, not shown ===")
local repo3 = new_repo({ "Section A", "  keep" })
proposal.build(repo3, "morning", "2026-10-01", {
	item("e", { kind = "edit", target = { at = "  keep" }, before = "  keep\n  other", after = "  changed", source = "" }),
}, FILES)
local d = proposal.read(repo3)
assert_eq("one item", 1, #d.items)
assert_true("flagged deferred", d.items[1].deferred == true)
assert_eq("not counted as open", 0, #proposal.open_items(repo3))
assert_eq("the tree is just his HEAD text", { "Section A", "  keep" }, tip_lines(repo3, "notes.md"))

print("\n=== a removal is taken when its before is gone from HEAD ===")
local repo4 = new_repo({ "Section A", "  stale", "  keep" })
proposal.build(repo4, "morning", "2026-10-01", {
	item("rm", { kind = "remove", target = { at = "  stale" }, before = "  stale", after = "", source = "" }),
}, FILES)
assert_eq("proposal drops the line", { "Section A", "  keep" }, tip_lines(repo4, "notes.md"))
write(repo4, "notes.md", { "Section A", "  keep" })
commit_all(repo4, "he removed it")
assert_eq("sync takes it", 1, #proposal.sync_taken(repo4))

print("\n=== declining a non-URL-sourced item never blocks other items by source ===")
do
	local r = new_repo({ "Section A", "  existing" })
	local running = item("c1", { after = "sess-foo: running", source = "session:11111111-1111-1111-1111-111111111111", headline = "capture running" })
	proposal.build(r, "1630", "2026-10-01", { running, item("t1", { after = "ticket one", source = "ticket:ABC-12", headline = "t one" }) }, FILES)
	local items = proposal.read(r).items
	ledger.record_declines(r, items)
	assert_eq("non-URL sources never enter the blocked-source set", 0, #vim.tbl_keys(ledger.declined(ledger.read(r)).sources))
	proposal.build(r, "1630", "2026-10-02", {
		item("c2", { after = "sess-foo: closed", source = "session:11111111-1111-1111-1111-111111111111", headline = "capture closed" }),
		item("t2", { after = "ticket two", source = "ticket:ABC-12", headline = "t two" }),
	}, FILES)
	local hs = vim.tbl_map(function(it) return it.headline end, proposal.read(r).items)
	table.sort(hs)
	assert_eq("a later close capture and a later ticket item are still proposed", { "capture closed", "t two" }, hs)
end

print("\n=== a postponed non-URL item is not superseded by an unrelated one sharing its source ===")
do
	local r = new_repo({ "Section A", "  existing", "Section B", "  other" })
	proposal.build(r, "morning", "2026-10-01", { item("m1", { kind = "add", target = { under = "Section A" }, after = "  - link: design doc", source = "notes", headline = "postponed add A" }) }, FILES)
	local _, st = proposal.build(r, "morning", "2026-10-02", { item("m2", { kind = "add", target = { under = "Section B" }, after = "  - link: runbook", source = "notes", headline = "new add B" }) }, FILES)
	local hs = vim.tbl_map(function(it) return it.headline end, proposal.read(r).items)
	table.sort(hs)
	assert_eq("both items are in the proposal", { "new add B", "postponed add A" }, hs)
	assert_eq("nothing was superseded", 0, st.superseded)
	local _, st2 = proposal.build(r, "morning", "2026-10-03", { item("m3", { kind = "add", target = { under = "Section A" }, after = "  - link: newer doc", source = "notes", headline = "newer add A" }) }, FILES)
	assert_eq("replacing a carried item at the same place is counted", 1, st2.superseded)
end

print("\n=== presence is judged at the anchored occurrence, not anywhere in the file ===")
do
	-- an add whose line exists elsewhere is still proposed
	local r = new_repo({ "Section A", "  existing", "Section B", "  - link: design doc" })
	proposal.build(r, "morning", "2026-10-01", { item("a1", { kind = "add", target = { under = "Section A" }, after = "  - link: design doc", source = "notes", headline = "add A" }) }, FILES)
	assert_eq("an add whose line exists under another section is proposed", { "add A" }, vim.tbl_map(function(it) return it.headline end, proposal.read(r).items))
	assert_eq("and is open", 1, #proposal.open_items(r))
	assert_eq("and the proposal text has it under Section A", { "Section A", "  existing", "  - link: design doc", "Section B", "  - link: design doc" }, tip_lines(r, "notes.md"))

	-- a move whose `after` equals its `before` at another place is evaluated at the landing anchor
	local r2 = new_repo({ "Section A", "  - ping Kari", "Section B", "  - other" })
	proposal.build(r2, "morning", "2026-10-01", { item("mv", { kind = "move", target = { { at = "  - ping Kari" }, { under = "Section B" } }, before = "  - ping Kari", after = "  - ping Kari", source = "notes", headline = "move ping" }) }, FILES)
	assert_eq("a move is proposed although its text sits at the leaving place", 1, #proposal.open_items(r2))
	assert_eq("applied at the landing place, gone from the leaving one", { "Section A", "Section B", "  - other", "  - ping Kari" }, tip_lines(r2, "notes.md"))
	write(r2, "notes.md", { "Section A", "  - ping Kari", "Section B", "  - other", "  - ping Kari" })
	commit_all(r2, "he copied it down only")
	assert_eq("landing alone counts as taken", 1, #proposal.sync_taken(r2))

	-- a removal of a repeated line targets the anchored occurrence
	local rep = { "Section A", "  - ping Kari", "Section B", "  - ping Kari" }
	local r3 = new_repo(rep)
	proposal.build(r3, "morning", "2026-10-01", { item("rm", { kind = "remove", target = { at = "  - ping Kari" }, before = "  - ping Kari", after = "", source = "notes", headline = "drop ping" }) }, FILES)
	write(r3, "notes.md", { "Section A", "  - ping Kari", "Section B" })
	commit_all(r3, "he removed the second copy")
	assert_eq("removing the other copy does not take it", 0, #proposal.sync_taken(r3))
	assert_eq("it is still open", 1, #proposal.open_items(r3))
	local r4 = new_repo(rep)
	proposal.build(r4, "morning", "2026-10-01", { item("rm", { kind = "remove", target = { at = "  - ping Kari" }, before = "  - ping Kari", after = "", source = "notes", headline = "drop ping" }) }, FILES)
	write(r4, "notes.md", { "Section A", "Section B", "  - ping Kari" })
	commit_all(r4, "he removed the first copy")
	assert_eq("removing the anchored copy takes it although another copy remains", 1, #proposal.sync_taken(r4))
end

print("\n=== a news URL already taken or declined is never proposed again ===")
do
	local r = new_repo({ "Section A", "  existing" })
	proposal.build(r, "morning", "2026-10-01", {
		item("t", { source = "https://example.invalid/taken-story", after = "NEWS taken story", headline = "taken story" }),
		item("d", { source = "https://example.invalid/declined-story", after = "NEWS declined story", headline = "declined story" }),
	}, FILES)
	write(r, "notes.md", { "NEWS taken story", "Section A", "  existing" })
	commit_all(r, "he took it")
	proposal.sync_taken(r)
	for _, it in ipairs(proposal.read(r).items) do
		if it.headline == "declined story" then
			ledger.record_declines(r, { it })
		end
	end
	local _, st = proposal.build(r, "morning", "2026-10-02", {
		item("t2", { source = "https://example.invalid/taken-story", after = "NEWS taken story again", headline = "taken again" }),
		item("d2", { source = "https://example.invalid/declined-story", after = "NEWS declined again", headline = "declined again" }),
		item("f", { source = "https://example.invalid/fresh", after = "NEWS fresh", headline = "fresh story" }),
	}, FILES)
	assert_eq("only the unseen story is proposed", { "fresh story" }, vim.tbl_map(function(it) return it.headline end, proposal.read(r).items))
	assert_eq("the two dropped are counted", 2, st.skipped)
end

print("\n=== morning news sits above the 16:30 captures on top, whichever pass landed last ===")
do
	local r = new_repo({ "Section A" })
	proposal.build(r, "morning", "2026-10-01", { item("n1", { after = "MORNING news" }) }, FILES)
	proposal.build(r, "1630", "2026-10-01", { item("c1", { after = "CAPTURE five", source = "session:aaaaaaaa-0000-0000-0000-000000000000" }) }, FILES)
	assert_eq("morning above the later 16:30 capture", { "MORNING news", "CAPTURE five", "Section A" }, tip_lines(r, "notes.md"))
	local r2 = new_repo({ "Section A" })
	proposal.build(r2, "1630", "2026-10-01", { item("c1", { after = "CAPTURE five", source = "session:aaaaaaaa-0000-0000-0000-000000000000" }) }, FILES)
	proposal.build(r2, "morning", "2026-10-02", { item("n1", { after = "MORNING news" }) }, FILES)
	assert_eq("and above an earlier one too", { "MORNING news", "CAPTURE five", "Section A" }, tip_lines(r2, "notes.md"))
end

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
