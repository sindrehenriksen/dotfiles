-- D7 test: annotations (desk.annotate) — the pure formatting/scanning
-- functions directly, and a from-scratch fixture for the async end-to-end
-- path: the reader is a stub script ($DESK_READER), never the real one,
-- and the ticket cache is a throwaway file ($DESK_TICKET_CACHE).
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-annotate-test.lua
local annotate = require("desk.annotate")

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

local DAY = 86400
local now = os.time()

print("=== session_text ===")

assert_eq(
	"idle counts from his last human message, not from other recent activity",
	"live · idle 4d",
	annotate.session_text({ live = true, last_activity = now, last_human_message = now - 4 * DAY }, now)
)

assert_eq("live and recently active: just 'live'", "live", annotate.session_text({ live = true, last_activity = now }, now))
assert_eq(
	"live but quiet for days: 'live · idle Nd'",
	"live · idle 3d",
	annotate.session_text({ live = true, last_activity = now - 3 * DAY }, now)
)
assert_eq(
	"closed by the desk pass: resumable",
	"closed by desk · resumable",
	annotate.session_text({ live = false, end_reason = "closed-by-pass" }, now)
)
assert_eq(
	"ended any other way: not running, with the date",
	"not running · last active " .. os.date("%Y-%m-%d", now - 2 * DAY),
	annotate.session_text({ live = false, end_reason = "prompt_input_exit", last_activity = now - 2 * DAY }, now)
)
assert_eq(
	"ended with no recorded activity at all: 'unknown' rather than erroring",
	"not running · last active unknown",
	annotate.session_text({ live = false, end_reason = "other" }, now)
)

print()
print("=== ticket_text ===")

local cache = { checked_at = now - 90, tickets = { ["TICKET-1"] = { status = "In Review" } } }
assert_eq("an exact-case match", "In Review · status from last pass · 1 minute ago", annotate.ticket_text(cache, "TICKET-1", now))
assert_eq("a case-insensitive match (his notes mix cases)", "In Review · status from last pass · 1 minute ago", annotate.ticket_text(cache, "ticket-1", now))
assert_eq("no cache entry for the token: no annotation, not a blank one", nil, annotate.ticket_text(cache, "TICKET-2", now))
assert_eq("no cache at all: nil, never an error", nil, annotate.ticket_text(nil, "TICKET-1", now))

local hours_cache = { checked_at = now - 3 * 3600, tickets = { ["T-1"] = { status = "Done" } } }
assert_eq("age in hours once past 60 minutes", "Done · status from last pass · 3 hours ago", annotate.ticket_text(hours_cache, "T-1", now))

local days_cache = { checked_at = now - 2 * DAY, tickets = { ["T-1"] = { status = "Done" } } }
assert_eq("age in days once past 24 hours", "Done · status from last pass · 2 days ago", annotate.ticket_text(days_cache, "T-1", now))

print()
print("=== ticket_cache_path: follows $DESK_STATE_DIR, never a bare $HOME, when $DESK_TICKET_CACHE is unset ===")

do
	local old_cache, old_state = vim.env.DESK_TICKET_CACHE, vim.env.DESK_STATE_DIR

	vim.env.DESK_TICKET_CACHE = "/explicit/override.json"
	vim.env.DESK_STATE_DIR = "/should-be-ignored"
	assert_eq(
		"an explicit $DESK_TICKET_CACHE always wins",
		"/explicit/override.json",
		annotate.ticket_cache_path()
	)

	vim.env.DESK_TICKET_CACHE = nil
	vim.env.DESK_STATE_DIR = "/tmp/desk-annotate-test-state"
	assert_eq(
		"no $DESK_TICKET_CACHE: derives from $DESK_STATE_DIR rather than a bare ~/.local/state/desk",
		"/tmp/desk-annotate-test-state/ticket-status.json",
		annotate.ticket_cache_path()
	)

	vim.env.DESK_TICKET_CACHE = nil
	vim.env.DESK_STATE_DIR = nil
	assert_eq(
		"neither set: falls back to the real default",
		vim.fn.expand("~/.local/state/desk/ticket-status.json"),
		annotate.ticket_cache_path()
	)

	vim.env.DESK_TICKET_CACHE = old_cache
	vim.env.DESK_STATE_DIR = old_state
end

print()
print("=== scan: finds tokens by classified kind, at their own positions ===")

local tokens_config = {
	{ pattern = "^TICKET-([0-9]+)$", case_insensitive = true, handler = "url", template = "https://example.invalid/{1}" },
	{ pattern = "^.+$", case_insensitive = false, handler = "session" },
}
local lines = {
	"Alpha Session: working on TICKET-9",
	"  a note about it",
	"Beta Session: something else",
}
local session_hits = annotate.scan(lines, tokens_config, "session")
local names = {}
for _, h in ipairs(session_hits) do
	names[#names + 1] = h.token.text
end
table.sort(names)
-- Every run of letters/digits/_/- is its own token, including "working"
-- and "on" and "a" and "note" and "about" and "it" — scan doesn't know
-- which ones are section names, only which ones classify as "session"
-- (the catch-all), so a plain-prose word is indistinguishable from one at
-- this layer. Annotate only actually shows text for tokens the reader
-- recognizes as a real session name (M.refresh's by_name lookup), so this
-- is fine — checking here just for "Alpha", "Session" and "Beta" being
-- among them, not that the noise words are somehow excluded.
local function contains(list, v)
	for _, x in ipairs(list) do
		if x == v then
			return true
		end
	end
	return false
end
assert_eq("'Alpha' is found as a session-kind token", true, contains(names, "Alpha"))
assert_eq("'Beta' is found as a session-kind token", true, contains(names, "Beta"))

local ticket_hits = annotate.scan(lines, tokens_config, "url")
assert_eq("exactly one url-kind token found", 1, #ticket_hits)
assert_eq("it's TICKET-9, on line 1", { line = 1, text = "TICKET-9" }, { line = ticket_hits[1].line, text = ticket_hits[1].token.text })
assert_eq("its column span covers exactly the token", "TICKET-9", lines[1]:sub(ticket_hits[1].token.start_col + 1, ticket_hits[1].token.end_col + 1))

print()
print("=== tokens_in_line: æ/ø/å (and other non-ASCII letters) stay in the token ===")

local tok_hits = annotate.tokens_in_line("Åse møter Kåre på Bekkestøa")
local tok_texts = {}
for _, t in ipairs(tok_hits) do
	tok_texts[#tok_texts + 1] = t.text
end
assert_eq(
	"every word stays whole, none split at its æ/ø/å",
	{ "Åse", "møter", "Kåre", "på", "Bekkestøa" },
	tok_texts
)

print()
print("=== refresh: end to end, reader and ticket cache both stubbed ===")

do
	local tmp_dir = vim.fn.tempname()
	vim.fn.mkdir(tmp_dir, "p")

	-- A stub reader: a tiny script printing one canned live-session entry,
	-- standing in for session-status.sh so this never shells out to the
	-- real one.
	local stub_reader = tmp_dir .. "/fake-session-status.sh"
	local fd = assert(io.open(stub_reader, "w"))
	fd:write(
		"#!/usr/bin/env bash\n"
			.. 'echo '
			.. vim.fn.shellescape(vim.json.encode({
				id = "sess-1",
				name = "Alpha",
				live = true,
				last_activity = now,
				cwd = "",
				older_names = {},
				status = "busy",
				ended = false,
				end_reason = vim.NIL,
				transcript_path = "",
				has_start_event = true,
				pid = 123,
				tty = "ttys001",
			}))
			.. "\n"
	)
	fd:close()
	vim.fn.setfperm(stub_reader, "rwxr-xr-x")

	local ticket_cache = tmp_dir .. "/ticket-cache.json"
	local tfd = assert(io.open(ticket_cache, "w"))
	tfd:write(vim.json.encode({ checked_at = now, tickets = { ["TICKET-9"] = { status = "In Review" } } }))
	tfd:close()

	local old_reader, old_cache = vim.env.DESK_READER, vim.env.DESK_TICKET_CACHE
	vim.env.DESK_READER = stub_reader
	vim.env.DESK_TICKET_CACHE = ticket_cache

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	annotate.refresh(buf, { tokens = tokens_config })

	-- The ticket annotation is synchronous (a local file): should already
	-- be there.
	local ticket_marks = vim.api.nvim_buf_get_extmarks(buf, annotate.ns, { 0, 0 }, { 0, -1 }, { details = true })
	local saw_ticket = false
	for _, m in ipairs(ticket_marks) do
		local vt = m[4].virt_text
		if vt and vt[1] and vt[1][1]:find("In Review", 1, true) then
			saw_ticket = true
		end
	end
	assert_eq("the ticket annotation is painted synchronously", true, saw_ticket)

	-- The session annotation is async (the reader is a subprocess): wait
	-- for it.
	local saw_session = false
	vim.wait(2000, function()
		local marks = vim.api.nvim_buf_get_extmarks(buf, annotate.ns, { 0, 0 }, { -1, -1 }, { details = true })
		for _, m in ipairs(marks) do
			local vt = m[4].virt_text
			if vt and vt[1] and vt[1][1] == "live" then
				saw_session = true
			end
		end
		return saw_session
	end, 20)
	assert_eq("the session annotation is painted once the (stubbed) reader returns", true, saw_session)

	vim.env.DESK_READER = old_reader
	vim.env.DESK_TICKET_CACHE = old_cache
end

print()
print("=== D7 fix: several tokens on one line are each labeled by name ===")

do
	local ticket_cache_path = vim.fn.tempname()
	local tfd = assert(io.open(ticket_cache_path, "w"))
	tfd:write(vim.json.encode({
		checked_at = now,
		tickets = { ["TICKET-1"] = { status = "To Do" }, ["TICKET-2"] = { status = "Done" } },
	}))
	tfd:close()
	local old_cache = vim.env.DESK_TICKET_CACHE
	vim.env.DESK_TICKET_CACHE = ticket_cache_path

	-- The line's other words ("blocks", "alone", "on", ...) all classify
	-- as session-kind tokens too (the catch-all), so this still triggers
	-- an async reader.all() call — a no-op stub, never the real
	-- subprocess, same as every other test here that touches session
	-- tokens.
	local old_reader = vim.env.DESK_READER
	vim.env.DESK_READER = vim.fn.tempname()
	local rfd = assert(io.open(vim.env.DESK_READER, "w"))
	rfd:write("#!/usr/bin/env bash\ntrue\n")
	rfd:close()
	vim.fn.setfperm(vim.env.DESK_READER, "rwxr-xr-x")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "TICKET-1 blocks TICKET-2", "TICKET-1 alone on its own line" })
	annotate.refresh(buf, { tokens = tokens_config })

	local marks = vim.api.nvim_buf_get_extmarks(buf, annotate.ns, { 0, 0 }, { -1, -1 }, { details = true })
	local texts = {}
	for _, m in ipairs(marks) do
		texts[#texts + 1] = m[4].virt_text[1][1]
	end
	table.sort(texts)
	assert_eq(
		"two tickets sharing a line are each prefixed with their own token; alone, no prefix",
		{ "TICKET-1: To Do · status from last pass · 0 minutes ago", "TICKET-2: Done · status from last pass · 0 minutes ago", "To Do · status from last pass · 0 minutes ago" },
		texts
	)

	vim.env.DESK_READER = old_reader
	vim.env.DESK_TICKET_CACHE = old_cache
	os.remove(ticket_cache_path)
end

print()
print("=== D7 fix: no ticket cache yet still clears stale labels (no pile-up) ===")

do
	local tmp_dir = vim.fn.tempname()
	vim.fn.mkdir(tmp_dir, "p")
	local stub_reader = tmp_dir .. "/fake-session-status.sh"
	local fd = assert(io.open(stub_reader, "w"))
	fd:write(
		"#!/usr/bin/env bash\n"
			.. "echo "
			.. vim.fn.shellescape(vim.json.encode({
				id = "sess-1",
				name = "Alpha",
				live = true,
				last_activity = now,
				cwd = "",
				older_names = {},
				status = "busy",
				ended = false,
				end_reason = vim.NIL,
				transcript_path = "",
				has_start_event = true,
				pid = 123,
				tty = "ttys001",
			}))
			.. "\n"
	)
	fd:close()
	vim.fn.setfperm(stub_reader, "rwxr-xr-x")

	local old_reader, old_cache = vim.env.DESK_READER, vim.env.DESK_TICKET_CACHE
	vim.env.DESK_READER = stub_reader
	vim.env.DESK_TICKET_CACHE = "/nonexistent/desk-ticket-cache-fixture.json" -- no cache at all yet

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Alpha Session: working" })

	annotate.refresh(buf, { tokens = tokens_config })
	vim.wait(500, function()
		return #vim.api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, {}) > 0
	end, 10)
	annotate.refresh(buf, { tokens = tokens_config }) -- a second refresh, no cache having appeared meanwhile
	vim.wait(500, function()
		return #vim.api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, {}) > 0
	end, 10)

	local marks = vim.api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, {})
	assert_eq("exactly one label, not piled up across the two refreshes", 1, #marks)

	vim.env.DESK_READER = old_reader
	vim.env.DESK_TICKET_CACHE = old_cache
end

print()
print("=== D7 fix: a BufEnter/FocusGained double-refresh never double-paints ===")

do
	local tmp_dir = vim.fn.tempname()
	vim.fn.mkdir(tmp_dir, "p")
	-- A slow stub: sleeps briefly before replying, so both refresh() calls
	-- below are genuinely in flight together — the race this guards
	-- against, rather than one always finishing before the second starts.
	local stub_reader = tmp_dir .. "/fake-session-status.sh"
	local fd = assert(io.open(stub_reader, "w"))
	fd:write(
		"#!/usr/bin/env bash\nsleep 0.1\necho "
			.. vim.fn.shellescape(vim.json.encode({
				id = "sess-1",
				name = "Alpha",
				live = true,
				last_activity = now,
				cwd = "",
				older_names = {},
				status = "busy",
				ended = false,
				end_reason = vim.NIL,
				transcript_path = "",
				has_start_event = true,
				pid = 123,
				tty = "ttys001",
			}))
			.. "\n"
	)
	fd:close()
	vim.fn.setfperm(stub_reader, "rwxr-xr-x")

	local old_reader, old_cache = vim.env.DESK_READER, vim.env.DESK_TICKET_CACHE
	vim.env.DESK_READER = stub_reader
	vim.env.DESK_TICKET_CACHE = "/nonexistent/desk-ticket-cache-fixture.json"

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Alpha Session: working" })

	-- Two refreshes back to back, like BufEnter immediately followed by
	-- FocusGained, both still in flight.
	annotate.refresh(buf, { tokens = tokens_config })
	annotate.refresh(buf, { tokens = tokens_config })

	vim.wait(2000, function()
		return #vim.api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, {}) > 0
	end, 20)
	local marks = vim.api.nvim_buf_get_extmarks(buf, annotate.ns, 0, -1, {})
	assert_eq("exactly one label once both in-flight refreshes have settled", 1, #marks)

	vim.env.DESK_READER = old_reader
	vim.env.DESK_TICKET_CACHE = old_cache
end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
