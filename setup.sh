#### Install terminal
# if mac; install iterm2
# if wsl: install wsltty

# install gruvbox colorscheme

#### Install packages
# if mac
# Install homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"

brew install git
brew install exa
brew install ripgrep
brew install fzf
brew install tmux
brew install tldr
# end if

# if linux
# Setup zsh
sudo apt install git
sudo apt install exa
sudo apt install ripgrep
sudo apt install fzf
sudo apt install tmux
sudo apt install tldr
# end if

# install pip if not installed
sudo pip3 install -U pip

sudo pip3 install virtualenvwrapper

# zplug
curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh

# nodejs
curl -sL install-node.now.sh/lts | bash

#### Download dotfiles repo
# Generate SSH-key:
# https://docs.github.com/en/github/authenticating-to-github/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent

# if mac (or linux but not wsl?)
pbcopy < ~.ssh/id_rsa_git.pub
# end if

# Prompt to add public key to github

#### Install symlinks
~/dotfiles/install_symlinks.sh

#### Run zsh
zsh

#### Install vim plugins; :PlugInstall
