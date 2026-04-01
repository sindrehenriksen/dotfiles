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
link ~/dotfiles/.tmux.conf ~/.tmux.conf
mkdir -p ~/.config
link ~/dotfiles/nvim ~/.config/nvim
link ~/dotfiles/.zprofile ~/.zprofile
link ~/dotfiles/.zshrc ~/.zshrc
mkdir -p ~/.jupyter
link ~/dotfiles/.jupyter_notebook_config.py ~/.jupyter/jupyter_notebook_config.py
mkdir -p ~/.agents/skills ~/.claude/skills
link ~/dotfiles/.agents/skills/pr-review ~/.agents/skills/pr-review
link ~/dotfiles/.agents/skills/pr-description ~/.agents/skills/pr-description
link ~/dotfiles/.agents/skills/adding-skills ~/.agents/skills/adding-skills
link ~/dotfiles/.agents/skills/pr-review ~/.claude/skills/pr-review
link ~/dotfiles/.agents/skills/pr-description ~/.claude/skills/pr-description
link ~/dotfiles/.agents/skills/adding-skills ~/.claude/skills/adding-skills
# Claude Code
link ~/dotfiles/.claude/CLAUDE.md ~/.claude/CLAUDE.md

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: VS Code prompts
    mkdir -p ~/Library/Application\ Support/Code/User/prompts
    link ~/dotfiles/copilot-prompts/general.instructions.md ~/Library/Application\ Support/Code/User/prompts/general.instructions.md
    link ~/dotfiles/copilot-prompts/git.instructions.md ~/Library/Application\ Support/Code/User/prompts/git.instructions.md

    # macOS: Ghostty config
    mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty
    link ~/dotfiles/ghostty/config ~/Library/Application\ Support/com.mitchellh.ghostty/config
else
    # Linux: VS Code prompts
    mkdir -p ~/.config/Code/User/prompts
    link ~/dotfiles/copilot-prompts/general.instructions.md ~/.config/Code/User/prompts/general.instructions.md
    link ~/dotfiles/copilot-prompts/git.instructions.md ~/.config/Code/User/prompts/git.instructions.md

    # Linux: Ghostty config
    mkdir -p ~/.config/ghostty
    link ~/dotfiles/ghostty/config ~/.config/ghostty/config
fi
