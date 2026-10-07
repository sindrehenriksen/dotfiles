-- A desk notes buffer conceals link URLs: conceallevel 2 with concealcursor
-- empty, so the label shows and the URL appears on the cursor line. Another
-- Markdown file is left alone.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-conceal-test.lua
local pass, fail = 0, 0
local function assert_eq(desc, expected, actual)
	if expected == actual then
		pass = pass + 1
		print("ok   - " .. desc)
	else
		fail = fail + 1
		print(string.format("FAIL - %s (expected %s, got %s)", desc, vim.inspect(expected), vim.inspect(actual)))
	end
end

vim.env.DESK_CONFIG = ""
local root = vim.fn.tempname()
local notes_dir, other_dir = root .. "/notes", root .. "/other"
vim.fn.mkdir(notes_dir, "p")
vim.fn.mkdir(other_dir, "p")
vim.fn.writefile({}, notes_dir .. "/.desk-notes")
vim.fn.writefile({ "- a thread [Slack thread](https://example.invalid/archives/C1/p1)" }, notes_dir .. "/notes.md")
vim.fn.writefile({ "- [x](https://example.invalid/y)" }, other_dir .. "/notes.md")

require("desk").setup()

vim.cmd("edit " .. vim.fn.fnameescape(notes_dir .. "/notes.md"))
assert_eq("a desk notes window conceals at level 2", 2, vim.wo.conceallevel)
assert_eq("and reveals on the cursor line (concealcursor empty)", "", vim.wo.concealcursor)
local buf = vim.api.nvim_get_current_buf()
assert_eq("markdown tree-sitter highlighting is on, which does the concealing", true,
	vim.treesitter.highlighter.active[buf] ~= nil)
vim.treesitter.get_parser(buf):parse(true)
local concealed = false
for _, c in ipairs(vim.treesitter.get_captures_at_pos(buf, 0, 40)) do
	concealed = concealed or c.metadata.conceal ~= nil
end
assert_eq("the link's URL is concealed", true, concealed)

vim.cmd("enew")
vim.cmd("edit " .. vim.fn.fnameescape(other_dir .. "/notes.md"))
assert_eq("a notes.md outside a notes repo is left alone", 0, vim.wo.conceallevel)

vim.fn.delete(root, "rf")
print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
