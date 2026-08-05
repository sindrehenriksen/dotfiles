link() {
    if [ -e "$2" ] && ! [ -L "$2" ]; then
        echo "WARNING: $2 exists and is not a symlink — skipping"
        return 1
    fi
    ln -sfn "$1" "$2"
}

link ~/dotfiles/.bashrc ~/.bashrc
link ~/dotfiles/.gitconfig ~/.gitconfig
link ~/dotfiles/.profile ~/.profile
link ~/dotfiles/.shellrc ~/.shellrc
mkdir -p ~/.config
link ~/dotfiles/nvim ~/.config/nvim
link ~/dotfiles/.zprofile ~/.zprofile
link ~/dotfiles/.zshrc ~/.zshrc
mkdir -p ~/.jupyter
link ~/dotfiles/.jupyter_notebook_config.py ~/.jupyter/jupyter_notebook_config.py
mkdir -p ~/.agents/skills ~/.claude/skills
link ~/dotfiles/.agents/skills/orchestration ~/.agents/skills/orchestration
link ~/dotfiles/.agents/skills/browser ~/.agents/skills/browser
link ~/dotfiles/.agents/skills/coderabbit ~/.agents/skills/coderabbit
link ~/dotfiles/.agents/skills/pr-description ~/.agents/skills/pr-description
link ~/dotfiles/.agents/skills/ci-debugging ~/.agents/skills/ci-debugging
link ~/dotfiles/.agents/skills/orchestration ~/.claude/skills/orchestration
link ~/dotfiles/.agents/skills/browser ~/.claude/skills/browser
link ~/dotfiles/.agents/skills/coderabbit ~/.claude/skills/coderabbit
link ~/dotfiles/.agents/skills/pr-description ~/.claude/skills/pr-description
link ~/dotfiles/.agents/skills/ci-debugging ~/.claude/skills/ci-debugging
# Repo-specific skills (not global)
mkdir -p ~/dotfiles/.claude/skills
link ~/dotfiles/.agents/skills/sync ~/dotfiles/.claude/skills/sync
# Git hooks (repo-local)
git -C ~/dotfiles config core.hooksPath git-hooks
# Claude Code
link ~/dotfiles/.claude/CLAUDE.md ~/.claude/CLAUDE.md
link ~/dotfiles/.claude/settings.json ~/.claude/settings.json
link ~/dotfiles/.claude/statusline.sh ~/.claude/statusline.sh
# Claude Code work-account config dir (shared config symlinked from personal)
mkdir -p ~/.claude-work
link ~/dotfiles/.claude/CLAUDE.md ~/.claude-work/CLAUDE.md
link ~/dotfiles/.claude/settings.json ~/.claude-work/settings.json
link ~/.claude/keybindings.json ~/.claude-work/keybindings.json
link ~/.claude/skills ~/.claude-work/skills
link ~/.claude/plugins ~/.claude-work/plugins

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Ghostty config
    mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty
    link ~/dotfiles/ghostty/config ~/Library/Application\ Support/com.mitchellh.ghostty/config

    # macOS: Hammerspoon config
    mkdir -p ~/.hammerspoon
    link ~/dotfiles/hammerspoon/init.lua ~/.hammerspoon/init.lua
else
    # Linux: Ghostty config
    mkdir -p ~/.config/ghostty
    link ~/dotfiles/ghostty/config ~/.config/ghostty/config
fi
