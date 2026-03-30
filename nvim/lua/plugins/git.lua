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
				map({ "n", "v" }, "<leader>ga", gs.stage_hunk, "Stage hunk")
				map("n", "<leader>gu", gs.reset_hunk, "Reset hunk")
				map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
				map("n", "<leader>gb", gs.blame_line, "Blame line")
			end,
		},
	},
}
