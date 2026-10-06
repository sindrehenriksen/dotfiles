-- Entry point: enables the desk review system (D6) and D7's annotations
-- and hotkey, only in the notes files, detected by a local marker in the
-- notes repo so this config never
-- names where the notes repo lives.
local M = {}

function M.setup()
	local review = require("desk.review")
	local annotate = require("desk.annotate")
	local hotkey = require("desk.hotkey")
	local tokens = require("desk.tokens")

	-- nomodeline, buffer-local, before the file is even read: a notes file
	-- routinely holds pasted/captured text (a session transcript, a
	-- fetched page) nobody wrote by hand to be safe vim config, so it
	-- never gets to act as one. This has to run on BufReadPre rather than
	-- BufEnter (below) — modelines are processed once, while the file is
	-- read, which is already over by the time BufEnter fires.
	vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
		pattern = { "notes.md", "reading.md" },
		callback = function(args)
			local dir = vim.fn.fnamemodify(args.file, ":p:h")
			if not review.has_marker(dir) then
				return
			end
			vim.bo[args.buf].modeline = false
		end,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = { "notes.md", "reading.md" },
		callback = function(args)
			local dir = vim.fn.fnamemodify(args.file, ":p:h")
			if not review.has_marker(dir) then
				return
			end
			review.attach(args.buf)

			-- The tokens config is instantiation-specific and can be genuinely absent while dotfiles is
			-- being exercised on its own (e.g. these tests): a missing or
			-- invalid config just means annotations/hotkey have nothing to
			-- classify against, not a load error in the notes buffer.
			local config = select(1, tokens.load())
			annotate.attach(args.buf, config or { tokens = {} })
			hotkey.attach(args.buf, config or { tokens = {} })
		end,
	})
end

return M
