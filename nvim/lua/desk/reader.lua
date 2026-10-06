-- nvim's one entry point onto claude/session-status.sh — every session lookup (annotations, the
-- hotkey) goes through here, never a second implementation of the join.
-- Every call is async (vim.system with a callback, never :wait()): a
-- reader call must never block typing.
local M = {}

--- The reader command to run, overridable (`$DESK_READER`) so a test can
--- point this at a stub script instead of a real install, without either
--- needing dotfiles installed onto PATH or the caller hand-wiring a path
--- itself.
function M.command()
	local override = vim.env.DESK_READER
	return (override and override ~= "") and override or "session-status.sh"
end

--- Runs the reader with `args` and calls `callback(ok, lines, exit_code)`
--- once it exits — `lines` is every stdout line parsed as JSON (invalid
--- ones dropped), `ok` is whether the process itself exited 0. Never
--- blocks the caller.
function M.run(args, callback)
	vim.system({ M.command(), unpack(args or {}) }, { text = true }, function(res)
		vim.schedule(function()
			local lines = {}
			for line in (res.stdout or ""):gmatch("[^\n]+") do
				local ok, parsed = pcall(vim.json.decode, line)
				if ok and type(parsed) == "table" then
					lines[#lines + 1] = parsed
				end
			end
			callback(res.code == 0, lines, res.code)
		end)
	end)
end

--- Every known session, as entries (see the header of claude/session-status.sh, plus `pid` /
--- `tty`). `callback(ok, entries)`.
function M.all(callback)
	M.run({}, function(ok, lines)
		callback(ok, lines)
	end)
end

--- `session-status.sh resolve <token>`: `callback(result, candidates)` —
--- exactly one of the two is set. `result` is the one matched entry;
--- `candidates` is the (possibly empty) list the reader could not narrow
--- further, on a non-zero exit.
function M.resolve(token, callback)
	M.run({ "resolve", token }, function(ok, lines)
		if ok and #lines == 1 then
			callback(lines[1], nil)
		else
			callback(nil, lines)
		end
	end)
end

return M
