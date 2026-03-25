ln -sfn ~/dotfiles/.bashrc ~/.bashrc
ln -sfn ~/dotfiles/.gitconfig ~/.gitconfig
ln -sfn ~/dotfiles/.profile ~/.profile
ln -sfn ~/dotfiles/.shellrc ~/.shellrc
ln -sfn ~/dotfiles/.tmux.conf ~/.tmux.conf
ln -sfn ~/dotfiles/.vimrc ~/.vimrc
ln -sfn ~/dotfiles/.zprofile ~/.zprofile
ln -sfn ~/dotfiles/.zshrc ~/.zshrc
mkdir -p ~/.jupyter
ln -sfn ~/dotfiles/.jupyter_notebook_config.py ~/.jupyter/jupyter_notebook_config.py
mkdir -p ~/.agents/skills
ln -sfn ~/dotfiles/.agents/skills/pr-review ~/.agents/skills/pr-review
ln -sfn ~/dotfiles/.agents/skills/pr-description ~/.agents/skills/pr-description
ln -sfn ~/dotfiles/.agents/skills/adding-skills ~/.agents/skills/adding-skills
# Claude Code
ln -sfn ~/dotfiles/.claude/CLAUDE.md ~/.claude/CLAUDE.md
mkdir -p ~/.claude/agents
ln -sfn ~/dotfiles/.claude/agents/pr-review.md ~/.claude/agents/pr-review.md
ln -sfn ~/dotfiles/.claude/agents/pr-description.md ~/.claude/agents/pr-description.md

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: VS Code prompts
    mkdir -p ~/Library/Application\ Support/Code/User/prompts
    ln -sfn ~/dotfiles/copilot-prompts/general.instructions.md ~/Library/Application\ Support/Code/User/prompts/general.instructions.md
    ln -sfn ~/dotfiles/copilot-prompts/git.instructions.md ~/Library/Application\ Support/Code/User/prompts/git.instructions.md

    # macOS: Ghostty config
    mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty
    ln -sfn ~/dotfiles/ghostty/config ~/Library/Application\ Support/com.mitchellh.ghostty/config
else
    # Linux: VS Code prompts
    mkdir -p ~/.config/Code/User/prompts
    ln -sfn ~/dotfiles/copilot-prompts/general.instructions.md ~/.config/Code/User/prompts/general.instructions.md
    ln -sfn ~/dotfiles/copilot-prompts/git.instructions.md ~/.config/Code/User/prompts/git.instructions.md

    # Linux: Ghostty config
    mkdir -p ~/.config/ghostty
    ln -sfn ~/dotfiles/ghostty/config ~/.config/ghostty/config
fi
