#### Init
source ~/.zprofile

# Cache zplug plugins in order to improve zsh startup time
export ZPLUG_USE_CACHE=true


#### Aliases
alias szsh="source ~/.zshrc"
alias vzsh="vim ~/.zshrc"


#### vim keybindings
## Use vim editing mode in terminal [escape to enter normal mode]
bindkey -v

# Restore some keymaps removed by vim keybind mode
bindkey '^P' up-history
bindkey '^N' down-history
bindkey '^ ' autosuggest-accept
bindkey '^w' forward-word
bindkey '^?' backward-delete-char
#bindkey '^h' backward-delete-char
#bindkey '^w' backward-kill-word


#### fzf init
#[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh && source ~/dotfiles/.fzf_config
source ~/dotfiles/.fzf_config
source /usr/local/opt/fzf/shell/completion.zsh


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

# Install plugins if there are plugins that have not been installed
if ! zplug check --verbose; then
    printf "Install? [y/N]: "
    if read -q; then
        echo; zplug install
    fi
fi

# Load
zplug load

#### Load common shell settings
source ~/.shellrc


####
# --- ZSH environment variables ---
# Where to save ZSH command history
export HISTFILE="$HOME/.local/share/zsh/history"
mkdir -p $(dirname $HISTFILE) && touch $HISTFILE

# The maximum number of history events to save in the history file (on disk)
export SAVEHIST=1000000

# The maximum number of events stored in the internal history list (in memory)
export HISTSIZE=1000000


#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
