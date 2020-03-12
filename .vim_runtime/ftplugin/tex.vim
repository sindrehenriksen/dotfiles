" Soft wrapping
setlocal wrap linebreak nolist
setlocal showbreak=↪

" ALE linters
let b:ale_linters = ['proselint', 'chktex', 'lacheck']

" Ignore some chktex warnings:
" 2 - Non-breaking space should have been used (fixed in ref-commands).
" 24 - Delete this space to maintain correct pagereferences.
let b:ale_tex_chktex_options = '-n2 -n24'
