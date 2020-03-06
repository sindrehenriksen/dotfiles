#### Init
source ~/.zprofile

# Cache zplug plugins in order to improve zsh startup time
export ZPLUG_USE_CACHE=true


#### Aliases
alias szsh="source ~/.zshrc"
alias vzsh="vim ~/.zshrc"


#### ZSH keybindings
bindkey '^ ' autosuggest-accept


#### fzf init
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh && source ~/dotfiles/.fzf_config


#### Plugins
source ~/.zplug/init.zsh

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


#### Load common shell settings
source ~/.shellrc

