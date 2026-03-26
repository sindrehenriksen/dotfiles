#!/bin/sh
# Visma-specific symlinks — run after install_symlinks.sh on work machines

# Shell config
ln -sfn ~/dotfiles/.shellrc-visma ~/.shellrc-visma

# Confluence skill (Copilot agents + Claude Code)
ln -sfn ~/dotfiles/.agents/skills/confluence ~/.agents/skills/confluence
ln -sfn ~/dotfiles/.claude/agents/confluence.md ~/.claude/agents/confluence.md
