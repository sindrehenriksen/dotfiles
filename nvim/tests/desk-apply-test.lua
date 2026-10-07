-- desk.apply.apply_file on its own, no git: items that act at the same spot
-- must each act on their own committed lines, whatever order they come in.
-- An insertion landing just above a line that an edit, removal or move
-- takes away must survive, and so must a move's landed lines.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-apply-test.lua
local apply = require("desk.apply")

local pass, fail = 0, 0
local function assert_eq(desc, expected, actual)
	if vim.deep_equal(expected, actual) then
		pass = pass + 1
		print("ok   - " .. desc)
	else
		fail = fail + 1
		print(string.format("FAIL - %s (expected %s, got %s)", desc, vim.inspect(expected), vim.inspect(actual)))
	end
end

-- `{ after = "- a1" }` resolves to the end of a1's own block, which is the
-- spot just above "- a2": the same place an edit or removal of a2 acts.
local BASE = {
	"# Heading A",
	"- a1",
	"- a2",
	"- a3",
	"",
	"# Heading B",
	"- b1",
}

local function it(id, kind, target, before, after)
	return { id = id, kind = kind, target = target, before = before or "", after = after or "" }
end

local function reversed(list)
	local out = {}
	for i = #list, 1, -1 do
		out[#out + 1] = list[i]
	end
	return out
end

local function run(desc, items, expected, expected_results)
	for _, order in ipairs({ { "in order", items }, { "reversed", reversed(items) } }) do
		local lines, results = apply.apply_file(vim.deepcopy(BASE), order[2])
		local want_lines = expected[order[1]] or expected
		assert_eq(desc .. " (" .. order[1] .. ")", want_lines, lines)
		local want = {}
		for _, item in ipairs(items) do
			want[item.id] = (expected_results and expected_results[item.id]) or "applied"
		end
		assert_eq(desc .. ": results (" .. order[1] .. ")", want, results)
	end
end

print("=== an insertion beside an edit, removal or move of the next line ===")
for _, kind in ipairs({ "add", "new", "link" }) do
	local ins = it("ins", kind, { after = "- a1" }, "", "- INSERTED")

	run(kind .. " + edit of the line below it", { ins, it("ed", "edit", { at = "- a2" }, "- a2", "- a2 edited") }, {
		"# Heading A", "- a1", "- INSERTED", "- a2 edited", "- a3", "", "# Heading B", "- b1",
	})

	run(kind .. " + remove of the line below it", { ins, it("rm", "remove", { at = "- a2" }, "- a2", "") }, {
		"# Heading A", "- a1", "- INSERTED", "- a3", "", "# Heading B", "- b1",
	})

	run(kind .. " + move whose source is the line below it", {
		ins,
		it("mv", "move", { { at = "- a2" }, { under = "# Heading B" } }, "- a2", "- a2"),
	}, {
		"# Heading A", "- a1", "- INSERTED", "- a3", "", "# Heading B", "- b1", "- a2",
	})

	run(kind .. " + move whose target is the same spot", {
		ins,
		it("mv", "move", { { at = "- b1" }, { after = "- a1" } }, "- b1", "- b1"),
	}, {
		-- Two insertions at one spot land in input order, as documented.
		["in order"] = { "# Heading A", "- a1", "- INSERTED", "- b1", "- a2", "- a3", "", "# Heading B" },
		reversed = { "# Heading A", "- a1", "- b1", "- INSERTED", "- a2", "- a3", "", "# Heading B" },
	})
end

print("\n=== a move's landed lines beside an edit or removal of the next line ===")
local mv_in = it("mv", "move", { { at = "- b1" }, { after = "- a1" } }, "- b1", "- b1")
run("move landing + edit of the line below it", { mv_in, it("ed", "edit", { at = "- a2" }, "- a2", "- a2 edited") }, {
	"# Heading A", "- a1", "- b1", "- a2 edited", "- a3", "", "# Heading B",
})
run("move landing + remove of the line below it", { mv_in, it("rm", "remove", { at = "- a2" }, "- a2", "") }, {
	"# Heading A", "- a1", "- b1", "- a3", "", "# Heading B",
})
run("move landing + another move's source below it", {
	mv_in,
	it("mv2", "move", { { at = "- a2" }, { under = "# Heading B" } }, "- a2", "- a2"),
}, {
	"# Heading A", "- a1", "- b1", "- a3", "", "# Heading B", "- a2",
})

print("\n=== an insertion inside a multi-line edit's range ===")
run("insertion after the edit's first line", {
	it("ins", "add", { after = "- a2" }, "", "- INSERTED"),
	it("ed", "edit", { at = "- a2" }, "- a2\n- a3", "- a2+a3"),
}, {
	"# Heading A", "- a1", "- a2+a3", "- INSERTED", "", "# Heading B", "- b1",
})

print("\n=== two items claiming the same line: the first acts, the second is deferred ===")
do
	local ed = it("ed", "edit", { at = "- a2" }, "- a2", "- a2 edited")
	local rm = it("rm", "remove", { at = "- a2" }, "- a2", "")
	local lines, results = apply.apply_file(vim.deepcopy(BASE), { ed, rm })
	assert_eq("edit first: edited, and a3 is not taken with it", {
		"# Heading A", "- a1", "- a2 edited", "- a3", "", "# Heading B", "- b1",
	}, lines)
	assert_eq("edit first: the removal is deferred", { ed = "applied", rm = "deferred" }, results)
	lines, results = apply.apply_file(vim.deepcopy(BASE), { rm, ed })
	assert_eq("remove first: removed, and a3 is not taken with it", {
		"# Heading A", "- a1", "- a3", "", "# Heading B", "- b1",
	}, lines)
	assert_eq("remove first: the edit is deferred", { rm = "applied", ed = "deferred" }, results)

	local mv = it("mv", "move", { { at = "- a2" }, { under = "# Heading B" } }, "- a2\n- a3", "- a2\n- a3")
	lines, results = apply.apply_file(vim.deepcopy(BASE), { mv, it("ed3", "edit", { at = "- a3" }, "- a3", "- a3 edited") })
	assert_eq("an edit inside a move's source range is deferred, the move is whole", {
		"# Heading A", "- a1", "", "# Heading B", "- b1", "- a2", "- a3",
	}, lines)
	assert_eq("and reported so", { mv = "applied", ed3 = "deferred" }, results)
end

print("\n=== a stale edit is still deferred, never misapplied onto an inserted line ===")
run("stale multi-line edit beside an insertion", {
	it("ins", "add", { after = "- a1" }, "", "- a3"),
	it("ed", "edit", { at = "- a2" }, "- a2\n- a3 changed", "- a2 edited"),
}, {
	"# Heading A", "- a1", "- a3", "- a2", "- a3", "", "# Heading B", "- b1",
}, { ed = "deferred" })
run("stale remove whose quote is gone lands nothing and loses nothing", {
	it("ins", "add", { after = "- a1" }, "", "- INSERTED"),
	it("rm", "remove", { at = "- gone" }, "- gone", ""),
}, {
	"# Heading A", "- a1", "- INSERTED", "- a2", "- a3", "", "# Heading B", "- b1",
})

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
