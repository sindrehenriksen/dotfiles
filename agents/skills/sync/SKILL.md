---
name: sync
description: 'Sync dotfiles repo from origin and apply changes locally. USE FOR: pull, sync, update dotfiles, apply latest changes. DO NOT USE FOR: pushing changes, committing.'
allowed-tools: Read, Grep, Glob, Bash
---

<!-- Repo-specific skill — not symlinked globally. Available via .claude/skills/ in the dotfiles repo. -->

# Sync Dotfiles

Pull latest from origin and apply locally.

## Upstream check

Before pulling, and for every checkout the sync covers (this repo's main checkout here; a layer skill can add its own), say where it stands against its upstream:

1. `git -C <checkout> fetch --all --prune`.
2. **New upstream:** `git -C <checkout> log --oneline HEAD..@{u}`.
3. **Local and unpushed:** `git -C <checkout> log --oneline @{u}..HEAD`, plus uncommitted changes from `git -C <checkout> status --short`, and the branch it is on when that is not the one it should be parked on.

Report each in a line: up to date, N new upstream, N local and unpushed, dirty, or diverged. A fetch that fails (no network, an expired credential) is said as such, never read as "up to date".

## Pull

From the upstream check's state of each checkout:

1. **Clean + fast-forwardable**: `git -C <checkout> pull --ff-only`
2. **Uncommitted changes**: `git -C <checkout> stash`, pull, report the stash
3. **Diverged**: show what differs on both sides (`git -C <checkout> log --oneline HEAD..@{u}` and `@{u}..HEAD`). Reset to the upstream if incoming changes are reasonable and local commits are trivial; otherwise ask the user.

## Apply

Review the pulled diff and apply what's needed:

- **Symlinks**: `source ~/dotfiles/install_symlinks.sh`. If a target exists as a regular file, compare — back up and replace if repo version is a superset, otherwise report. The script only adds links, so a rename or removal upstream leaves a dangling one: after a pull that renamed anything, check `find ~/.claude/skills ~/.claude-work/skills ~/.agents/skills -maxdepth 1 -xtype l` and remove only those whose source the pull deleted, leaving links that point outside dotfiles alone.
- **Setup scripts** (`setup.sh`): identify and run only affected sections, or flag for the user. Don't re-run blindly.
- **Shell configs**: nudge user to reload shell or source the changed file.
- **Tool configs** (nvim plugins, ghostty, etc.): note if restart/reload/install is needed.
- **Quick wins**: if something is easy to verify (alias, keybinding, setting), test it or prompt the user to.

## Run unattended

From a scheduled or briefed pass, with nobody at the keyboard, the sync does three things and nothing else: the upstream check, the pull of a checkout that is clean and fast-forwards (case 1), and the read-only half of Apply, which looks and changes nothing (a dangling-link `find`, whether a changed file needs a reload or an install). Every other case of Pull, and everything in Apply that changes something (sourcing the installer, replacing or removing a file or link, running `setup.sh`, an install), is left as it is and reported for the user to decide, with what it would take: no stash, no reset, no rebase, no fix.

## Finish

Summarize: the upstream check per checkout, commits pulled, what was applied, anything stashed/skipped (and, run unattended, every checkout left unpulled and why), manual steps remaining.
