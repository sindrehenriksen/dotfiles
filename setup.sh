#### Install terminal
# if mac: install iterm2
# if linux: install ghostty (https://ghostty.org/docs/install)

# Set zsh as default shell
sudo chsh -s $(which zsh) $USER

# install symlinks now, to set up configs early
~/dotfiles/install_symlinks.sh

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

#### Secrets
# Personal secrets (currently empty template):
cp ~/dotfiles/secrets/secrets.env.example ~/.secrets.env
chmod 600 ~/.secrets.env
# edit ~/.secrets.env
# For Visma setup, see setup-visma.sh

#### Browser automation (agent-browser)
# if mac
brew install agent-browser
# if linux
npm install -g agent-browser
# both: install browser binary
agent-browser install

#### MCP servers (shared / non-org-specific)
# Playwright (browser automation) — kept alongside agent-browser for now

# Claude Code (user-scoped — available in all projects)
claude mcp add -s user playwright -- npx @playwright/mcp@latest

#### Claude Code preferences (per-machine, stored in ~/.claude.json)
# Enable vim keybindings in the input prompt: run /config in a Claude Code
# session and set "Editor mode" to Vim. Not persistable via settings.json.

# VS Code / GitHub Copilot: add to mcp.json (settings gear > MCP Servers, or directly):
#   macOS: ~/Library/Application Support/Code/User/mcp.json
#   Linux: ~/.config/Code/User/mcp.json
#   Add: "playwright": { "type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"] }

# GitHub Copilot CLI: add to ~/.copilot/mcp-config.json (or /mcp add interactively)

# OpenAI Codex CLI:
#   codex mcp add playwright -- npx @playwright/mcp@latest

#### Visma-specific setup (MCP servers, etc.)
# ~/dotfiles/setup-visma.sh

#### Install vim-plug (if not already installed)
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

#### Run zsh
zsh

#### Install vim plugins
# Open vim and run :PlugInstall

#### Linux system setup (if linux)
# See system/ for configs and scripts. General steps:
~/dotfiles/system/gnome-keybindings.sh
# Lenovo-specific (battery conservation, keyboard resume fix, power button):
# See system/README.md for install instructions
