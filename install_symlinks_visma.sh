#!/bin/sh
# Visma-specific symlinks — run after install_symlinks.sh on work machines

link() {
    if [ -e "$2" ] && ! [ -L "$2" ]; then
        echo "WARNING: $2 exists and is not a symlink — skipping"
        return 1
    fi
    ln -sfn "$1" "$2"
}

# Shell config
link ~/dotfiles/.shellrc-visma ~/.shellrc-visma

# Confluence skill (Copilot agents + Claude Code)
link ~/dotfiles/.agents/skills/confluence ~/.agents/skills/confluence
link ~/dotfiles/.agents/skills/confluence ~/.claude/skills/confluence
