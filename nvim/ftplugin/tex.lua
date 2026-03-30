-- Soft wrapping
vim.opt_local.wrap = true
vim.opt_local.linebreak = true
vim.opt_local.list = false
vim.opt_local.showbreak = "↪"

-- Wider textwidth (avoid hard wrapping prose)
vim.opt_local.textwidth = 1000

-- ALE linters (Phase 1c: replace with nvim-lint + texlab LSP)
vim.b.ale_linters = { "proselint", "chktex", "lacheck" }
vim.b.ale_tex_chktex_options = "-n2 -n24"

-- ALE navigation (Phase 1c: replace with LSP diagnostic keymaps)
vim.keymap.set("n", "<leader>ak", "<Plug>(ale_previous_wrap)", { buffer = true, silent = true })
vim.keymap.set("n", "<leader>aj", "<Plug>(ale_next_wrap)", { buffer = true, silent = true })

-- Custom ref command syntax (turn off underscore highlighting)
vim.cmd([[
syn match texInputFile "\\eqref\s*\(\[.*\]\)\={.\{-}}"
	\ contains=texStatement,texInputCurlies,texInputFileOpt
syn match texInputFile "\\figref\s*\(\[.*\]\)\={.\{-}}"
	\ contains=texStatement,texInputCurlies,texInputFileOpt
syn match texInputFile "\\chapref\s*\(\[.*\]\)\={.\{-}}"
	\ contains=texStatement,texInputCurlies,texInputFileOpt
syn match texInputFile "\\secref\s*\(\[.*\]\)\={.\{-}}"
	\ contains=texStatement,texInputCurlies,texInputFileOpt
syn match texInputFile "\\algref\s*\(\[.*\]\)\={.\{-}}"
	\ contains=texStatement,texInputCurlies,texInputFileOpt
]])
