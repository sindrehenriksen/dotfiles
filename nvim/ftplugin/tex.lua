-- Soft wrapping
vim.opt_local.wrap = true
vim.opt_local.linebreak = true
vim.opt_local.list = false
vim.opt_local.showbreak = "↪"

-- Wider textwidth (avoid hard wrapping prose)
vim.opt_local.textwidth = 1000

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
