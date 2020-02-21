## Init
. ~/.zprofile
source ~/.zplug/init.zsh

## General
source .shellrc
alias szsh="source ~/.zshrc"
alias vzsh="vim ~/.zshrc"

## ZSH keybindings
bindkey '^ ' autosuggest-accept

## Plugins
# Fish like autocompletions
zplug "zsh-users/zsh-autosuggestions"

# Highlighting in terminal
zplug "zsh-users/zsh-syntax-highlighting"

# For faster, history based cd'ing using "z" instead
zplug "plugins/z", from:oh-my-zsh

# Load theme file
zplug "mafredri/zsh-async", from:github
zplug "sindresorhus/pure", use:pure.zsh, from:github, as:theme

# Fuzzy searchable cd command
zplug "b4b4r07/enhancd", use:init.sh

# Load
zplug load
