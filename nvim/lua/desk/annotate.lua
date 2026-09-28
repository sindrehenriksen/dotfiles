-- D7: annotations (design.md §2 "Annotations and the hotkey"). Per-token
-- virtual text: a session-name token shows live/idle/ended state from the
-- reader (§3), a ticket-like token (any token this instantiation's config
-- classifies as a url handler) shows status from the ticket cache the
-- runner writes. Both are computed async, via the reader as an external
-- process — never blocking typing — and repainted on BufEnter/FocusGained.
--
-- The ticket cache's path and shape are this module's to define (design.md
-- §6: dotfiles owns each format the runner instantiates against); neither
-- design.md nor the runner side pins one yet. Assumed shape, read-only
-- here: `{"checked_at": <unix seconds>, "tickets": {"<TOKEN>": {"status":
-- "..."}, ...}}`, keyed by the token text itself (case-insensitive lookup —
-- his notes mix casing on a ticket key) rather than by anything Jira-specific,
-- so this stays generic across whatever url-handler tokens an instantiation
-- configures. If the runner ends up writing something else, this is the
-- one place to change.
local tokens = require("desk.tokens")
local reader = require("desk.reader")

local M = {}

M.ns = vim.api.nvim_create_namespace("desk_annotate")

--- The ticket cache path, overridable (`$DESK_TICKET_CACHE`) the same way
--- every other desk path is.
function M.ticket_cache_path()
	local override = vim.env.DESK_TICKET_CACHE
	return vim.fn.expand((override and override ~= "") and override or "~/.local/state/desk/ticket-status.json")
end

--- Reads and parses the ticket cache, or nil if it's absent/invalid — an
--- annotation simply doesn't show rather than erroring.
function M.read_ticket_cache(path)
	path = path or M.ticket_cache_path()
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local data = fd:read("*a")
	fd:close()
	local ok, parsed = pcall(vim.json.decode, data)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	return parsed
end

--- The cache age as "N minutes"/"N hours"/"N days", or nil if `checked_at`
--- is missing.
local function format_cache_age(checked_at, now)
	if not checked_at then
		return nil
	end
	now = now or os.time()
	local mins = math.floor((now - checked_at) / 60)
	if mins < 60 then
		return mins .. (mins == 1 and " minute" or " minutes")
	end
	local hours = math.floor(mins / 60)
	if hours < 24 then
		return hours .. (hours == 1 and " hour" or " hours")
	end
	local days = math.floor(hours / 24)
	return days .. (days == 1 and " day" or " days")
end

--- The display text for a ticket-like token from the cache, or nil if the
--- cache has nothing for it (no annotation shown, rather than a
--- misleading blank one).
function M.ticket_text(cache, token, now)
	if not cache or not cache.tickets then
		return nil
	end
	local key = token:upper()
	local entry
	for k, v in pairs(cache.tickets) do
		if k:upper() == key then
			entry = v
			break
		end
	end
	if not entry or not entry.status then
		return nil
	end
	local age = format_cache_age(cache.checked_at, now)
	local parts = { entry.status, "status from last pass" }
	if age then
		parts[#parts + 1] = age .. " ago"
	end
	return table.concat(parts, " · ")
end

--- The display text for a session-name token, from one reader entry
--- (design.md §2: "live / idle / ended, last activity and 'closed by
--- 16:30'" — here "closed by desk", the pass isn't named in dotfiles):
---   "live"                                 — live, active recently
---   "live · idle Nd"                       — live, but quiet N days
---   "closed by desk · resumable"           — the pass closed it
---   "not running · last active <date>"     — ended any other way
function M.session_text(entry, now)
	now = now or os.time()
	if entry.live then
		local days = entry.last_activity and math.floor((now - entry.last_activity) / 86400) or 0
		if days >= 1 then
			return string.format("live · idle %dd", days)
		end
		return "live"
	end
	if entry.end_reason == "closed-by-pass" then
		return "closed by desk · resumable"
	end
	local date = entry.last_activity and os.date("%Y-%m-%d", entry.last_activity) or "unknown"
	return "not running · last active " .. date
end

--- Every token (letters, digits, `_`, `-`) in `line`, as
--- {text, start_col, end_col} (0-indexed columns, end inclusive). Exported
--- (not just this module's own internal use) so desk.cli's `tokens` verb
--- can classify a whole file in file order without a second tokenizer.
function M.tokens_in_line(line)
	local out = {}
	local s = nil
	for i = 1, #line + 1 do
		local c = line:sub(i, i)
		local is_tok = c ~= "" and c:match(tokens.TOKEN_CHARS) ~= nil
		if is_tok and not s then
			s = i
		elseif not is_tok and s then
			out[#out + 1] = { text = line:sub(s, i - 1), start_col = s - 1, end_col = i - 2 }
			s = nil
		end
	end
	return out
end

--- Every (line 1-indexed, token) pair in `lines` that classifies as
--- `wanted_kind` ("session" or "url") under `tokens_config`.
function M.scan(lines, tokens_config, wanted_kind)
	local found = {}
	for i, line in ipairs(lines) do
		for _, t in ipairs(M.tokens_in_line(line)) do
			local classification = tokens.classify(t.text, tokens_config)
			if classification.kind == wanted_kind then
				found[#found + 1] = { line = i, token = t }
			end
		end
	end
	return found
end

--- Sets one line of virtual text at `line` (1-indexed) plus, when
--- `underline`, an underline highlight over the token's own columns.
local function set_extmark(bufnr, line, token, text, underline)
	vim.api.nvim_buf_set_extmark(bufnr, M.ns, line - 1, token.start_col, {
		end_col = token.end_col + 1,
		hl_group = underline and "Underlined" or nil,
		virt_text = { { text, "Comment" } },
		virt_text_pos = "eol",
	})
end

--- Redraws every session-name and ticket-like annotation in `bufnr` from
--- scratch. Async end to end: the reader call never blocks, and nothing
--- here is called from inside a fast-event context.
function M.refresh(bufnr, config)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local tokens_config = tokens.tokens_from(config)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local session_hits = M.scan(lines, tokens_config, "session")
	local ticket_hits = M.scan(lines, tokens_config, "url")

	-- Tickets: synchronous (a local file, no external process) — paint
	-- immediately rather than waiting on the (separate) session lookup.
	local cache = M.read_ticket_cache()
	if cache then
		vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
		for _, hit in ipairs(ticket_hits) do
			local text = M.ticket_text(cache, hit.token.text)
			if text then
				set_extmark(bufnr, hit.line, hit.token, text, false)
			end
		end
	end

	if #session_hits == 0 then
		return
	end

	-- Sessions: async via the reader, one call for the whole buffer rather
	-- than one per token.
	reader.all(function(ok, entries)
		if not ok or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local by_name = {}
		for _, e in ipairs(entries) do
			if e.name and e.name ~= "" then
				by_name[e.name] = e
			end
		end
		for _, hit in ipairs(session_hits) do
			local entry = by_name[hit.token.text]
			if entry then
				set_extmark(bufnr, hit.line, hit.token, M.session_text(entry), true)
			end
		end
	end)
end

--- Wires BufEnter/FocusGained repaint for `bufnr`, guarded by desk.review's
--- own notes-repo marker so this never fires outside the notes files.
--- Idempotent per buffer.
function M.attach(bufnr, config)
	if vim.b[bufnr].desk_annotate_attached then
		return
	end
	vim.b[bufnr].desk_annotate_attached = true
	vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
		buffer = bufnr,
		callback = function()
			M.refresh(bufnr, config)
		end,
	})
	M.refresh(bufnr, config)
end

return M
