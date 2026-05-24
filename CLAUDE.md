# Dotfiles Repo

This repo manages shell configs, tool settings, and setup scripts. Key entry points:

- `setup.sh` / `setup-visma.sh` — general and Visma-specific setup (MCP servers, credentials, etc.)
- `install_symlinks.sh` — symlinks managed configs into place
- `~/.secrets.env` / `~/.secrets-visma.env` — untracked secrets (chmod 600, `export KEY=VALUE` format); sourced by shell configs and MCP servers via `--env-file`
- Skills live in `.agents/skills/` (single source), symlinked to both `~/.agents/skills/` and `~/.claude/skills/`

Don't search `~` broadly for settings — check this repo and the paths above.

## Auto-Approved Commands

`~/.claude/settings.json` (symlinked from this repo) defines which Bash commands are auto-approved vs prompted. Only genuinely safe (read-only, test, build) commands belong in the allow list. If the user asks to add a command, verify it's safe before adding — discuss with the user if there's any risk of destructive side effects or system modification. Keep in sync with the VS Code `chat.tools.terminal.autoApprove` list.

## Local-Only Settings

`~/.claude/settings.local.json` holds machine-specific Claude Code config (gitignored via `~/.config/git/ignore`). Current use: `permissions.additionalDirectories` trusts per-machine review-worktree paths (sibling `<repo>-review` dirs) so the pr-review skill can `cd` into them without approval prompts. Paths must be literal and absolute — no globs.
