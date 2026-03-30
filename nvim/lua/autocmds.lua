local autocmd = vim.api.nvim_create_autocmd

-- Reload file when changed externally
autocmd({ "FocusGained", "BufEnter" }, {
	command = "checktime",
})

-- Return to last edit position when opening files
autocmd("BufReadPost", {
	callback = function()
		local mark = vim.api.nvim_buf_get_mark(0, '"')
		local line_count = vim.api.nvim_buf_line_count(0)
		if mark[1] > 1 and mark[1] <= line_count then
			vim.api.nvim_win_set_cursor(0, mark)
		end
	end,
})

-- Clean trailing whitespace on save
autocmd("BufWritePre", {
	pattern = { "*.txt", "*.js", "*.py", "*.wiki", "*.sh", "*.coffee", "*.lua" },
	callback = function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local search = vim.fn.getreg("/")
		vim.cmd([[silent! %s/\s\+$//e]])
		vim.api.nvim_win_set_cursor(0, cursor)
		vim.fn.setreg("/", search)
	end,
})

-- Last accessed tab tracking
vim.g.lasttab = 1
autocmd("TabLeave", {
	callback = function()
		vim.g.lasttab = vim.fn.tabpagenr()
	end,
})
vim.keymap.set("n", "<leader>tl", function()
	vim.cmd("tabn " .. vim.g.lasttab)
end)
