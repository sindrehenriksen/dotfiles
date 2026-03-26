" Neovim initial config — loads existing VimScript config for compatibility.
" This will be replaced by init.lua in Phase 1b.

set runtimepath+=~/dotfiles/.vim_runtime

source ~/dotfiles/.vim_runtime/plugins.vim
source ~/dotfiles/.vim_runtime/config.vim
source ~/dotfiles/.vim_runtime/plugins_config.vim
