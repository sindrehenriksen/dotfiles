-- The review overview's list sits across the top of the editor, which a
-- terminal window in half a screen column has no room for. While the
-- overview is open the editor's window goes full height, and back when it
-- closes, through desk-window.sh (hammerspoon/, over `hs -c`). nvim names
-- its own terminal by tty and foreground pid; Hammerspoon finds that
-- terminal's window, decides whether it has a full-height form, keeps the
-- frame it left, and puts it back only while the window is still where the
-- stretch left it. Without the helper on PATH (Linux, or not installed), or
-- when nvim can't name its terminal, nothing happens.
--
-- What the window should be is kept apart from what was last asked of
-- Hammerspoon. One call runs at a time, and each one, when it comes back,
-- starts the call that gets the two in line again, so a list closed and
-- reopened quickly never has its stretch and its restore cross. A stretch
-- whose answer never came back (the helper timed out while Hammerspoon went
-- on) still gets its restore: Hammerspoon keeps the frame by terminal, and
-- restoring one it never stretched does nothing.
--
-- Every call goes through M.run, and the terminal is found by M.owner_fn,
-- both of which a test replaces.
local M = {}

M.TIMEOUT_MS = 10000

local want = false -- the overview is open
local asked = false -- Hammerspoon may hold a stretch for this terminal
local busy = false -- a call is running
local leaving = false -- nvim is quitting: no call starts but leave's own
local warned = false
local leave_installed = false
local owner_cache = nil

--- The default runner: `desk-window.sh <args...>`, `cb(ok, output)` on the
--- main loop. With `sync`, waits for it (for VimLeavePre). `ok` false with
--- a nil output means there is no helper.
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

local function ps(pid)
	local res = vim.system({ "ps", "-o", "tty=,comm=", "-p", tostring(pid) }, { text = true }):wait()
	return (res.stdout or ""):match("^%s*(%S+)%s+(.-)%s*$")
end

--- The terminal this nvim runs in, as { tty, pid }: the pid in the
--- terminal's foreground is this process, or since nvim 0.10 its TUI
--- parent, the one holding the tty. nil when neither holds one.
function M.default_owner()
	for _, pid in ipairs({ vim.fn.getpid(), vim.uv.os_getppid() }) do
		local ok, tty, comm = pcall(ps, pid)
		if ok and tty and tty:match("^ttys?%d+$") and comm and comm:match("nvim") then
			return { tty = tty, pid = tostring(pid) }
		end
	end
	return nil
end

M.owner_fn = M.default_owner

local function owner()
	if owner_cache == nil then
		owner_cache = M.owner_fn() or false
	end
	return owner_cache or nil
end

--- For tests: forget everything, the terminal included.
function M.reset()
	want, asked, busy, leaving, warned, owner_cache = false, false, false, false, false, nil
end

--- The state, for tests.
function M.state()
	return { want = want, asked = asked, busy = busy }
end

local function warn(out)
	-- Said once: an overview opened every few minutes should not repeat
	-- that Hammerspoon is not answering.
	if out and out ~= "" and not warned then
		warned = true
		vim.notify("desk: couldn't make the window full height: " .. out, vim.log.levels.WARN)
	end
end

-- Starts the call that brings what was asked in line with what is wanted.
local function step()
	if busy or leaving then
		return
	end
	local who = owner()
	if not who then
		return
	end
	if want and not asked then
		busy, asked = true, true
		M.run({ "tall", who.tty, who.pid }, function(ok, out)
			busy = false
			if not ok then
				warn(out)
			end
			step()
		end)
	elseif not want and asked then
		busy, asked = true, false
		M.run({ "restore", who.tty, who.pid }, function()
			busy = false
			step()
		end)
	end
end

local function install_leave()
	if leave_installed then
		return
	end
	leave_installed = true
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			M.leave()
		end,
	})
end

--- The overview opened: the window should be full height.
function M.tall()
	install_leave()
	want = true
	step()
end

--- The overview closed: the window should be back.
function M.restore()
	want = false
	step()
end

--- nvim is quitting: waits for a call still running, then restores
--- synchronously, since nothing runs after this.
function M.leave()
	want, leaving = false, true
	if busy then
		vim.wait(M.TIMEOUT_MS + 1000, function()
			return not busy
		end, 20)
	end
	local who = owner()
	if asked and who and not busy then
		asked = false
		M.run({ "restore", who.tty, who.pid }, function() end, true)
	end
end

return M
