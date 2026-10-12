-- The review overview's list sits across the top of the editor, which a
-- terminal window in half a screen column has no room for. While the
-- overview is open its window goes full height, and back when it closes,
-- through desk-window.sh (hammerspoon/, over `hs -c`). Hammerspoon decides
-- whether the window is at a placement with a full-height form, and puts it
-- back only while it is still where it was left. Without the helper on
-- PATH (Linux, or not installed) nothing happens.
--
-- Every call goes through M.run, which a test replaces; the default runs
-- the helper async, so opening the list never waits on it.
local M = {}

M.TIMEOUT_MS = 10000

-- nil, or the window's state: { phase = "pending", restore_wanted = bool }
-- while the stretch is on its way, { phase = "tall", args = {...} } once
-- Hammerspoon has stretched it.
local state = nil
local warned = false
local leave_installed = false

--- The default runner: `desk-window.sh <args...>`, `cb(ok, output)` on the
--- main loop. With `sync`, waits for it (for VimLeavePre, which can't wait
--- on a callback). `ok` false with a nil output means there is no helper.
function M.default_run(args, cb, sync)
	local v = vim.env.DESK_WINDOW_BIN
	local cmd = (v and v ~= "") and v or "desk-window.sh"
	if vim.fn.executable(cmd) ~= 1 then
		cb(false, nil)
		return
	end
	local argv = { cmd }
	vim.list_extend(argv, args)
	local function done(res)
		local out = vim.trim(res.stdout or "")
		cb(res.code == 0, res.code == 0 and out or vim.trim(out .. " " .. (res.stderr or "")))
	end
	local ok, err = pcall(function()
		if sync then
			done(vim.system(argv, { text = true, timeout = 3000 }):wait())
		else
			vim.system(argv, { text = true, timeout = M.TIMEOUT_MS }, function(res)
				vim.schedule(function()
					done(res)
				end)
			end)
		end
	end)
	if not ok then
		cb(false, tostring(err))
	end
end

M.run = M.default_run

--- For tests: forget any stretched window and the one-time warning.
function M.reset()
	state = nil
	warned = false
end

--- The current state, for tests.
function M.state()
	return state
end

local function parse(out)
	local nums = {}
	for n in (out or ""):gmatch("%-?%d+") do
		nums[#nums + 1] = n
	end
	return #nums == 9 and nums or nil
end

local function install_leave()
	if leave_installed then
		return
	end
	leave_installed = true
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			M.restore(true)
		end,
	})
end

--- Stretches the editor's window, unless it already is or is on its way.
function M.tall()
	if state then
		state.restore_wanted = nil
		return
	end
	install_leave()
	local mine = { phase = "pending" }
	state = mine
	M.run({ "tall" }, function(ok, out)
		if state ~= mine then
			return
		end
		state = nil
		if not ok then
			-- Said once: an overview opened every few minutes should not
			-- repeat that Hammerspoon is not answering.
			if out and out ~= "" and not warned then
				warned = true
				vim.notify("desk: couldn't make the window full height: " .. out, vim.log.levels.WARN)
			end
			return
		end
		local args = parse(out)
		if not args then
			return -- "none": not at a placement with a full-height form
		end
		state = { phase = "tall", args = args }
		if mine.restore_wanted then
			M.restore()
		end
	end)
end

--- Puts the window back where M.tall found it. A window gone or moved
--- since is left alone, by Hammerspoon, without a word.
function M.restore(sync)
	if not state then
		return
	end
	if state.phase == "pending" then
		state.restore_wanted = true
		return
	end
	local argv = { "restore" }
	vim.list_extend(argv, state.args)
	state = nil
	M.run(argv, function() end, sync)
end

return M
