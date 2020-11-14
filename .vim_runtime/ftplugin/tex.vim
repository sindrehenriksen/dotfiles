" Soft wrapping
setlocal wrap linebreak nolist
setlocal showbreak=↪

" ALE linters
let b:ale_linters = ['proselint', 'chktex', 'lacheck']

" Ignore some chktex warnings:
" 2 - Non-breaking space should have been used (fixed in ref-commands).
" 24 - Delete this space to maintain correct pagereferences.
let b:ale_tex_chktex_options = '-n2 -n24'

" Next/prev error/warning map
nmap <silent> <leader>ak <Plug>(ale_previous_wrap)
nmap <silent> <leader>aj <Plug>(ale_next_wrap)

" Turn of syntax highlighting for underscorers in custom ref commands
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

" Increase textwidth (before automatich hard wrap)
set textwidth=1000
