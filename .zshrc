#### Init
source ~/.zprofile

#### zplug
# Note: ZPLUG_HOME determines where repos are stored. On macOS (Homebrew),
# repos live under /opt/homebrew/opt/zplug/repos/, NOT ~/.zplug/repos/.
if [[ "$(uname)" == "Darwin" ]]; then
    export ZPLUG_HOME=/opt/homebrew/opt/zplug
else
    export ZPLUG_HOME="$HOME/.zplug"
fi
source $ZPLUG_HOME/init.zsh
# Cache zplug plugins in order to improve zsh startup time
export ZPLUG_USE_CACHE=true


#### Aliases
alias szsh="source ~/.zshrc"
alias vzsh="nvim ~/.zshrc"


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
if [[ "$(uname)" == "Darwin" ]]; then
    source /opt/homebrew/opt/fzf/shell/completion.zsh
else
    # fzf keybindings and completion on Linux (apt install)
    [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
    [ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh
fi


#### Plugins

# Fish like autocompletions
zplug "zsh-users/zsh-autosuggestions"

# Highlighting in terminal
zplug "zsh-users/zsh-syntax-highlighting"

# For faster, history based cd'ing using "z" instead
zplug "plugins/z", from:oh-my-zsh

# zsh-async

# Load theme file
zplug "mafredri/zsh-async", from:github, use:async.zsh
zplug sindresorhus/pure, use:pure.zsh, from:github, as:theme

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

# Don't record commands starting with a space
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY

