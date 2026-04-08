---
name: sync
description: 'Sync dotfiles repo from origin and apply changes locally. USE FOR: pull, sync, update dotfiles, apply latest changes. DO NOT USE FOR: pushing changes, committing.'
allowed-tools: Read, Grep, Glob, Bash
---

<!-- Repo-specific skill — not symlinked globally. Available via .claude/skills/ in the dotfiles repo. -->

# Sync Dotfiles

Pull latest from origin and apply locally.

## Pull

1. `git fetch origin` and check `git status`
2. **Clean + fast-forwardable**: `git pull`
3. **Uncommitted changes**: `git stash`, pull, report stash
4. **Diverged**: show what differs on both sides (`git log --oneline HEAD..origin/main` and `origin/main..HEAD`). Reset to origin if incoming changes are reasonable and local commits are trivial; otherwise ask the user.

## Apply

Review the pulled diff and apply what's needed:

- **Symlinks**: `source ~/dotfiles/install_symlinks.sh`. If a target exists as a regular file, compare — back up and replace if repo version is a superset, otherwise report.
- **Setup scripts** (`setup.sh`, `setup-visma.sh`): identify and run only affected sections, or flag for the user. Don't re-run blindly.
- **Shell configs**: nudge user to reload shell or source the changed file.
- **Tool configs** (nvim plugins, tmux, ghostty, etc.): note if restart/reload/install is needed.
- **Quick wins**: if something is easy to verify (alias, keybinding, setting), test it or prompt the user to.

## Finish

Summarize: commits pulled, what was applied, anything stashed/skipped, manual steps remaining.
