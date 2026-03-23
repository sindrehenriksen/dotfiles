ln -is ~/dotfiles/.bashrc ~/.bashrc
ln -is ~/dotfiles/.gitconfig ~/.gitconfig
ln -is ~/dotfiles/.profile ~/.profile
ln -is ~/dotfiles/.shellrc ~/.shellrc
ln -is ~/dotfiles/.tmux.conf ~/.tmux.conf
ln -is ~/dotfiles/.vimrc ~/.vimrc
ln -is ~/dotfiles/.zprofile ~/.zprofile
ln -is ~/dotfiles/.zshrc ~/.zshrc
mkdir -p ~/.jupyter
ln -is ~/dotfiles/.jupyter_notebook_config.py ~/.jupyter/jupyter_notebook_config.py
mkdir -p ~/.agents/skills
ln -is ~/dotfiles/.agents/skills/pr-review ~/.agents/skills/pr-review
ln -is ~/dotfiles/.agents/skills/pr-description ~/.agents/skills/pr-description
ln -is ~/dotfiles/.agents/skills/adding-skills ~/.agents/skills/adding-skills
# Claude Code
ln -is ~/dotfiles/.claude/CLAUDE.md ~/.claude/CLAUDE.md
mkdir -p ~/.claude/agents
ln -is ~/dotfiles/.claude/agents/pr-review.md ~/.claude/agents/pr-review.md
ln -is ~/dotfiles/.claude/agents/pr-description.md ~/.claude/agents/pr-description.md

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: VS Code prompts
    mkdir -p ~/Library/Application\ Support/Code/User/prompts
    ln -is ~/dotfiles/copilot-prompts/general.instructions.md ~/Library/Application\ Support/Code/User/prompts/general.instructions.md
    ln -is ~/dotfiles/copilot-prompts/git.instructions.md ~/Library/Application\ Support/Code/User/prompts/git.instructions.md
else
    # Linux: VS Code prompts
    mkdir -p ~/.config/Code/User/prompts
    ln -is ~/dotfiles/copilot-prompts/general.instructions.md ~/.config/Code/User/prompts/general.instructions.md
    ln -is ~/dotfiles/copilot-prompts/git.instructions.md ~/.config/Code/User/prompts/git.instructions.md

    # Linux: Ghostty config
    mkdir -p ~/.config/ghostty
    ln -is ~/dotfiles/ghostty/config ~/.config/ghostty/config
fi
