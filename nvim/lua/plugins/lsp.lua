return {
	-- Mason: manage LSP servers, linters, formatters
	{
		"williamboman/mason.nvim",
		cmd = "Mason",
		opts = {},
	},

	-- Bridge mason ↔ lspconfig
	{
		"williamboman/mason-lspconfig.nvim",
		dependencies = { "williamboman/mason.nvim" },
		opts = {
			ensure_installed = { "basedpyright", "ts_ls", "texlab", "lua_ls" },
		},
	},

	-- LSP server configs (provides default cmd, filetypes, root_dir)
	{
		"neovim/nvim-lspconfig",
		event = "VeryLazy",
		dependencies = {
			"williamboman/mason-lspconfig.nvim",
			"saghen/blink.cmp",
		},
		config = function()
			-- Shared config for all servers
			vim.lsp.config("*", {
				capabilities = require("blink.cmp").get_lsp_capabilities(),
			})

			-- Server-specific settings
			vim.lsp.config("lua_ls", {
				settings = {
					Lua = {
						runtime = { version = "LuaJIT" },
						workspace = {
							checkThirdParty = false,
							library = { vim.env.VIMRUNTIME },
						},
						telemetry = { enable = false },
					},
				},
			})

			-- Enable servers
			vim.lsp.enable({ "basedpyright", "ts_ls", "texlab", "lua_ls" })

			-- Keymaps on LSP attach
			vim.api.nvim_create_autocmd("LspAttach", {
				callback = function(args)
					local client = vim.lsp.get_client_by_id(args.data.client_id)
					local bufnr = args.buf
					local map = function(mode, lhs, rhs, desc)
						vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
					end

					map("n", "gd", vim.lsp.buf.definition, "Go to definition")
					map("n", "gr", vim.lsp.buf.references, "References")
					map("n", "gy", vim.lsp.buf.type_definition, "Type definition")
					map("n", "gI", vim.lsp.buf.implementation, "Implementation")
					map("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
					map({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, "Code action")

					-- Highlight symbol under cursor
					if client and client.supports_method("textDocument/documentHighlight") then
						local group = vim.api.nvim_create_augroup("lsp_highlight_" .. bufnr, { clear = true })
						vim.api.nvim_create_autocmd("CursorHold", {
							group = group,
							buffer = bufnr,
							callback = vim.lsp.buf.document_highlight,
						})
						vim.api.nvim_create_autocmd("CursorMoved", {
							group = group,
							buffer = bufnr,
							callback = vim.lsp.buf.clear_references,
						})
					end
				end,
			})

			vim.diagnostic.config({
				virtual_text = true,
				signs = true,
				underline = true,
				update_in_insert = false,
			})
		end,
	},

	-- Completion
	{
		"saghen/blink.cmp",
		version = "1.*",
		dependencies = { "rafamadriz/friendly-snippets" },
		opts = {
			keymap = { preset = "super-tab" },
			appearance = { nerd_font_variant = "mono" },
			sources = {
				default = { "lsp", "path", "snippets", "buffer" },
			},
			completion = {
				accept = { auto_brackets = { enabled = true } },
				documentation = { auto_show = true },
			},
		},
	},

	-- Formatting
	{
		"stevearc/conform.nvim",
		event = "BufWritePre",
		cmd = "ConformInfo",
		keys = {
			{
				"<leader>cf",
				function()
					require("conform").format({ async = true, lsp_fallback = true })
				end,
				mode = { "n", "v" },
				desc = "Format",
			},
		},
		opts = {
			formatters_by_ft = {
				python = { "ruff_format" },
				javascript = { "prettier" },
				typescript = { "prettier" },
				lua = { "stylua" },
				tex = { "latexindent" },
			},
			format_on_save = false,
		},
	},

	-- Linting (non-LSP)
	{
		"mfussenegger/nvim-lint",
		event = { "BufReadPost", "BufWritePost" },
		config = function()
			require("lint").linters_by_ft = {
				tex = { "proselint" },
			}
			vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
				callback = function()
					require("lint").try_lint()
				end,
			})
		end,
	},
}
