-- gx on markdown links (mdlink): the link under the cursor, headings by
-- GitHub slug, relative files, and never a bare word to the opener. The
-- opener is stubbed; files are throwaway temp ones.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/mdlink-test.lua
local mdlink = require("mdlink")

local pass, fail = 0, 0
local function assert_eq(desc, expected, actual)
	local e, a = vim.json.encode(expected), vim.json.encode(actual)
	if e == a then
		pass = pass + 1
		print("ok   - " .. desc)
	else
		fail = fail + 1
		print(string.format("FAIL - %s (expected %s, got %s)", desc, e, a))
	end
end

local opened, said = {}, {}
mdlink.deps.open = function(t)
	opened[#opened + 1] = t
end
mdlink.deps.notify = function(m)
	said[#said + 1] = m
end

print("=== the link under the cursor ===")
local line = "See [How it works](#how-it-works) and <https://example.invalid/a> or https://example.invalid/b."
assert_eq("on the label's last word: the whole link", "#how-it-works", mdlink.link_at(line, line:find("works") - 1))
assert_eq("on its target", "#how-it-works", mdlink.link_at(line, line:find("#how") - 1))
assert_eq("an autolink", "https://example.invalid/a", mdlink.link_at(line, line:find("<https") ))
assert_eq("a bare URL, without the full stop", "https://example.invalid/b", mdlink.link_at(line, line:find("/b") - 1))
assert_eq("plain prose is none", nil, mdlink.link_at(line, 0))
assert_eq("a title is dropped", "doc.md", mdlink.link_at('[x](doc.md "The doc")', 1))

print("=== GitHub slugs ===")
assert_eq("lowercase, spaces to dashes", "how-it-works", mdlink.slug("How it works"))
assert_eq("punctuation dropped, - and _ kept", "the-prompt-contract_v2", mdlink.slug("The *prompt* contract_v2!"))
assert_eq("code and links reduced to text", "review-keys-and-gx", mdlink.slug("Review keys and [`gx`](#x)"))
assert_eq("an em dash goes, its spaces stay", "why--and-how", mdlink.slug("Why — and how"))
assert_eq("curly quotes, guillemets and an ellipsis go", "its-quoted-and-so-on", mdlink.slug("It’s “quoted” «and» so on…"))
assert_eq("letters beyond ASCII stay", "ærlig-økt-på-året", mdlink.slug("Ærlig økt på året"))
local doc = { "# Desk", "", "## How it works", "text", "```", "## How it works", "```", "## How it works", "## Review keys" }
assert_eq("finds the heading", 3, mdlink.find_heading(doc, "how-it-works"))
assert_eq("a repeat is name-1, fenced code skipped", 8, mdlink.find_heading(doc, "how-it-works-1"))
assert_eq("none", nil, mdlink.find_heading(doc, "nope"))

print("=== gx follows it ===")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "# Other", "", "## Part two", "here" }, dir .. "/other.md")
vim.fn.writefile({ "# Main", "[parts](other.md#part-two) [top](#main) [web](https://example.invalid/x) [gone](nope.md) plain words", "## Main" }, dir .. "/main.md")
vim.cmd("edit " .. dir .. "/main.md")
local main = vim.api.nvim_get_current_buf()
vim.cmd("filetype plugin on")
vim.bo.filetype = "markdown"
assert_eq("the markdown ftplugin maps gx", "Open the markdown link under the cursor", vim.fn.maparg("gx", "n", false, true).desc)
local function gx_on(text)
	vim.api.nvim_set_current_buf(main)
	local l = vim.api.nvim_buf_get_lines(main, 1, 2, false)[1]
	vim.api.nvim_win_set_cursor(0, { 2, l:find(text, 1, true) - 1 })
	vim.cmd("normal gx")
end
gx_on("top")
assert_eq("#anchor jumps to the heading", { 1, 0 }, vim.api.nvim_win_get_cursor(0))
vim.cmd("execute \"normal! \\<C-o>\"")
assert_eq("through the jumplist", 2, vim.api.nvim_win_get_cursor(0)[1])
gx_on("web")
assert_eq("a URL goes to the opener", { "https://example.invalid/x" }, opened)
gx_on("parts")
assert_eq("a relative path opens the file", vim.fn.resolve(dir .. "/other.md"), vim.fn.resolve(vim.api.nvim_buf_get_name(0)))
assert_eq("at its #anchor", 3, vim.api.nvim_win_get_cursor(0)[1])
gx_on("gone")
assert_eq("a missing file is said, not opened", "no file nope.md", said[#said])
opened = {}
gx_on("words")
assert_eq("outside a link, a bare word never reaches the opener", {}, opened)
assert_eq("it says so", "'words' is not a link", said[#said])

print(string.format("\n=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
