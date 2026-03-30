return {
	{
		"airblade/vim-gitgutter",
		event = "BufReadPost",
		init = function()
			vim.keymap.set("n", "<leader>gj", "<Plug>(GitGutterNextHunk)")
			vim.keymap.set("n", "<leader>gk", "<Plug>(GitGutterPrevHunk)")
			vim.keymap.set("n", "<leader>ga", "<Plug>(GitGutterStageHunk)")
			vim.keymap.set("n", "<leader>gu", "<Plug>(GitGutterUndoHunk)")
		end,
	},
}
