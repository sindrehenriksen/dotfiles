emulate sh -c '. ~/.profile'

# Run brew shellenv early so fpath includes Homebrew's site-functions (where
# pure and async live) before .zshrc runs compinit and promptinit. Keeping it
# here also means bash picks it up via .shellrc.
# Try Apple Silicon path first, fall back to Intel.
if [[ "$(uname)" == "Darwin" && -z "$HOMEBREW_PREFIX" ]]; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi
