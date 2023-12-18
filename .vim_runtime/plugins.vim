call plug#begin('~/.vim/plugged')

" Colorscheme
Plug 'morhetz/gruvbox'

" vim-gitgutter - for git diff in sign column and hunk staging/undo
Plug 'airblade/vim-gitgutter'

" fzf.vim - vim fuzzy searching
Plug 'junegunn/fzf', { 'do': './install --bin' }
Plug 'junegunn/fzf.vim'

" vimtex - support for writing latex files
Plug 'lervag/vimtex'

" ale - linting
Plug 'dense-analysis/ale'

" coc.nvim - autocompletion
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" vim-slime - code execution
Plug 'jpalardy/vim-slime', {'branch': 'main'}

call plug#end()
