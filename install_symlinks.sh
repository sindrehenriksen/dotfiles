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
link ~/dotfiles/.agents/skills/browser ~/.agents/skills/browser
link ~/dotfiles/.agents/skills/pr-review ~/.agents/skills/pr-review
link ~/dotfiles/.agents/skills/pr-description ~/.agents/skills/pr-description
link ~/dotfiles/.agents/skills/browser ~/.claude/skills/browser
link ~/dotfiles/.agents/skills/pr-review ~/.claude/skills/pr-review
link ~/dotfiles/.agents/skills/pr-description ~/.claude/skills/pr-description
# Repo-specific skills (not global)
mkdir -p ~/dotfiles/.claude/skills
link ~/dotfiles/.agents/skills/sync ~/dotfiles/.claude/skills/sync
link ~/dotfiles/.agents/skills/adding-skills ~/dotfiles/.claude/skills/adding-skills
# Git hooks (repo-local)
git -C ~/dotfiles config core.hooksPath git-hooks
# Claude Code
link ~/dotfiles/.claude/CLAUDE.md ~/.claude/CLAUDE.md
link ~/dotfiles/.claude/settings.json ~/.claude/settings.json
# Claude Code work-account config dir (shared config symlinked from personal)
mkdir -p ~/.claude-work
link ~/dotfiles/.claude/CLAUDE.md ~/.claude-work/CLAUDE.md
link ~/dotfiles/.claude/settings.json ~/.claude-work/settings.json
link ~/.claude/keybindings.json ~/.claude-work/keybindings.json
link ~/.claude/skills ~/.claude-work/skills
link ~/.claude/plugins ~/.claude-work/plugins

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: VS Code prompts
    mkdir -p ~/Library/Application\ Support/Code/User/prompts
    link ~/dotfiles/copilot-prompts/general.instructions.md ~/Library/Application\ Support/Code/User/prompts/general.instructions.md
    link ~/dotfiles/copilot-prompts/git.instructions.md ~/Library/Application\ Support/Code/User/prompts/git.instructions.md

    # macOS: Ghostty config
    mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty
    link ~/dotfiles/ghostty/config ~/Library/Application\ Support/com.mitchellh.ghostty/config

    # macOS: Hammerspoon config
    mkdir -p ~/.hammerspoon
    link ~/dotfiles/hammerspoon/init.lua ~/.hammerspoon/init.lua
else
    # Linux: VS Code prompts
    mkdir -p ~/.config/Code/User/prompts
    link ~/dotfiles/copilot-prompts/general.instructions.md ~/.config/Code/User/prompts/general.instructions.md
    link ~/dotfiles/copilot-prompts/git.instructions.md ~/.config/Code/User/prompts/git.instructions.md

    # Linux: Ghostty config
    mkdir -p ~/.config/ghostty
    link ~/dotfiles/ghostty/config ~/.config/ghostty/config
fi
