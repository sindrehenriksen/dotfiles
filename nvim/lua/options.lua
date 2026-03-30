local opt = vim.opt

-- General
opt.history = 500
opt.updatetime = 100

-- UI
opt.number = true
opt.relativenumber = true
opt.scrolloff = 7
opt.wildignore = { "*.o", "*~", "*.pyc", "*/.git/*", "*/.hg/*", "*/.svn/*", "*/.DS_Store" }
opt.ruler = true
opt.whichwrap:append("<,>,h,l")
opt.ignorecase = true
opt.smartcase = true
opt.showmatch = true
opt.matchtime = 2
opt.splitbelow = true
opt.splitright = true
opt.cmdheight = 1
opt.signcolumn = "yes"

-- Colors
opt.fileformats = { "unix", "dos", "mac" }
opt.background = "dark"
opt.termguicolors = true

-- Files and backups
opt.backup = false
opt.writebackup = false
opt.swapfile = true
opt.directory = vim.fn.stdpath("state") .. "/swap//"

-- Text, tab and indent
opt.expandtab = false
opt.shiftwidth = 4
opt.softtabstop = 4
opt.linebreak = true
opt.textwidth = 500
opt.autoindent = true
opt.smartindent = true
opt.wrap = true

-- Undo
opt.undodir = vim.fn.stdpath("state") .. "/undo//"
opt.undofile = true

-- Buffers
opt.switchbuf = { "useopen", "usetab", "newtab" }
opt.showtabline = 2

-- LaTeX
vim.g.tex_flavor = "latex"
