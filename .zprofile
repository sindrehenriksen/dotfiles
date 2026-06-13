emulate sh -c '. ~/.profile'

# Run brew shellenv early so fpath is set before compinit (triggered by zplug
# load in .zshrc). Keeping it here also means bash picks it up via .shellrc.
# Try Apple Silicon path first, fall back to Intel.
if [[ "$(uname)" == "Darwin" && -z "$HOMEBREW_PREFIX" ]]; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi
