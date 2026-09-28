-- D7: the hotkey (design.md §2 "The hotkey", §10 D7's done-check). Acts on
-- the token under the cursor (letters, digits, `_`, `-`):
--   - a url-handler token (e.g. a ticket key) opens its templated URL;
--   - a session-handler token that's a plain in-notes mention of a section
--     defined elsewhere in this same buffer is followed internally,
--     jumplist-safe, rather than treated as something to focus/resume;
--   - otherwise a session-handler token is resolved through the reader
--     (never a raw token passed to `claude`) and, live, focuses its
--     Ghostty tab by tty, or, not live, resumes it by id in its recorded
--     cwd; ambiguity or a failed focus is reported, never guessed past;
--   - no match at all: a message, nothing opened.
--
-- Every external step (the reader, focusing a tab, opening a tab, opening
-- a URL) goes through an injectable `deps` table so the decision logic
-- here is testable without a subprocess, Hammerspoon, or a real browser —
-- see nvim/tests/desk-hotkey-test.lua. The default deps (M.default_deps)
-- are the only part of this module that actually shells out, and they do
-- it async (vim.system with a callback, never :wait()): the hotkey must
-- never block typing.
local block = require("desk.block")
local tokens = require("desk.tokens")

local M = {}

-- The shared token-char class (desk.tokens.TOKEN_CHARS) — kept as its own
-- name here since this is the hotkey's own public constant, but defined in
-- one place so a fix to what counts as a token char (e.g. Unicode letters)
-- never has to land twice.
M.TOKEN_CHARS = tokens.TOKEN_CHARS

--- The token containing 0-indexed byte column `col` in `line` (nvim
--- cursor convention), or nil if `col` doesn't sit on a token character.
--- Returns the token text plus its 0-indexed [start, finish] columns.
function M.token_under_cursor(line, col)
	local n = #line
	if col < 0 or col >= n then
		return nil
	end
	local function is_tok(i)
		return line:sub(i, i):match(M.TOKEN_CHARS) ~= nil
	end
	if not is_tok(col + 1) then
		return nil
	end
	local s, e = col + 1, col + 1
	while s > 1 and is_tok(s - 1) do
		s = s - 1
	end
	while e < n and is_tok(e + 1) do
		e = e + 1
	end
	return line:sub(s, e), s - 1, e - 1
end

-- Strips a leading heading/list/checkbox marker (design.md §2's "section"
-- rule: "after list, heading and checkbox markers; the token stops at
-- `:`"), a best-effort local re-implementation for this one purpose — it
-- doesn't need desk.block's full block/section semantics, only "does this
-- line's own text start by naming this token".
local function line_names_token(line, token)
	local rest = line:gsub("^%s*#+%s*", "")
	rest = rest:gsub("^%s*[-*+]%s*%[[^%]]?%]%s*", "") -- "- [ ] " / "- [x] "
	rest = rest:gsub("^%s*[-*+]%s*", "")
	local head = rest:match("^([%w_%-]+)")
	return head == token
end

--- The first (file-order) 1-indexed line whose own text names `token` as a
--- section head — i.e. `token` appears in the buffer as more than a
--- passing mention. Deliberately not "some OTHER line": with two sections
--- both headed by the same session name, "other than the cursor's own
--- line" alternates depending on which one the cursor happens to be on,
--- so following always lands wherever the cursor WASN'T — pressing from
--- inside either section bounces to the other and back, forever. Always
--- resolving to the same (first) line instead makes M.run's own "already
--- in that block?" check (below) a stable function of the cursor's
--- position rather than of the last jump, which is what actually breaks
--- the ping-pong: from block two it goes to block one; from block one
--- there is nowhere left to jump, so it resolves externally instead.
function M.find_section_head_line(lines, token)
	for i, line in ipairs(lines) do
		if line_names_token(line, token) then
			return i
		end
	end
	return nil
end

--- The command a resumed session's tab runs — built from the reader's own
--- resolved id, never from the raw cursor token (design.md §2: "never by
--- token (a token can start with `-`)").
function M.resume_command(session_id)
	return "claude --resume " .. session_id
end

--- The real dependencies: shells out to the reader (desk.reader), D7's
--- desk-focus-tab.sh, D4's desk-open-tab.sh, and `open` — each overridable
--- by an env var so an install can relocate them without a code change,
--- and so a test can point at a stub instead of a real one. Every call is
--- async.
function M.default_deps()
	local reader = require("desk.reader")

	local function shell_dep(env_var, default_cmd)
		return function(...)
			local args = { ... }
			local cb = args[#args]
			args[#args] = nil
			local cmd = vim.env[env_var]
			cmd = (cmd and cmd ~= "") and cmd or default_cmd
			local argv = { cmd }
			for _, a in ipairs(args) do
				argv[#argv + 1] = a
			end
			vim.system(argv, { text = true }, function(res)
				vim.schedule(function()
					if res.code == 0 then
						cb(true, nil)
					else
						cb(false, vim.trim((res.stdout or "") .. (res.stderr or "")))
					end
				end)
			end)
		end
	end

	return {
		notify = function(msg, level)
			vim.notify("desk: " .. msg, level or vim.log.levels.WARN)
		end,
		reader_resolve = function(token, cb)
			reader.resolve(token, cb)
		end,
		focus_tty = shell_dep("DESK_FOCUS_TAB", "desk-focus-tab.sh"),
		open_tab = shell_dep("DESK_OPEN_TAB", "desk-open-tab.sh"),
		open_url = shell_dep("DESK_OPEN_URL", "open"),
	}
end

--- The hotkey's action for the token under the cursor in window `win`
--- (buffer `bufnr`), using `config.tokens` (desk.tokens shape) to classify
--- it and `deps` (desk.hotkey.default_deps() shape) to act. Never blocks:
--- every branch that reaches outside this buffer does so through an async
--- dep.
function M.run(bufnr, win, config, deps)
	deps = deps or {}
	local notify = deps.notify or function() end
	local cursor = vim.api.nvim_win_get_cursor(win)
	local line_num, col = cursor[1], cursor[2]
	local line = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1] or ""
	local token = M.token_under_cursor(line, col)
	if not token then
		notify("no token under the cursor")
		return
	end

	local classification = tokens.classify(token, tokens.tokens_from(config))

	if classification.kind == "url" then
		(deps.open_url or function(_, cb) cb(false, "no open_url dep") end)(classification.url, function(ok, err)
			if not ok then
				notify("could not open " .. classification.url .. (err and (": " .. err) or ""))
			end
		end)
		return
	end

	if classification.kind == "none" then
		notify("no match for '" .. token .. "'")
		return
	end

	-- session: a plain in-notes reference to a section defined elsewhere in
	-- this same buffer is followed internally (design.md §10 D7's done-
	-- check) — the ' mark is set first, so Ctrl-O returns to where he was.
	-- "Elsewhere" means the cursor isn't already inside the block that
	-- section head starts (block.block_containing): jumping there from
	-- within it would just be a no-op self-jump, and — when two sections
	-- share the same head token — is what used to make following bounce
	-- between them (see find_section_head_line). Not already there: jump
	-- to the section head. Already there: nowhere internal left to go, so
	-- fall through and resolve the token externally instead.
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local head_line = M.find_section_head_line(lines, token)
	if head_line then
		local head_block_start = (block.block_containing(lines, head_line))
		local cursor_block_start = (block.block_containing(lines, line_num))
		if cursor_block_start ~= head_block_start then
			vim.api.nvim_win_call(win, function()
				vim.cmd("normal! m'")
			end)
			vim.api.nvim_win_set_cursor(win, { head_line, 0 })
			return
		end
	end

	(deps.reader_resolve or function(_, cb) cb(nil, {}) end)(token, function(entry, candidates)
		if not entry then
			if candidates and #candidates > 0 then
				local names = {}
				for _, c in ipairs(candidates) do
					names[#names + 1] = c.id or c.name or "?"
				end
				notify("ambiguous session '" .. token .. "': " .. table.concat(names, ", "))
			else
				notify("no session named '" .. token .. "' found")
			end
			return
		end

		if entry.live then
			if not entry.tty or entry.tty == "" then
				-- Live but no tty on record: never resume (that would risk a
				-- second process against the same live transcript).
				notify("session '" .. token .. "' is live but has no recorded tty; not resuming")
				return
			end
			(deps.focus_tty or function(_, cb) cb(false, "no focus_tty dep") end)(entry.tty, function(ok, err)
				if not ok then
					notify("could not focus the live session's tab" .. (err and (": " .. err) or ""))
				end
			end)
		else
			(deps.open_tab or function(_, _, _, cb) cb(false, "no open_tab dep") end)(
				M.resume_command(entry.id),
				entry.id,
				entry.cwd or "",
				function(ok, err)
					if not ok then
						notify("could not resume the session" .. (err and (": " .. err) or ""))
					end
				end
			)
		end
	end)
end

M.KEYMAP = "<leader>gx"

--- Attaches the hotkey to `bufnr` on M.KEYMAP, idempotent per buffer.
function M.attach(bufnr, config)
	if vim.b[bufnr].desk_hotkey_attached then
		return
	end
	vim.b[bufnr].desk_hotkey_attached = true
	vim.keymap.set("n", M.KEYMAP, function()
		M.run(bufnr, vim.api.nvim_get_current_win(), config, M.default_deps())
	end, { buffer = bufnr, desc = "Desk: act on the token under the cursor" })
end

return M
