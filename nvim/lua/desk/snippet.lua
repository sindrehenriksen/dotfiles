-- Occurrence-aware plain-text line matching. Every snippet comparison in
-- the desk system happens through here — never a bare substring search and
-- never a Lua pattern on the snippet's own text.
local M = {}

--- Splits `text` into a list of lines, and whether it ended in a newline.
--- "" (no trailing newline) yields {}; "\n" yields { "" }.
function M.split_lines(text)
	text = text or ""
	local trailing_nl = text:sub(-1) == "\n"
	local body = trailing_nl and text:sub(1, -2) or text
	if body == "" then
		return {}, trailing_nl
	end
	local lines = {}
	for line in (body .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	return lines, trailing_nl
end

--- The inverse of split_lines: `lines` joined with "\n", trailing newline
--- restored if `trailing_nl` (or the list is empty — an empty file is just
--- an empty file, not a no-newline one).
function M.join_lines(lines, trailing_nl)
	local text = table.concat(lines, "\n")
	if #lines == 0 then
		return ""
	end
	if trailing_nl then
		text = text .. "\n"
	end
	return text
end

-- The mark the runner appends to a taken suggestion's lines in the copies a
-- call reads (claude/desk-lib/steps.sh, DESK_AGENT_MARK), with whatever
-- whitespace precedes it: a line that already ended in a space reaches the
-- call with three spaces before the mark, and a model echoing it need not
-- keep the count.
local AGENT_MARK_PAT = "%s*<<agent%-suggested>>%s*$"

--- `line` without the agent mark.
function M.unmark(line)
	return (line:gsub(AGENT_MARK_PAT, ""))
end

--- `line` as quotes are compared: without the agent mark and without
--- trailing whitespace, which a model quoting a line cannot be relied on to
--- reproduce and which the user cannot see.
function M.line_key(line)
	return (M.unmark(line):gsub("%s+$", ""))
end

--- Whether two lines are the same line, as every comparison of a snippet
--- with the text makes it (lines_match_at, so placement and the checks for
--- an item already applied, taken or removed alike): equal once each is
--- read as line_key reads it.
function M.same_line(a, b)
	return a == b or (a ~= nil and b ~= nil and M.line_key(a) == M.line_key(b))
end

--- True if lines[pos .. pos + #snippet - 1] equals `snippet` (each line as
--- same_line compares them, or exactly with `exact`), position and line
--- count both — never a scan for the snippet elsewhere.
--- An empty snippet always matches (a zero-width point) at any `pos` from
--- 1 to #lines + 1, which is what lets a pure insertion or a pure removal
--- (`before`/`after` of length 0) share this one check.
function M.lines_match_at(lines, pos, snippet, exact)
	if pos == nil or pos < 1 then
		return false
	end
	if #snippet == 0 then
		return pos <= #lines + 1
	end
	if pos + #snippet - 1 > #lines then
		return false
	end
	for i = 1, #snippet do
		local line = lines[pos + i - 1]
		if line ~= snippet[i] and (exact or not M.same_line(line, snippet[i])) then
			return false
		end
	end
	return true
end

return M
