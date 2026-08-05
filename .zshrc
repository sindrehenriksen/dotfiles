#### Init
source ~/.zprofile


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
    source "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/fzf/shell/key-bindings.zsh"
    source "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/fzf/shell/completion.zsh"
else
    # fzf keybindings and completion on Linux (apt install)
    [ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
    [ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh
fi


#### Plugins
# No plugin manager. Plugins come from the system package manager (brew on
# macOS, apt on Ubuntu) or, where they aren't packaged, from git clones in
# $ZSH_PLUGIN_DIR. See the plugin section of setup.sh for install commands.
export ZSH_PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins"

# Source the first candidate that exists, so a machine missing a plugin gets a
# working shell instead of an error on every prompt.
__source_first() {
    local candidate
    for candidate in "$@"; do
        [[ -r $candidate ]] || continue
        source "$candidate"
        return 0
    done
    return 1
}

# pure and its zsh-async dependency are autoloaded off fpath. Homebrew's
# site-functions dir is already there via brew shellenv (.zprofile); the clone
# path covers Linux, where pure isn't packaged (its repo vendors async too).
fpath=("$ZSH_PLUGIN_DIR"/pure $fpath)

autoload -Uz compinit
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
compinit -d "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"

autoload -Uz promptinit && promptinit
prompt pure

# Fish-like autosuggestions
__source_first \
    "${HOMEBREW_PREFIX:-/opt/homebrew}/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# History-based cd'ing with `z` (replaces oh-my-zsh's z plugin)
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"

# Must come last: syntax highlighting wraps every ZLE widget defined before it.
__source_first \
    "${HOMEBREW_PREFIX:-/opt/homebrew}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

unset -f __source_first


#### Plugin updates
# Packaged plugins update with `brew upgrade` / `apt upgrade`. Only the clones
# need pulling, so this is a no-op on macOS.
zsh-plugins-update() {
    local repo
    for repo in "$ZSH_PLUGIN_DIR"/*(N/); do
        [[ -d $repo/.git ]] || continue
        printf '%-16s' "${repo:t}"
        if git -C "$repo" pull --ff-only --quiet; then print ok; else print FAILED; fi
    done
    [[ -d $ZSH_PLUGIN_DIR ]] && touch "$ZSH_PLUGIN_DIR/.last-update"
}

# Weekly, detached, silent — a pull only takes effect in the next shell anyway.
# Set ZSH_PLUGINS_NO_AUTOUPDATE=1 to opt out.
__zsh_plugins_autoupdate() {
    [[ -n $ZSH_PLUGINS_NO_AUTOUPDATE || ! -d $ZSH_PLUGIN_DIR ]] && return
    local -a fresh=("$ZSH_PLUGIN_DIR"/.last-update(Nm-7))
    (( $#fresh )) && return
    ( zsh-plugins-update >| "$ZSH_PLUGIN_DIR/.update.log" 2>&1 ) &!
}
__zsh_plugins_autoupdate
unset -f __zsh_plugins_autoupdate

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

