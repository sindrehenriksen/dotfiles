return {
	{
		"nvim-treesitter/nvim-treesitter",
		branch = "master",
		build = ":TSUpdate",
		main = "nvim-treesitter.configs",
		opts = {
			ensure_installed = {
				"python", "bash", "json", "yaml", "toml",
				"lua", "typescript", "javascript",
			},
		},
	},
}
