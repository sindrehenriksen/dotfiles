#### Install terminal
# if mac: install iterm2
# if linux: install ghostty (https://ghostty.org/docs/install)

# install symlinks now, to set up configs early
~/dotfiles/install_symlinks.sh
zsh

#### Install font
# if mac
brew install --cask font-fira-code
# if linux (ubuntu)
sudo apt install fonts-firacode
# choose fira code in terminal preferences / ghostty config
# enable ligatures

#### Install packages
# if mac
brew install eza ripgrep fzf tldr
# if linux (ubuntu)
sudo apt install eza ripgrep fzf tldr xclip

#### zplug
# if mac
brew install zplug
# if linux
git clone https://github.com/zplug/zplug ~/.zplug

#### mise
# if mac
brew install mise
# if linux (ubuntu): install build deps for compiling python from source.
# Needed because mise (as of 2026.3.9) defaults to freethreaded prebuilt
# Python builds which fail ("missing lib directory"). Compiling from source
# works. Retest prebuilt after `mise self-update` — may be fixed upstream.
sudo apt install -y build-essential libssl-dev zlib1g-dev libbz2-dev \
    libreadline-dev libsqlite3-dev libncursesw5-dev xz-utils tk-dev \
    libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
curl https://mise.run | sh
mise use --global python@3.13
mise use --global node@lts
zsh

#### pipx & python tools
# if mac
brew install pipx
# if linux
sudo apt install pipx
pipx install hatch
pip install virtualenv virtualenvwrapper

#### 1password-cli (optional)
# if mac
brew install 1password-cli
# if linux: see https://developer.1password.com/docs/cli/get-started/

#### Visma-specific setup (MCP servers, etc.)
# ~/dotfiles/setup-visma.sh

#### Install vim-plug (if not already installed)
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

#### Run zsh
zsh

#### Install vim plugins
# Open vim and run :PlugInstall
