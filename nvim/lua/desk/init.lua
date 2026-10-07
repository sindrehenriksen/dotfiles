-- Entry point: enables the desk review system and annotations
-- and hotkey, only in the notes files, detected by a local marker in the
-- notes repo so this config never
-- names where the notes repo lives.
local M = {}

function M.setup()
	local review = require("desk.review")
	local annotate = require("desk.annotate")
	local hotkey = require("desk.hotkey")
	local tokens = require("desk.tokens")

	-- The notes files are the config's `files` (default notes.md and
	-- reading.md); the marker file still decides whether a buffer is one.
	local patterns = { "notes.md", "reading.md" }
	local cfg = select(1, tokens.load())
	if cfg and type(cfg.files) == "table" and #cfg.files > 0 then
		patterns = {}
		for _, f in ipairs(cfg.files) do
			patterns[#patterns + 1] = f
		end
	end

	-- nomodeline, buffer-local, before the file is even read: a notes file
	-- routinely holds pasted/captured text (a session transcript, a
	-- fetched page) nobody wrote by hand to be safe vim config, so it
	-- never gets to act as one. This has to run on BufReadPre rather than
	-- BufEnter (below) — modelines are processed once, while the file is
	-- read, which is already over by the time BufEnter fires.
	vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
		pattern = patterns,
		callback = function(args)
			local dir = vim.fn.fnamemodify(args.file, ":p:h")
			if not review.has_marker(dir) then
				return
			end
			vim.bo[args.buf].modeline = false
		end,
	})

	vim.api.nvim_create_autocmd("BufEnter", {
		pattern = patterns,
		callback = function(args)
			local dir = vim.fn.fnamemodify(args.file, ":p:h")
			if not review.has_marker(dir) then
				return
			end
			review.attach(args.buf)

			-- Links are written `[label](url)`: show the label and reveal the
			-- URL on the cursor line (concealcursor left at its empty default).
			-- The conceal comes from the markdown tree-sitter highlights; the
			-- legacy syntax file does not hide link URLs, so start them here
			-- when nothing else has.
			if not vim.treesitter.highlighter.active[args.buf] then
				pcall(vim.treesitter.start, args.buf, "markdown")
			end
			vim.opt_local.conceallevel = 2

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
