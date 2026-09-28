-- D7: the token → handler table (design.md §9(c), §2 "the hotkey"). Reads
-- the instantiation's `tokens` list from `$DESK_CONFIG` and classifies a
-- token under the cursor into a handler — dotfiles ships no work patterns
-- of its own, only this mechanism and a generic example in its tests.
--
-- Config shape, one entry per pattern, tried in order (first match wins):
--   { pattern = "...", case_insensitive = true|false,
--     handler = "session" | "url", template = "..." }  -- template: url only
--
-- `pattern` is read as a Lua pattern, with one deliberate departure: a bare
-- `-` is always literal, never Lua's "0 or more of the previous item,
-- lazily" quantifier. That quantifier reading is almost never what a config
-- author means by a hyphen (the whole point of writing patterns like
-- `TICKET%-([0-9]+)` — or, as a config author naturally writes it without
-- the escape, `TICKET-([0-9]+)`), and matches how the same string reads as an
-- ordinary regex, which is the dialect the runner's own reader uses on the
-- same config entries (design.md §9(c): "a Lua-pattern reader (nvim) and a
-- regex reader (the runner) need to apply it the same way"). Write `%-?`
-- explicitly for an actual lazy-quantifier hyphen; nothing here needs one.
--
-- `case_insensitive` is implemented by turning each literal letter into a
-- `[Xx]` class rather than by lowercasing pattern and token, so a capture
-- group keeps the token's original casing — the `{1}`, `{2}`, … a url
-- handler's `template` substitutes are never silently lowercased.
local M = {}

--- Reads `$DESK_CONFIG` and returns its parsed JSON, or nil, an error
--- message. Takes an explicit path only for tests; real callers rely on the
--- env var, same as the runner.
function M.load(path)
	path = path or vim.env.DESK_CONFIG
	if not path or path == "" then
		return nil, "$DESK_CONFIG is not set"
	end
	path = vim.fn.expand(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil, "could not open " .. path
	end
	local data = fd:read("*a")
	fd:close()
	local ok, parsed = pcall(vim.json.decode, data)
	if not ok or type(parsed) ~= "table" then
		return nil, "invalid JSON in " .. path
	end
	return parsed
end

--- The `tokens` list out of a loaded config, or {} if absent.
function M.tokens_from(config)
	return (config and config.tokens) or {}
end

-- Compiles one config `pattern` into a Lua pattern that (a) treats a bare
-- `-` as a literal character rather than Lua's lazy-quantifier magic char,
-- and (b) — when `case_insensitive` — turns each literal letter into a
-- two-way class so matching runs against the token's real casing. Escape
-- sequences (`%` followed by one character) and the contents of a `[...]`
-- class are passed through untouched: a class's own `-` is a range
-- separator, not the magic quantifier, and already means what it looks
-- like it means.
local function compile_pattern(pattern, case_insensitive)
	local out = {}
	local i, n = 1, #pattern
	local in_class = false
	while i <= n do
		local c = pattern:sub(i, i)
		if c == "%" and i < n then
			out[#out + 1] = pattern:sub(i, i + 1)
			i = i + 2
		elseif c == "[" and not in_class then
			in_class = true
			out[#out + 1] = c
			i = i + 1
		elseif c == "]" and in_class then
			in_class = false
			out[#out + 1] = c
			i = i + 1
		elseif c == "-" and not in_class then
			out[#out + 1] = "%-"
			i = i + 1
		elseif case_insensitive and not in_class and c:match("%a") then
			out[#out + 1] = "[" .. c:lower() .. c:upper() .. "]"
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

--- True, captures if `token` matches `pattern` (config dialect, above) over
--- its whole length — never a partial/anywhere match, since a token is
--- already the exact word the cursor sits on. `captures` is the list of
--- `()` groups the pattern captured, empty if it had none.
local function full_match(token, pattern, case_insensitive)
	local compiled = compile_pattern(pattern, case_insensitive)
	local found = { token:find(compiled) }
	local s, e = found[1], found[2]
	if not s or s ~= 1 or e ~= #token then
		return false, {}
	end
	local captures = {}
	for i = 3, #found do
		captures[#captures + 1] = found[i]
	end
	return true, captures
end

--- Substitutes `{1}`, `{2}`, … in `template` with `captures`' entries (1-
--- indexed, as the config's own `{1}` numbering implies); a placeholder
--- past the end of `captures` becomes "".
local function substitute(template, captures)
	return (template or ""):gsub("{(%d+)}", function(n)
		return captures[tonumber(n)] or ""
	end)
end

--- Classifies `token` against `tokens_config` (a list of entries, as
--- above), trying each in order and returning the first match:
---   { kind = "url", url = "..." }
---   { kind = "session" }
---   { kind = "none" }   -- no entry matched at all
function M.classify(token, tokens_config)
	for _, entry in ipairs(tokens_config or {}) do
		local matched, captures = full_match(token, entry.pattern or "", entry.case_insensitive)
		if matched then
			if entry.handler == "url" then
				return { kind = "url", url = substitute(entry.template, captures) }
			elseif entry.handler == "session" then
				return { kind = "session" }
			end
		end
	end
	return { kind = "none" }
end

return M
