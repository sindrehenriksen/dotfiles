-- D7 test: the hotkey's decision logic (desk.hotkey) — the reader, the
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
print("=== D7 done-check: following an in-notes reference to another section ===")
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
	assert_eq("Ctrl-O returns to the line he was reading", 5, after_ctrl_o[1])

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
print("=== D7 fix: two sections sharing one head never ping-pong ===")

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
print(string.format("=== summary: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
