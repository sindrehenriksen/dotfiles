call plug#begin('~/.vim/plugged')

" Colorscheme
Plug 'morhetz/gruvbox'

" vim-gitgutter
Plug 'airblade/vim-gitgutter'

" fzf.vim
Plug 'junegunn/fzf', { 'do': './install --bin' }
Plug 'junegunn/fzf.vim'

" vimtex
Plug 'lervag/vimtex'

" ale
Plug 'dense-analysis/ale'

" coc.nvim
Plug 'neoclide/coc.nvim', {'branch': 'release'}

call plug#end()
