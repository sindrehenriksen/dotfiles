-- Leader must be set before lazy
vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("options")
require("keymaps")

if vim.g.vscode then
	-- VS Code handles UI, LSP, git, etc. — only load keymaps/options above.
	return
end

require("autocmds")

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup("plugins", {
	rocks = { enabled = false },
})
