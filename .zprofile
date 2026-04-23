emulate sh -c '. ~/.profile'

# Run brew shellenv early so fpath is set before compinit (triggered by zplug
# load in .zshrc). Keeping it here also means bash picks it up via .shellrc.
if [[ "$(uname)" == "Darwin" && -x /opt/homebrew/bin/brew && -z "$HOMEBREW_PREFIX" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
