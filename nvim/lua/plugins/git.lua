return {
	{
		"lewis6991/gitsigns.nvim",
		event = "BufReadPost",
		opts = {
			on_attach = function(bufnr)
				local gs = require("gitsigns")
				local map = function(mode, lhs, rhs, desc)
					vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
				end

				map("n", "<leader>gj", gs.next_hunk, "Next hunk")
				map("n", "<leader>gk", gs.prev_hunk, "Previous hunk")
				map("n", "<leader>ga", gs.stage_hunk, "Stage hunk")
				-- Visual mode: calling gs.stage_hunk directly (as above)
				-- ignores the selection — with no range argument gitsigns
				-- falls back to "the hunk under the cursor" and stages the
				-- WHOLE hunk even when only part of it is selected. The Ex
				-- command form is range-aware (`:'<,'>Gitsigns stage_hunk`,
				-- which a visual-mode `:` mapping supplies automatically),
				-- and supports a partial hunk, so visual presses route
				-- through it instead.
				map("v", "<leader>ga", ":Gitsigns stage_hunk<CR>", "Stage selected lines")
				map("n", "<leader>gu", gs.reset_hunk, "Reset hunk")
				map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
				map("n", "<leader>gb", gs.blame_line, "Blame line")
			end,
		},
	},
}
