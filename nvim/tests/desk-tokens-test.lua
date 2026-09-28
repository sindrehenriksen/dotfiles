-- D7 test: the token → handler table (desk.tokens) — pure, no reader or
-- filesystem involved beyond desk.tokens.load's own path argument.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-tokens-test.lua
local tokens = require("desk.tokens")

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

-- ---------------------------------------------------------------------------
-- The dotfiles-owned generic example: an unescaped hyphen in a pattern (the
-- real-world shape a config author naturally writes) plus a catch-all
-- session fallback, tried last — the same two-entry shape as the actual
-- instantiation, with an invented pattern so dotfiles names no real one.
-- ---------------------------------------------------------------------------
local example_config = {
	{
		pattern = "^EXAMPLE-([0-9]+)$",
		case_insensitive = true,
		handler = "url",
		template = "https://example.invalid/items/EXAMPLE-{1}",
	},
	{ pattern = "^.+$", case_insensitive = false, handler = "session" },
}

print("=== classify: the url handler, including its hyphen-as-literal fix ===")

local d = tokens.classify("EXAMPLE-123", example_config)
assert_eq("an exact-case match is a url handler", "url", d.kind)
assert_eq("the template's {1} is substituted with the capture", "https://example.invalid/items/EXAMPLE-123", d.url)

d = tokens.classify("example-123", example_config)
assert_eq("case_insensitive matches lowercase too", "url", d.kind)
assert_eq("the template's literal text is unaffected by the token's casing", "https://example.invalid/items/EXAMPLE-123", d.url)

d = tokens.classify("ExAmPlE-456", example_config)
assert_eq("mixed case matches under case_insensitive", "url", d.kind)
assert_eq("...and still substitutes the (numeric, caseless) capture correctly", "https://example.invalid/items/EXAMPLE-456", d.url)

-- A pattern whose capture is itself letters: proof that case_insensitive
-- matching doesn't force the *captured* text to any particular case —
-- only the literal parts of the pattern are matched case-insensitively.
local letter_capture_config = {
	{ pattern = "^ID-([A-Za-z]+)$", case_insensitive = true, handler = "url", template = "https://example.invalid/{1}" },
}
d = tokens.classify("id-AbC", letter_capture_config)
assert_eq("a lowercase literal prefix still matches", "url", d.kind)
assert_eq("the letter capture keeps the token's original casing verbatim", "https://example.invalid/AbC", d.url)

d = tokens.classify("EXAMPLE456", example_config)
assert_eq(
	"without the hyphen it's not a url match (falls through to the session catch-all)",
	"session",
	d.kind
)

print()
print("=== classify: the session catch-all, tried last ===")

d = tokens.classify("my-session-name", example_config)
assert_eq("anything else is the session handler", "session", d.kind)

d = tokens.classify("", {})
assert_eq("no entries at all -> none", "none", d.kind)

print()
print("=== classify: first match wins, order matters ===")

local order_config = {
	{ pattern = "^a+$", case_insensitive = false, handler = "session" },
	{ pattern = "^a+$", case_insensitive = false, handler = "url", template = "should-not-be-reached" },
}
d = tokens.classify("aaa", order_config)
assert_eq("the earlier entry wins even though a later one also matches", "session", d.kind)

print()
print("=== classify: case-sensitive entries stay case-sensitive ===")

local cs_config = { { pattern = "^CASED$", case_insensitive = false, handler = "url", template = "x" } }
assert_eq("exact case matches", "url", tokens.classify("CASED", cs_config).kind)
assert_eq("wrong case does not match without case_insensitive", "none", tokens.classify("cased", cs_config).kind)

print()
print("=== load: missing / unset / invalid config ===")

local parsed, err = tokens.load("/nonexistent/path/desk-config-that-does-not-exist.json")
assert_eq("a missing file returns nil", nil, parsed)
assert_eq("...with an error message", true, err ~= nil)

local tmp = vim.fn.tempname()
local fd = assert(io.open(tmp, "w"))
fd:write("{ not json")
fd:close()
parsed, err = tokens.load(tmp)
assert_eq("invalid JSON returns nil", nil, parsed)
assert_eq("...with an error message", true, err ~= nil)
os.remove(tmp)

local fd2 = assert(io.open(tmp, "w"))
fd2:write(vim.json.encode({ tokens = example_config, notes_repo = "~/somewhere" }))
fd2:close()
parsed = tokens.load(tmp)
assert_eq("a real config parses", "~/somewhere", parsed.notes_repo)
assert_eq("tokens_from extracts the list", 2, #tokens.tokens_from(parsed))
os.remove(tmp)

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
