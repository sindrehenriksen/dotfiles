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

-- Leader must be set before lazy
vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("options")
require("keymaps")
require("autocmds")

require("lazy").setup("plugins", {
	rocks = { enabled = false },
})
