-- Minimal headless init for the review tests: puts this repo's nvim/ (so
-- require("desk.xxx") resolves the normal way, via 'runtimepath') and the
-- already-installed gitsigns.nvim plugin on 'runtimepath', and nothing
-- else — no lazy.nvim, no other plugins, no user options beyond what a
-- test itself needs.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local nvim_dir = here .. "/.."
vim.opt.rtp:prepend(nvim_dir)
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/lazy/gitsigns.nvim"))
vim.g.mapleader = " "
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = false

-- Shared safety net for any test here that runs real git commands — see
-- tests/lib/git-safety.lua. Applied unconditionally: harmless for a test
-- that never touches git, and this file is the one thing every headless
-- test in nvim/tests/ already loads (`-u minimal_init.lua`).
dofile(here .. "/../../tests/lib/git-safety.lua").init()
