-- desk.apply.apply_file on its own, no git: items that act at the same spot
-- must each act on their own committed lines, whatever order they come in.
-- An insertion landing just above a line that an edit, removal or move
-- takes away must survive, and so must a move's landed lines. And blank
-- lines between sections: a moved section's, and those at an after's edges.
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
run("stale remove whose quote is gone is deferred and loses nothing", {
	it("ins", "add", { after = "- a1" }, "", "- INSERTED"),
	it("rm", "remove", { at = "- gone" }, "- gone", ""),
}, {
	"# Heading A", "- a1", "- INSERTED", "- a2", "- a3", "", "# Heading B", "- b1",
}, { rm = "deferred" })

print("\n=== blank lines between sections: a moved section, and blank lines at an after's edges ===")
local SECTIONS = { "Alpha", "- a1", "", "Bravo", "- b1", "", "Charlie", "- c1" }
local function on(lines, desc, items, expected)
	local got, results = apply.apply_file(vim.deepcopy(lines), items)
	assert_eq(desc, expected, got)
	for _, item in ipairs(items) do
		assert_eq(desc .. ": " .. item.id .. " applied", "applied", results[item.id])
	end
end
on(SECTIONS, "a middle section moved to the end takes one blank line along and lands after one", {
	it("mv", "move", { { at = "Bravo" }, { after = "Charlie" } }, "Bravo\n- b1", "Bravo\n- b1"),
}, { "Alpha", "- a1", "", "Charlie", "- c1", "", "Bravo", "- b1" })
on(SECTIONS, "the last section moved to the top takes the blank line above it, and lands above one", {
	it("mv", "move", { { at = "Charlie" }, "top" }, "Charlie\n- c1", "Charlie\n- c1"),
}, { "Charlie", "- c1", "", "Alpha", "- a1", "", "Bravo", "- b1" })
on(SECTIONS, "the first section moved down takes the blank line below it", {
	it("mv", "move", { { at = "Alpha" }, { after = "Bravo" } }, "Alpha\n- a1", "Alpha\n- a1"),
}, { "Bravo", "- b1", "", "Alpha", "- a1", "", "Charlie", "- c1" })
on(SECTIONS, "a section that already carries its blank line lands with just that one", {
	it("mv", "move", { { at = "Bravo" }, { after = "Charlie" } }, "Bravo\n- b1", "\nBravo\n- b1"),
}, { "Alpha", "- a1", "", "Charlie", "- c1", "", "Bravo", "- b1" })
on(SECTIONS, "a line moved out of a section takes no blank line and gets none", {
	it("mv", "move", { { at = "- c1" }, { under = "Alpha" } }, "- c1", "- c1"),
}, { "Alpha", "- a1", "- c1", "", "Bravo", "- b1", "", "Charlie" })
local TIGHT = { "Alpha", "- a1", "Bravo", "- b1" }
on(TIGHT, "an edit can add the blank line between two sections", {
	it("ed", "edit", { at = "- a1" }, "- a1", "- a1\n\n"),
}, { "Alpha", "- a1", "", "Bravo", "- b1" })
on(TIGHT, "and an insertion a leading one", {
	it("ins", "add", { after = "- a1" }, "", "\nNEW"),
}, { "Alpha", "- a1", "", "NEW", "Bravo", "- b1" })
on(SECTIONS, "a trailing blank line beside an existing one is dropped", {
	it("ed", "edit", { at = "- a1" }, "- a1", "- a1 edited\n\n"),
}, { "Alpha", "- a1 edited", "", "Bravo", "- b1", "", "Charlie", "- c1" })
on(SECTIONS, "so is one at the end of the file", {
	it("ins", "add", { under = "Charlie" }, "", "- c2\n\n"),
}, { "Alpha", "- a1", "", "Bravo", "- b1", "", "Charlie", "- c1", "- c2" })
on(SECTIONS, "and a leading one at the top, and extra ones beyond the one that separates", {
	it("top", "new", "top", "", "\nNEWS"),
	it("ed", "edit", { at = "- b1" }, "- b1", "\n\n- b1 edited"),
}, { "NEWS", "Alpha", "- a1", "", "Bravo", "", "- b1 edited", "", "Charlie", "- c1" })
assert_eq("fitted_after gives the text as it lands", "\nBravo\n- b1", apply.fitted_after(SECTIONS,
	it("mv", "move", { { at = "Bravo" }, { after = "Charlie" } }, "Bravo\n- b1", "Bravo\n- b1")))
assert_eq("and an after with nothing to fit unchanged", "- a1 edited", apply.fitted_after(SECTIONS,
	it("ed", "edit", { at = "- a1" }, "- a1", "- a1 edited")))

print("\n=== a before whose first line is too short to quote is found by its lines ===")
local SHORT = { "Status", "- a1", "ok", "- a2" }
on(SHORT, "a removal of a two-character line removes it", {
	it("rm", "remove", { at = "ok" }, "ok"),
}, { "Status", "- a1", "- a2" })
on(SHORT, "an edit of it rewrites it in place", {
	it("ed", "edit", { at = "ok" }, "ok", "okay then"),
}, { "Status", "- a1", "okay then", "- a2" })
on({ "Status", "", "- a1", "", "- a2" }, "a blank first line, with more under it", {
	it("rm", "remove", { at = "" }, "\n- a2"),
}, { "Status", "", "- a1" })
do
	local got, results = apply.apply_file(vim.deepcopy(SHORT), { it("gone", "remove", { at = "no" }, "no") })
	assert_eq("and one that isn't there removes nothing, and is deferred as a gone quote is", { SHORT, "deferred" }, { got, results.gone })
end

print("\n=== an edit, removal, move or merge whose line is gone is deferred, never landed ===")
for _, kind in ipairs({ "move", "merge" }) do
	local got, results = apply.apply_file(vim.deepcopy(SECTIONS), {
		it("mv", kind, { { at = "Delta" }, { after = "Alpha" } }, "Delta\n- d1", "Delta\n- d1"),
	})
	assert_eq("a " .. kind .. " of a deleted section is deferred", "deferred", results.mv)
	assert_eq("and its text is not put back", SECTIONS, got)
end
for _, kind in ipairs({ "edit", "remove" }) do
	local got, results, on_top = apply.apply_file(vim.deepcopy(SECTIONS), {
		it("ed", kind, { at = "- d1" }, "- d1", kind == "edit" and "- d1 edited" or ""),
	})
	assert_eq("an " .. kind .. " of a deleted line is deferred", "deferred", results.ed)
	assert_eq("and nothing of it lands on top", { SECTIONS, false }, { got, on_top.ed == true })
end

print("\n=== a new section is set off by blank lines, as the notes' own are ===")
local LOOSE = { "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "", "Bravo", "- b1" }
on(LOOSE, "sections on top go above the loose lines landing there, each followed by a blank line", {
	it("n1", "new", "top", "", "- WK: news one"),
	it("s1", "new", "top", "", "session-one\n  - where it stood"),
	it("s2", "new", "top", "", "session-two\n- where it stood"),
	it("n2", "new", "top", "", "- WK: news two"),
}, {
	"session-one", "  - where it stood", "",
	"session-two", "- where it stood", "",
	"- WK: news one", "- WK: news two",
	"- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "", "Bravo", "- b1",
})
on(LOOSE, "a section alone on top: no blank line at the file's start", {
	it("s1", "new", "top", "", "session-one\n  - where it stood"),
}, { "session-one", "  - where it stood", "", "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "", "Bravo", "- b1" })
on(LOOSE, "after a block, a section goes below a line landing there, behind a blank line", {
	it("s1", "add", { after = "- a1" }, "", "session-one\n  - where it stood"),
	it("n1", "add", { after = "- a1" }, "", "- a2"),
}, { "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "- a2", "", "session-one", "  - where it stood", "", "Bravo", "- b1" })
on(LOOSE, "a bullet with a sub-bullet on top is not a section: no blank line, not moved above other items", {
	it("n1", "new", "top", "", "- WK: news one"),
	it("b", "new", "top", "", "- a thing\n  - its detail"),
}, { "- WK: news one", "- a thing", "  - its detail", "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "", "Bravo", "- b1" })
on(LOOSE, "nor when added under a section", {
	it("b", "add", { under = "Alpha" }, "", "- a2\n  - its detail"),
}, { "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "- a2", "  - its detail", "", "Bravo", "- b1" })
on(LOOSE, "bullets added under a section are not a section", {
	it("b", "add", { under = "Alpha" }, "", "- a2\n- a3"),
}, { "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "- a2", "- a3", "", "Bravo", "- b1" })
on(LOOSE, "an anchor quoted with the runner's agent mark still finds its line", {
	it("b", "add", { under = "Alpha  <<agent-suggested>>" }, "", "- a2"),
}, { "- WK: loose one", "- WK: loose two", "", "Alpha", "- a1", "- a2", "", "Bravo", "- b1" })

print("=== a quoted line matches a committed one apart from trailing whitespace and the agent mark ===")
-- Committed lines that end in whitespace, quoted without it: bare, and with
-- the mark appended the way a judge echoes its input copy.
local TRAILING = { "Alpha ", "- a1 ", "- a2", "", "Bravo", "- b1\t" }
for _, quote in ipairs({
	{ "bare", function(l)
		return l
	end },
	{ "marked", function(l)
		return l .. "  <<agent-suggested>>"
	end },
}) do
	local q = quote[2]
	on(TRAILING, "an edit replaces its line in place (" .. quote[1] .. ")", {
		it("ed", "edit", { at = q("- a1") }, q("- a1"), "- A1"),
	}, { "Alpha ", "- A1", "- a2", "", "Bravo", "- b1\t" })
	on(TRAILING, "a removal removes its line (" .. quote[1] .. ")", {
		it("rm", "remove", { at = q("- a1") }, q("- a1")),
	}, { "Alpha ", "- a2", "", "Bravo", "- b1\t" })
	on(TRAILING, "a move leaves its line and lands at its anchor (" .. quote[1] .. ")", {
		it("mv", "move", { { at = q("- a1") }, { under = "Bravo" } }, q("- a1"), "- a1"),
	}, { "Alpha ", "- a2", "", "Bravo", "- b1\t", "- a1" })
	on(TRAILING, "a merge leaves its lines and lands after its anchor (" .. quote[1] .. ")", {
		it("mg", "merge", { { at = q("- a1") }, { after = q("- b1") } }, q("- a1") .. "\n" .. q("- a2"), "- a1 and a2"),
	}, { "Alpha ", "", "Bravo", "- b1\t", "- a1 and a2" })
	on(TRAILING, "an insertion lands under its heading (" .. quote[1] .. ")", {
		it("ad", "add", { under = q("Alpha") }, "", "- a3"),
	}, { "Alpha ", "- a1 ", "- a2", "- a3", "", "Bravo", "- b1\t" })
end
-- Two lines that differ only in trailing whitespace: an exact quote is the
-- line it quotes, wherever the other one stands.
local TWINS = { "Alpha", "- a1", "- a1 ", "- a2" }
on(TWINS, "an exact quote picks its own line over an earlier loose match", {
	it("ed", "edit", { at = "- a1 " }, "- a1 ", "- A1"),
}, { "Alpha", "- a1", "- A1", "- a2" })
on(TWINS, "and lands an insertion under it", {
	it("ad", "add", { after = "- a1 " }, "", "- a1b"),
}, { "Alpha", "- a1", "- a1 ", "- a1b", "- a2" })
on({ "Alpha", "ok", "ok ", "- a2" }, "a quote too short to search on is found by its exact lines first", {
	it("rm", "remove", { at = "ok " }, "ok "),
}, { "Alpha", "ok", "- a2" })
on(TRAILING, "an exact quote with the mark appended still finds its line", {
	it("ed", "edit", { at = "- a1   <<agent-suggested>>" }, "- a1   <<agent-suggested>>", "- A1"),
}, { "Alpha ", "- A1", "- a2", "", "Bravo", "- b1\t" })

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
if fail > 0 then
	os.exit(1)
end
