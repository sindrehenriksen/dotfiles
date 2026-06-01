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

# Confluence skill (Copilot agents + Claude Code).
# Source lives in the private work repo (~/dev/flyt) — clone it first.
CONFLUENCE_SKILL=~/dev/flyt/dev-setup/skills/confluence
if [ -d "$CONFLUENCE_SKILL" ]; then
    link "$CONFLUENCE_SKILL" ~/.agents/skills/confluence
    link "$CONFLUENCE_SKILL" ~/.claude/skills/confluence
else
    echo "NOTE: $CONFLUENCE_SKILL not found — clone the work repo, then re-run"
fi
