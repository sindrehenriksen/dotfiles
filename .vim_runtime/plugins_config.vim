"""" vim-gitgutter

" Jump between hunks
nmap <Leader>gj <Plug>(GitGutterNextHunk)
nmap <Leader>gk <Plug>(GitGutterPrevHunk)

" Hunk-add and hunk-revert for chunk staging
nmap <Leader>ga <Plug>(GitGutterStageHunk)
nmap <Leader>gu <Plug>(GitGutterUndoHunk)


"""" fzf.vim
nnoremap <silent> <leader>o :Files<CR>
nnoremap <silent> <leader>O :Files!<CR>
nnoremap <silent> <leader>b :Buffers<CR>
nnoremap <silent> <leader>l :BLines<CR>
nnoremap <silent> <leader>L :Lines<CR>
