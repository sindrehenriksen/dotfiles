-- the hotkey's decision logic (desk.hotkey) — the reader, the
-- Ghostty-tab helpers and URL-opening are all stubbed (never a real
-- subprocess, never Hammerspoon, never a browser); the in-notes reference
-- jump uses a real buffer/window, since that's what proves the jumplist
-- claim.
--
-- Run: nvim --headless -u nvim/tests/minimal_init.lua -l nvim/tests/desk-hotkey-test.lua
local hotkey = require("desk.hotkey")

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

-- A config using invented tokens (dotfiles ships no real ones): TICKET-N is
-- a url handler, anything else falls to the session catch-all.
local config = {
	tokens = {
		{ pattern = "^TICKET-([0-9]+)$", case_insensitive = true, handler = "url", template = "https://example.invalid/TICKET-{1}" },
		{ pattern = "^.+$", case_insensitive = false, handler = "session" },
	},
}

-- Records every call a stub dep received, in order, as {name, ...args}
-- (minus the trailing callback), so a test can assert both "was it called"
-- and "was nothing else called".
local function new_recorder()
	return { calls = {} }
end
local function record(rec, name, ...)
	table.insert(rec.calls, { name, ... })
end

--- Builds a deps table where every function is a stub recording its call
--- and invoking its callback with `results[name]` (a {ok_or_entry, err_or_candidates}
--- pair) — deferred one event-loop tick via vim.schedule, so a test that
--- checks "nothing happened yet, synchronously" actually proves something.
local function stub_deps(rec, results)
	local function stub(name, arity)
		return function(...)
			local args = { ... }
			local cb = args[arity]
			record(rec, name, unpack(args, 1, arity - 1))
			local r = results[name]
			vim.schedule(function()
				cb(unpack(r or {}))
			end)
		end
	end
	return {
		notify = function(msg)
			record(rec, "notify", msg)
		end,
		reader_resolve = stub("reader_resolve", 2),
		focus_tty = stub("focus_tty", 2),
		open_tab = stub("open_tab", 4),
		open_url = stub("open_url", 2),
	}
end

local function new_buf(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end

local function wait_for(desc, predicate)
	local done = vim.wait(1000, predicate, 10)
	if not done then
		bad(desc .. " (timed out waiting for the async callback)")
	end
	return done
end

print("=== token_under_cursor ===")

local tok, s, e = hotkey.token_under_cursor("hello world-name here", 6)
assert_eq("finds the token containing the column", "world-name", tok)
assert_eq("0-indexed start column", 6, s)
assert_eq("0-indexed end column", 15, e)

assert_eq("a space is no token", nil, (hotkey.token_under_cursor("a b", 1)))
assert_eq("column past the end of the line is no token", nil, (hotkey.token_under_cursor("abc", 5)))
tok = hotkey.token_under_cursor("TICKET-123 rest", 0)
assert_eq("cursor on the first character still finds the whole token", "TICKET-123", tok)
tok = hotkey.token_under_cursor("TICKET-123", 9)
assert_eq("cursor on the last character still finds the whole token", "TICKET-123", tok)

tok = hotkey.token_under_cursor("møte i går", 0)
assert_eq("æ/ø/å are token chars: 'møte' is one token, not split at ø", "møte", tok)

print()
print("=== url handler: opens the templated URL, nothing else ===")

do
	local buf = new_buf({ "see TICKET-42 for details" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 5 }) -- inside "TICKET-42"

	local rec = new_recorder()
	local deps = stub_deps(rec, { open_url = { true } })
	hotkey.run(buf, win, config, deps)
	-- The dispatch itself is synchronous (starting an async job never
	-- blocks on it finishing) — only its *result* is async.
	assert_eq("open_url is dispatched before this call returns", { { "open_url", "https://example.invalid/TICKET-42" } }, rec.calls)
	-- A successful open never notifies, so the call count should stay at
	-- exactly one even once the (stubbed) async result comes back.
	vim.wait(50)
	assert_eq("no further calls once the async result lands", 1, #rec.calls)
end

print()
print("=== no match at all: a message, nothing opened ===")

do
	local buf = new_buf({ "just plain prose, no special token" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	-- An empty tokens list: nothing classifies as url or session.
	hotkey.run(buf, win, { tokens = {} }, stub_deps(rec, {}))
	assert_eq("only a notify call, immediately (no external dep touched)", "notify", rec.calls[1][1])
	assert_eq("nothing else was called", 1, #rec.calls)
end

print()
print("=== session, resolved live: focuses by tty ===")

do
	local buf = new_buf({ "Alpha Session: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 }) -- on "Alpha" (part of the token "Alpha")
	local rec = new_recorder()
	local entry = { id = "sess-1", name = "Alpha", live = true, tty = "ttys003", cwd = "/tmp/x" }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil }, focus_tty = { true } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve then focus complete", function()
		return #rec.calls >= 2
	end)
	assert_eq("resolve was asked for the exact token", "reader_resolve", rec.calls[1][1])
	assert_eq("...with the token text", "Alpha", rec.calls[1][2])
	assert_eq("focus_tty was called with the entry's tty", { "focus_tty", "ttys003" }, rec.calls[2])
	local touched_open_tab = false
	for _, c in ipairs(rec.calls) do
		if c[1] == "open_tab" then
			touched_open_tab = true
		end
	end
	assert_eq("open_tab was never called for a live session", false, touched_open_tab)
end

print()
print("=== session, resolved live, focus fails: reports, never resumes ===")

do
	local buf = new_buf({ "Alpha Session: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	local entry = { id = "sess-1", name = "Alpha", live = true, tty = "ttys003", cwd = "/tmp/x" }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil }, focus_tty = { false, "no such window" } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve then failed focus complete", function()
		local saw_notify_after_focus = false
		for i, c in ipairs(rec.calls) do
			if c[1] == "focus_tty" and rec.calls[i + 1] and rec.calls[i + 1][1] == "notify" then
				saw_notify_after_focus = true
			end
		end
		return saw_notify_after_focus
	end)
	local touched_open_tab = false
	for _, c in ipairs(rec.calls) do
		if c[1] == "open_tab" then
			touched_open_tab = true
		end
	end
	assert_eq("a failed focus never falls back to resuming (no second process on a live transcript)", false, touched_open_tab)
end

print()
print("=== session, resolved live but no recorded tty: never resumes, never focuses ===")

do
	local buf = new_buf({ "Alpha Session: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	local entry = { id = "sess-1", name = "Alpha", live = true, tty = nil, cwd = "/tmp/x" }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve completes and a notify follows", function()
		return #rec.calls >= 2
	end)
	local touched = {}
	for _, c in ipairs(rec.calls) do
		touched[c[1]] = true
	end
	assert_eq("focus_tty was never called", nil, touched.focus_tty)
	assert_eq("open_tab was never called", nil, touched.open_tab)
	assert_eq("a notify was issued", true, touched.notify)
end

print()
print("=== session, resolved with duplicate_pids: refuses outright, never guesses ===")

do
	local buf = new_buf({ "Alpha Session: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	-- Two pid files claim this session id (session-status.sh's own
	-- duplicate_pids) — even though the reader reports it as live with a
	-- tty, the hotkey must refuse rather than trust that choice.
	local entry = { id = "sess-1", name = "Alpha", live = true, tty = "ttys003", cwd = "/tmp/x", duplicate_pids = true }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil }, focus_tty = { true }, open_tab = { true } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve completes and a notify follows", function()
		return #rec.calls >= 2
	end)
	local touched = {}
	for _, c in ipairs(rec.calls) do
		touched[c[1]] = true
	end
	assert_eq("focus_tty was never called", nil, touched.focus_tty)
	assert_eq("open_tab was never called", nil, touched.open_tab)
	assert_eq("a notify was issued", true, touched.notify)
end

print()
print("=== session, resolved not live: resumes by id, in its recorded cwd ===")

do
	local buf = new_buf({ "Alpha Session: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	local entry = { id = "sess-2", name = "Alpha", live = false, cwd = "/tmp/somewhere" }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil }, open_tab = { true } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve then open_tab complete", function()
		return #rec.calls >= 2
	end)
	assert_eq("open_tab got the resolved id, never the raw token", { "open_tab", "claude --resume sess-2", "sess-2", "/tmp/somewhere" }, rec.calls[2])
end

print()
print("=== session, ambiguous: reports, never guesses ===")

do
	local buf = new_buf({ "Alpha Session: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	local candidates = { { id = "sess-3" }, { id = "sess-4" } }
	local deps = stub_deps(rec, { reader_resolve = { nil, candidates } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve completes", function()
		return #rec.calls >= 2
	end)
	local touched = {}
	for _, c in ipairs(rec.calls) do
		touched[c[1]] = true
	end
	assert_eq("neither focus_tty nor open_tab was ever called", nil, touched.focus_tty or touched.open_tab)
	assert_eq("a notify was issued", true, touched.notify)
end

print()
print("=== session, no match at all found by the reader ===")

do
	local buf = new_buf({ "Nobody Here: doing the thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	local deps = stub_deps(rec, { reader_resolve = { nil, {} } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve completes", function()
		return #rec.calls >= 2
	end)
	assert_eq("a notify was issued", "notify", rec.calls[2][1])
end

print()
print("=== following an in-notes reference to another section ===")
print("=== jumps there internally, never touching the reader, jumplist-safe ===")

do
	local buf = new_buf({
		"Alpha Session: the actual section",
		"  doing the thing",
		"",
		"Some unrelated line here.",
		"See Alpha for context.",
	})
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 5, 4 }) -- on "Alpha" in "See Alpha for context."

	local rec = new_recorder()
	-- If this ever touched reader_resolve, calling its callback would
	-- crash the test (stub_deps' results table has nothing for it) —
	-- deliberately not stubbed, so a resolve call surfaces loudly.
	local deps = { notify = function(msg) record(rec, "notify", msg) end }
	hotkey.run(buf, win, config, deps)

	assert_eq("nothing was dispatched externally", 0, #rec.calls)
	local cur = vim.api.nvim_win_get_cursor(win)
	assert_eq("the cursor landed on the section's own head line", 1, cur[1])

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "x", false)
	local after_ctrl_o = vim.api.nvim_win_get_cursor(win)
	assert_eq("Ctrl-O returns to the line the user was reading", 5, after_ctrl_o[1])

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-i>", true, false, true), "x", false)
	local after_ctrl_i = vim.api.nvim_win_get_cursor(win)
	assert_eq("Ctrl-I goes forward again, back to the section head", 1, after_ctrl_i[1])
end

print()
print("=== the cursor already on a section's own head line: acts normally, no self-jump ===")

do
	local buf = new_buf({
		"Alpha Session: the actual section",
		"  doing the thing",
	})
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 }) -- on "Alpha", which IS the section head

	local rec = new_recorder()
	local entry = { id = "sess-5", name = "Alpha", live = false, cwd = "/tmp/y" }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil }, open_tab = { true } })
	hotkey.run(buf, win, config, deps)
	wait_for("resolve then open_tab complete", function()
		return #rec.calls >= 2
	end)
	assert_eq("it resolved through the reader as usual, not an internal jump", "reader_resolve", rec.calls[1][1])
end

print()
print("=== a session pattern's own capture resolves by short id ===")

do
	-- A config whose session pattern wraps a short id in decoration the user's
	-- notes actually use — the reader indexes sessions by "42", never by
	-- the decorated token "S-42" typed in the buffer.
	local capture_config = {
		tokens = {
			{ pattern = "^S-(%w+)$", case_insensitive = false, handler = "session" },
		},
	}
	local buf = new_buf({ "see S-42 for details" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 4 }) -- inside "S-42"

	local rec = new_recorder()
	local entry = { id = "sess-42", name = "42", live = false, cwd = "/tmp/w" }
	local deps = stub_deps(rec, { reader_resolve = { entry, nil }, open_tab = { true } })
	hotkey.run(buf, win, capture_config, deps)
	wait_for("resolve then open_tab complete", function()
		return #rec.calls >= 1
	end)
	assert_eq("resolved by the captured short id, not the decorated token", { "reader_resolve", "42" }, rec.calls[1])
end

print()
print("=== two sections sharing one head never ping-pong ===")

do
	local buf = new_buf({
		"Alpha Session: first section", -- 1: head #1
		"  detail one",
		"",
		"Alpha Session: second section", -- 4: head #2
		"  detail two",
	})
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)

	-- Hovering on the SECOND head's own "Alpha": not the same block as the
	-- first head, so it follows there — same as the old behavior would for
	-- this specific starting point.
	vim.api.nvim_win_set_cursor(win, { 4, 0 }) -- "Alpha" in the second head
	local rec = new_recorder()
	local deps = { notify = function(msg) record(rec, "notify", msg) end }
	hotkey.run(buf, win, config, deps)
	assert_eq("nothing dispatched externally (jumped internally instead)", 0, #rec.calls)
	assert_eq("landed on the FIRST section's head", 1, vim.api.nvim_win_get_cursor(win)[1])

	-- Pressing again from there (now on the FIRST head, inside its own
	-- block) must NOT bounce back to the second — the ping-pong this fixes.
	local rec2 = new_recorder()
	local entry = { id = "sess-9", name = "Alpha", live = false, cwd = "/tmp/z" }
	local deps2 = stub_deps(rec2, { reader_resolve = { entry, nil }, open_tab = { true } })
	hotkey.run(buf, win, config, deps2)
	wait_for("resolve then open_tab complete", function()
		return #rec2.calls >= 2
	end)
	assert_eq(
		"resolved externally instead of bouncing to the other section",
		"reader_resolve",
		rec2.calls[1][1]
	)
	assert_eq("cursor stayed put (no internal jump this time)", 1, vim.api.nvim_win_get_cursor(win)[1])
end

print()
print("=== the tab helpers are found by either env var name ===")
do
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local function stub(name)
		local path = dir .. "/" .. name
		local fh = io.open(path, "w")
		fh:write("#!/bin/sh\necho " .. name .. " > " .. dir .. "/called\n")
		fh:close()
		vim.fn.system({ "chmod", "+x", path })
		return path
	end
	local function called_after(var, name)
		vim.fn.delete(dir .. "/called")
		vim.env[var] = stub(name)
		local done = false
		hotkey.default_deps().open_tab("cmd", "", dir, function()
			done = true
		end)
		vim.wait(5000, function()
			return done
		end, 20)
		vim.env[var] = nil
		local fh = io.open(dir .. "/called", "r")
		local got = fh and vim.trim(fh:read("*a")) or nil
		if fh then
			fh:close()
		end
		return got
	end
	assert_eq("DESK_OPEN_TAB_BIN is used", "by-bin", called_after("DESK_OPEN_TAB_BIN", "by-bin"))
	assert_eq("the older DESK_OPEN_TAB still works", "by-alias", called_after("DESK_OPEN_TAB", "by-alias"))
	vim.env.DESK_OPEN_TAB = stub("alias-loses")
	assert_eq("the shared name wins when both are set", "by-bin2", called_after("DESK_OPEN_TAB_BIN", "by-bin2"))
	vim.env.DESK_OPEN_TAB = nil
end

print()
print("=== a section headed by a non-ASCII name is found by that name ===")
do
	local lines = { "Intro", "Ærlig-økt: the section", "  detail", "See Ærlig-økt for context." }
	assert_eq("the head line is found", 2, hotkey.find_section_head_line(lines, "Ærlig-økt"))
	assert_eq("a token that is only a prefix of the head is not a match", nil, hotkey.find_section_head_line(lines, "Ærlig"))
end

print()
print("=== a tab helper that never returns is killed and reported, not waited on ===")
do
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/hangs"
	local fh = io.open(path, "w")
	fh:write("#!/bin/sh\nexec sleep 30\n")
	fh:close()
	vim.fn.system({ "chmod", "+x", path })
	local saved_timeout = hotkey.SHELL_DEP_TIMEOUT_MS
	hotkey.SHELL_DEP_TIMEOUT_MS = 300
	vim.env.DESK_FOCUS_TAB_BIN = path
	local result
	hotkey.default_deps().focus_tty("ttys001", function(ok, err)
		result = { ok = ok, err = err }
	end)
	vim.wait(5000, function()
		return result ~= nil
	end, 20)
	vim.env.DESK_FOCUS_TAB_BIN = nil
	hotkey.SHELL_DEP_TIMEOUT_MS = saved_timeout
	assert_eq("the callback fires", true, result ~= nil)
	assert_eq("as a failure", false, result and result.ok)
	assert_eq("naming the timeout", true, result ~= nil and (result.err or ""):find("timed out", 1, true) ~= nil)
end

print()
print("=== markdown emphasis and a trailing colon around a session name ===")

do
	assert_eq("**name:** is the name", "alpha-team", hotkey.clean_token("**alpha-team:**"))
	assert_eq("__name__ is the name", "alpha-team", hotkey.clean_token("__alpha-team__"))
	assert_eq("_name_ is the name", "alpha-team", hotkey.clean_token("_alpha-team_"))
	assert_eq("an underscore inside stays", "my_session", hotkey.clean_token("my_session"))

	-- A bold head with a colon is a section head: a mention elsewhere jumps to it.
	local buf = new_buf({ "**Alpha-team:**", "  doing the thing", "", "See Alpha-team for context." })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 4, 6 })
	local rec = new_recorder()
	hotkey.run(buf, win, config, { notify = function(msg) record(rec, "notify", msg) end })
	assert_eq("a mention jumps to the bold head", 1, vim.api.nvim_win_get_cursor(win)[1])
	assert_eq("nothing dispatched", 0, #rec.calls)

	-- On an underscored head itself: the reader gets the bare name.
	local buf2 = new_buf({ "__Beta-team__", "  doing the thing" })
	vim.api.nvim_win_set_buf(win, buf2)
	vim.api.nvim_win_set_cursor(win, { 1, 4 })
	local rec2 = new_recorder()
	hotkey.run(buf2, win, config, stub_deps(rec2, { reader_resolve = { nil, {} } }))
	assert_eq("resolved by the name without its underscores", { "reader_resolve", "Beta-team" }, rec2.calls[1])
end

print()
print("=== a bare word is never handed to the system opener ===")

do
	local bare = {
		tokens = {
			{ pattern = "^WORD%-([a-z]+)$", handler = "url", template = "{1}" },
			{ pattern = "^.+$", handler = "session" },
		},
	}
	local buf = new_buf({ "WORD-thing" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	local rec = new_recorder()
	hotkey.run(buf, win, bare, stub_deps(rec, { open_url = { true } }))
	assert_eq("says it is not a link or session", { { "notify", "'WORD-thing' is not a link or session" } }, rec.calls)
	assert_eq("a scheme is openable", true, hotkey.openable("https://example.invalid/x"))
	assert_eq("so is a dotted name", true, hotkey.openable("example.invalid"))
	assert_eq("a bare word is not", false, hotkey.openable("alpha-team"))
end

print()
print("=== desk first, then the markdown link under the cursor ===")

do
	local buf = new_buf({ "see the [collab thread](https://example.invalid/t) and TICKET-7" })
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	local function run_at(text, results)
		local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
		vim.api.nvim_win_set_cursor(win, { 1, line:find(text, 1, true) - 1 })
		local rec = new_recorder()
		local deps = stub_deps(rec, results)
		deps.follow_link = function(b, w)
			record(rec, "follow_link")
			return require("mdlink").link_at(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], vim.api.nvim_win_get_cursor(w)[2]) ~= nil
		end
		hotkey.run(buf, win, config, deps)
		vim.wait(50)
		return rec.calls
	end
	local calls = run_at("thread", { reader_resolve = { nil, {} } })
	assert_eq("a link's label that is no session: the reader first, then the link", { { "reader_resolve", "thread" }, { "follow_link" } }, calls)
	calls = run_at("TICKET-7", { open_url = { true } })
	assert_eq("a ticket stays the desk's", { { "open_url", "https://example.invalid/TICKET-7" } }, calls)
	calls = run_at("and", { reader_resolve = { nil, {} } })
	assert_eq("prose that is neither: tried, and said", "notify", calls[#calls][1])
end

print()
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
