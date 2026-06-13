#### Install terminal (Ghostty on both platforms)
# if mac
brew install --cask ghostty
# if linux: https://ghostty.org/docs/install

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

#### Hammerspoon (macOS window manager — replaces Divvy)
# if mac
brew install --cask hammerspoon
# After install: launch Hammerspoon.app, grant accessibility access
# (System Settings > Privacy & Security > Accessibility), and in Hammerspoon
# preferences enable "Launch at login" + "Automatically reload config when
# any files change". Config is symlinked via install_symlinks.sh.

#### macOS keyboard tweaks
# Caps Lock <-> Escape swap (built-in, persistent, per-keyboard):
# System Settings > Keyboard > Keyboard Shortcuts... > Modifier Keys.
# Pick the keyboard from the dropdown, then set Caps Lock Key -> Escape
# and Escape Key -> Caps Lock. Repeat for each connected keyboard.
#
# Free up Ctrl+Space (used by other tools — e.g. autosuggest-accept in zsh):
# System Settings > Keyboard > Keyboard Shortcuts... > Input Sources.
# Uncheck "Select the previous input source". Ctrl+Option+Space still
# cycles via "Select next source in Input menu".
#
# Programmer Dvorak (Roland Kaufmann's layout — not built into macOS):
#   cd /tmp
#   curl -fsSLO https://www.kaufmann.no/downloads/macos/ProgrammerDvorak-1_2_13.pkg.zip
#   unzip ProgrammerDvorak-1_2_13.pkg.zip
#   mkdir -p ~/payload && cd ~/payload
#   pax -rz -f "/tmp/Programmer Dvorak v1.2.pkg/Contents/Archive.pax.gz"
#   mkdir -p ~/Library/Keyboard\ Layouts
#   cp -R "Library/Keyboard Layouts/Programmer Dvorak.bundle" ~/Library/Keyboard\ Layouts/
#   cd ~ && rm -rf ~/payload /tmp/Programmer\ Dvorak* /tmp/ProgrammerDvorak*
# Then enable: System Settings > Keyboard > Text Input > Input Sources >
# Edit... > + > Others > Programmer Dvorak. Log out + log in if the layout
# doesn't show up immediately.

#### 1password-cli (optional)
# if mac
brew install 1password-cli
# if linux: see https://developer.1password.com/docs/cli/get-started/

#### Secrets
# Personal secrets (currently empty template):
cp ~/dotfiles/secrets/secrets.env.example ~/.secrets.env
chmod 600 ~/.secrets.env
# edit ~/.secrets.env
# For work-machine setup, see the private work repo (dev-setup/)

#### Browser automation (agent-browser)
# if mac
brew install agent-browser
# if linux
npm install -g agent-browser
# both: install browser binary
agent-browser install

#### CodeRabbit CLI (free tier, AI code review)
# if mac (it's a cask — auto-resolves but --cask is explicit)
brew install --cask coderabbit
# if linux
curl -fsSL https://cli.coderabbit.ai/install.sh | sh
# both: one-time browser auth (free tier, daily rate limits)
cr auth login

#### Claude Code
# Use the official installer, not `brew install --cask claude-code`: the cask
# lags and may NOT carry the latest, which gates access to newer models. The
# official installer auto-updates and tracks latest.
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

#### MCP servers (shared / non-org-specific)
# Playwright (browser automation) — kept alongside agent-browser for now

# Claude Code (user-scoped — available in all projects)
claude mcp add -s user playwright -- npx @playwright/mcp@latest

#### Claude Code per-machine settings (~/.claude/settings.local.json, gitignored)
# Add this machine's resolved $TMPDIR to permissions.additionalDirectories so
# coding agents can read/write there without prompts (pairs with shared /tmp
# and /private/tmp entries in the tracked settings.json). Example:
#   echo "$TMPDIR" | sed 's:/$::'
# then add the result to the additionalDirectories array.

# VS Code / GitHub Copilot: add to mcp.json (settings gear > MCP Servers, or directly):
#   macOS: ~/Library/Application Support/Code/User/mcp.json
#   Linux: ~/.config/Code/User/mcp.json
#   Add: "playwright": { "type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"] }

# GitHub Copilot CLI: add to ~/.copilot/mcp-config.json (or /mcp add interactively)

# OpenAI Codex CLI:
#   codex mcp add playwright -- npx @playwright/mcp@latest

#### Work-specific setup (MCP servers, etc.)
# Lives in the private work repo: ~/dev/flyt/dev-setup/

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
