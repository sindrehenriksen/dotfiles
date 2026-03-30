return {
	{
		"junegunn/fzf",
		build = "./install --bin",
	},
	{
		"junegunn/fzf.vim",
		dependencies = { "junegunn/fzf" },
		keys = {
			{ "<leader>o", "<cmd>Files<cr>", desc = "Find files" },
			{ "<leader>O", "<cmd>Files!<cr>", desc = "Find files (fullscreen)" },
			{ "<leader>b", "<cmd>Buffers<cr>", desc = "Buffers" },
			{ "<leader>l", "<cmd>BLines<cr>", desc = "Buffer lines" },
			{ "<leader>L", "<cmd>Lines<cr>", desc = "All lines" },
		},
	},
}
