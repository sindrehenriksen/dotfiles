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

# Work skills (Copilot agents + Claude Code). Sources live in the private work
# repo (~/dev/flyt) — clone it first. Linked to user level because skills are
# discovered from cwd only, so workspace-level ones are invisible to sessions
# started inside a repo.
link_work_skill() {
    if [ -d "$1" ]; then
        link "$1" ~/.agents/skills/"$2"
        link "$1" ~/.claude/skills/"$2"
    else
        echo "NOTE: $1 not found — clone the work repo, then re-run"
    fi
}

link_work_skill ~/dev/flyt/dev-setup/skills/confluence confluence
link_work_skill ~/dev/flyt/.claude/skills/pr-review pr-review
link_work_skill ~/dev/flyt/.claude/skills/jira-visma jira-visma
link_work_skill ~/dev/flyt/.claude/skills/flyt-handoff flyt-handoff
