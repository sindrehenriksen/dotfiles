return {
	-- coc.nvim (keeping for now, will be replaced by native LSP in Phase 1c)
	{
		"neoclide/coc.nvim",
		branch = "release",
		event = "BufReadPost",
		init = function()
			-- Tab completion
			vim.cmd([[
				inoremap <silent><expr> <TAB>
					\ pumvisible() ? "\<C-n>" :
					\ "\<TAB>"
				inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
			]])

			-- Trigger completion
			vim.keymap.set("i", "<c-space>", "coc#refresh()", { silent = true, expr = true })

			-- Diagnostics navigation
			vim.keymap.set("n", "[g", "<Plug>(coc-diagnostic-prev)", { silent = true })
			vim.keymap.set("n", "]g", "<Plug>(coc-diagnostic-next)", { silent = true })

			-- GoTo code navigation
			vim.keymap.set("n", "gd", "<Plug>(coc-definition)", { silent = true })
			vim.keymap.set("n", "gy", "<Plug>(coc-type-definition)", { silent = true })
			vim.keymap.set("n", "gi", "<Plug>(coc-implementation)", { silent = true })
			vim.keymap.set("n", "gr", "<Plug>(coc-references)", { silent = true })

			-- Hover docs
			vim.keymap.set("n", "K", function()
				if vim.tbl_contains({ "vim", "help" }, vim.bo.filetype) then
					vim.cmd("h " .. vim.fn.expand("<cword>"))
				else
					vim.fn.CocActionAsync("doHover")
				end
			end, { silent = true })

			-- Highlight symbol under cursor
			vim.api.nvim_create_autocmd("CursorHold", {
				callback = function()
					if vim.fn.exists("*CocActionAsync") == 1 then
						vim.fn.CocActionAsync("highlight")
					end
				end,
			})

			-- Rename
			vim.keymap.set("n", "<leader>rn", "<Plug>(coc-rename)")

			-- Format selected
			vim.keymap.set({ "x", "n" }, "<leader>cf", "<Plug>(coc-format-selected)")

			-- Code actions
			vim.keymap.set({ "x", "n" }, "<leader>ca", "<Plug>(coc-codeaction-selected)")
			vim.keymap.set("n", "<leader>cl", "<Plug>(coc-codeaction)")
			vim.keymap.set("n", "<leader>cq", "<Plug>(coc-fix-current)")

			-- Function text objects
			vim.keymap.set({ "x", "o" }, "if", "<Plug>(coc-funcobj-i)")
			vim.keymap.set({ "x", "o" }, "af", "<Plug>(coc-funcobj-a)")

			-- Selection ranges
			vim.keymap.set({ "n", "x" }, "<TAB>", "<Plug>(coc-range-select)", { silent = true })

			-- Commands
			vim.api.nvim_create_user_command("Format", "call CocAction('format')", {})
			vim.api.nvim_create_user_command("Fold", function(opts)
				vim.fn.CocAction("fold", opts.args)
			end, { nargs = "?" })
			vim.api.nvim_create_user_command("OR", "call CocAction('runCommand', 'editor.action.organizeImport')", {})

			-- Statusline
			vim.opt.statusline:prepend("%{coc#status()}%{get(b:,'coc_current_function','')}")
		end,
	},

	-- ALE (keeping for now, will be replaced by conform + nvim-lint in Phase 1c)
	{
		"dense-analysis/ale",
		event = "BufReadPost",
		init = function()
			vim.g.ale_echo_msg_error_str = "E"
			vim.g.ale_echo_msg_warning_str = "W"
			vim.g.ale_echo_msg_format = "[%linter%] %s [%severity%]"
		end,
	},
}
