return {
	{
		"nvim-telescope/telescope.nvim",
		branch = "master",
		dependencies = {
			"nvim-lua/plenary.nvim",
			{ "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
		},
		keys = {
			{ "<leader>o", "<cmd>Telescope find_files<cr>", desc = "Find files" },
			{
				"<leader>O",
				function()
					require("telescope.builtin").find_files({ no_ignore = true })
				end,
				desc = "Find files (all)",
			},
			{ "<leader>b", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
			{ "<leader>l", "<cmd>Telescope current_buffer_fuzzy_find<cr>", desc = "Buffer lines" },
			{ "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "Live grep" },
		},
		config = function()
			require("telescope").setup({
				defaults = {
					file_ignore_patterns = { "node_modules", ".git/" },
				},
			})
			require("telescope").load_extension("fzf")
		end,
	},
}
