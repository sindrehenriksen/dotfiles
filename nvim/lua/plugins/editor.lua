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

	-- Copilot
	{
		"github/copilot.vim",
		event = "InsertEnter",
	},
}
