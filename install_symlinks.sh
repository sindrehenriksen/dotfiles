#!/usr/bin/env bash
# Needs bash, not sh: the platform check below uses [[ ]], which dash errors on —
# silently taking the Linux branch on macOS.

link() {
    if [ ! -e "$1" ]; then
        echo "WARNING: $1 does not exist — skipping, rather than linking to nothing"
        return 1
    fi
    if [ -e "$2" ] && ! [ -L "$2" ]; then
        echo "WARNING: $2 exists and is not a symlink — skipping"
        return 1
    fi
    ln -sfn "$1" "$2"
}

# Skills every account gets. Anything more specific belongs to the repo that
# owns it, linked by that repo's own installer into the one account it serves —
# see docs/overlays.md for why each account needs its own skills DIRECTORY.
generic_skills=(execution browser coderabbit pr-description ci-debugging handoff team)

link ~/dotfiles/.bashrc ~/.bashrc
link ~/dotfiles/.gitconfig ~/.gitconfig
link ~/dotfiles/.profile ~/.profile
link ~/dotfiles/.shellrc ~/.shellrc
mkdir -p ~/.config
link ~/dotfiles/nvim ~/.config/nvim
link ~/dotfiles/.zprofile ~/.zprofile
link ~/dotfiles/.zshrc ~/.zshrc
mkdir -p ~/.agents/skills ~/.claude/skills
link ~/dotfiles/.agents/principles.md ~/.agents/principles.md
link ~/dotfiles/.agents/AGENTS.md ~/.agents/AGENTS.md
for skill in "${generic_skills[@]}"; do
    link ~/dotfiles/.agents/skills/"$skill" ~/.agents/skills/"$skill"
    link ~/dotfiles/.agents/skills/"$skill" ~/.claude/skills/"$skill"
done
# Repo-specific skills (not global)
mkdir -p ~/dotfiles/.claude/skills
link ~/dotfiles/.agents/skills/sync ~/dotfiles/.claude/skills/sync
# Git hooks (repo-local)
git -C ~/dotfiles config core.hooksPath git-hooks
# Claude Code
link ~/dotfiles/.agents/AGENTS.md ~/.claude/CLAUDE.md
link ~/dotfiles/.claude/settings.json ~/.claude/settings.json
link ~/dotfiles/.claude/statusline.sh ~/.claude/statusline.sh
link ~/dotfiles/.claude/keybindings.json ~/.claude/keybindings.json
# Claude Code work-account config dir (shared config symlinked from personal)
mkdir -p ~/.claude-work
link ~/dotfiles/.agents/AGENTS.md ~/.claude-work/CLAUDE.md
link ~/dotfiles/.claude/settings.json ~/.claude-work/settings.json
link ~/dotfiles/.claude/keybindings.json ~/.claude-work/keybindings.json
link ~/.claude/plugins ~/.claude-work/plugins
# Skills are the exception: each account owns its directory, so an overlay
# repo's skills reach the one account it belongs to and no other. This used to
# be one symlink to the personal directory, which promoted every overlay's
# skills to both accounts — migrate it, since ln would only follow it.
[ -L ~/.claude-work/skills ] && rm ~/.claude-work/skills
mkdir -p ~/.claude-work/skills
for skill in "${generic_skills[@]}"; do
    link ~/dotfiles/.agents/skills/"$skill" ~/.claude-work/skills/"$skill"
done

if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: Ghostty config
    mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty
    link ~/dotfiles/ghostty/config ~/Library/Application\ Support/com.mitchellh.ghostty/config

    # macOS: Hammerspoon config
    mkdir -p ~/.hammerspoon
    link ~/dotfiles/hammerspoon/init.lua ~/.hammerspoon/init.lua

    # macOS: keyboard remapping at login — see macos/README.md
    mkdir -p ~/Library/LaunchAgents
    link ~/dotfiles/macos/com.local.KeyRemapping.plist \
         ~/Library/LaunchAgents/com.local.KeyRemapping.plist
else
    # Linux: Ghostty config
    mkdir -p ~/.config/ghostty
    link ~/dotfiles/ghostty/config ~/.config/ghostty/config

    # Linux: systemd user manager — keeps an OOM-killed process from taking its
    # whole Ghostty tab with it. See system/README.md.
    mkdir -p ~/.config/systemd
    link ~/dotfiles/system/systemd-user.conf ~/.config/systemd/user.conf
fi
