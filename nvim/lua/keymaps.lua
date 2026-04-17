local map = vim.keymap.set

-- Clear search highlight
map("n", "<leader><cr>", "<cmd>noh<cr>", { silent = true })

if not vim.g.vscode then
	-- Window navigation (Dvorak home row: h=left, t=up, n=down, s=right)
	map("n", "<C-h>", "<C-W>h")
	map("n", "<C-t>", "<C-W>k")
	map("n", "<C-n>", "<C-W>j")
	map("n", "<C-s>", "<C-W>l")

	-- Buffer navigation
	map("n", "<leader>j", "<cmd>bnext<cr>")
	map("n", "<leader>k", "<cmd>bprevious<cr>")
	map("n", "<leader>ba", "<cmd>bufdo bd<cr>")

	-- Tab management
	map("n", "<leader>wo", "<cmd>only<cr>")
	map("n", "<leader>to", "<cmd>tabonly<cr>")
	map("n", "<leader>tn", "<cmd>tabnew<cr>")
	map("n", "<leader>tc", "<cmd>tabclose<cr>")
end

-- Remap 0 to first non-blank character
map("n", "0", "^")

-- Move lines with Alt+j/k
map("n", "<M-j>", "<cmd>m .+1<cr>==")
map("n", "<M-k>", "<cmd>m .-2<cr>==")
map("v", "<M-j>", ":m '>+1<cr>gv=gv")
map("v", "<M-k>", ":m '<-2<cr>gv=gv")

-- Visual mode * and # search
map("v", "*", [[y/\V<C-R>=escape(@",'/\')<CR><CR>]], { silent = true })
map("v", "#", [[y?\V<C-R>=escape(@",'/\')<CR><CR>]], { silent = true })

-- Clipboard shortcuts
map({ "n", "v" }, "<leader>y", '"+y', { desc = "Copy to clipboard" })
map("n", "<leader>p", '"+p', { desc = "Paste from clipboard" })

if not vim.g.vscode then
	-- Switch CWD to the directory of the open buffer
	map("n", "<leader>cd", "<cmd>cd %:p:h<cr><cmd>pwd<cr>")

	-- Scratch buffers
	map("n", "<leader>q", "<cmd>e ~/buffer<cr>")
	map("n", "<leader>x", "<cmd>e ~/buffer.md<cr>")

	-- Edit config
	map("n", "<leader>e", "<cmd>e ~/dotfiles/nvim/init.lua<cr>")

	-- Sudo save
	vim.api.nvim_create_user_command("W", "w !sudo tee % > /dev/null | edit!", {})
end

