return {
	-- Gruvbox colorscheme (Lua port with treesitter/LSP support)
	{
		"ellisonleao/gruvbox.nvim",
		lazy = false,
		priority = 1000,
		config = function()
			require("gruvbox").setup({
				contrast = "hard",
			})
			vim.cmd.colorscheme("gruvbox")
		end,
	},

	-- Delete buffers without closing windows
	{
		"echasnovski/mini.bufremove",
		keys = {
			{ "<leader>bd", function() require("mini.bufremove").delete(0) end, desc = "Delete buffer" },
		},
	},

	-- Copilot (accept with C-y, Tab owned by blink.cmp)
	{
		"github/copilot.vim",
		event = "InsertEnter",
		init = function()
			vim.g.copilot_no_tab_map = true
		end,
		config = function()
			vim.keymap.set("i", "<C-y>", 'copilot#Accept("<CR>")', { expr = true, replace_keycodes = false })
		end,
	},

	-- Show available keybindings after pressing leader
	{
		"folke/which-key.nvim",
		event = "VeryLazy",
		opts = {},
	},

	-- File explorer as a buffer
	{
		"stevearc/oil.nvim",
		keys = {
			{ "-", "<cmd>Oil<cr>", desc = "Open parent directory" },
		},
		opts = {},
	},

	-- Side-by-side diffs
	{
		"sindrets/diffview.nvim",
		cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
		keys = {
			{ "<leader>dv", "<cmd>DiffviewOpen<cr>", desc = "Diffview open" },
			{ "<leader>dc", "<cmd>DiffviewClose<cr>", desc = "Diffview close" },
			{ "<leader>dh", "<cmd>DiffviewFileHistory %<cr>", desc = "File history" },
		},
		opts = {},
	},
}
