#### Install terminal
# if mac; install iterm2
# if wsl: install wsltty

# install gruvbox colorscheme

# if mac; install homebrew

# install fira code
brew tap homebrew/cask-fonts
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
mise use --global python@3.11

# TODO pipx
# TODO: hatch
# TODO pip install virtualenvwrapper

#### Install symlinks
~/dotfiles/install_symlinks.sh

#### Run zsh
zsh

#### Install vim plugins; :PlugInstall
