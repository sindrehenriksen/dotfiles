#### Install terminal
# if mac; install iterm2
# if wsl: install wsltty

# install gruvbox colorscheme

# if mac; install homebrew

# install symlinks now, to add brew to path
~/dotfiles/install_symlinks.sh
zsh

# install fira code
brew install --cask font-fira-code
# chose fira code in preferences
# enable ligatures

#### Install packages
# if mac
brew install eza
brew install ripgrep
brew install fzf
brew install tldr
# end if

# zplug
brew install zplug

# nodejs
brew install node

brew install mise
mise use --global python@3.13
zsh

brew install pipx

pipx install hatch

pip install virtualenv virtualenvwrapper

brew install 1password-cli

#### Run zsh
zsh

#### Install vim plugins; :PlugInstall
