# Dotfiles Repo

## This repo is PUBLIC

Pushed to a public GitHub repo. Never commit work-internal or employer-confidential content here:

- Internal hostnames/URLs, project or issue keys, internal tool/repo names, infra or resource names, customer data, or descriptions of internal processes/migrations.
- Secrets never go in any repo — use `~/.secrets*.env` (untracked, `chmod 600`).

Work-specific machine setup and agent config live in a **separate private repo** (`~/dev/flyt`). When adding work-related tooling, config, skills, or instructions, put them there — not here. If unsure whether something is publishable, treat it as private and ask.

## Key entry points

- `setup.sh` — general machine setup (work-machine tooling lives in the private work repo)
- `~/.secrets.env` — untracked personal secrets (chmod 600, `export KEY=VALUE` format); sourced by shell configs. Work/Visma secrets live in the private work repo (gitignored), not under `~` — see that repo's setup.

For ephemeral additions (one-off diagnostic scripts, throwaway repros, in-flight experiments): add only the script/config — don't update README or other repo docs until the addition clearly sticks (gained a second caller, survived a few weeks, or asked for explicitly).

## Auto-Approved Commands

`~/.claude/settings.json` (symlinked from this repo) defines which Bash commands are auto-approved vs prompted, so a permission-rule change is a commit here. What belongs in `allow`, `ask` or `deny` is settled in the global instructions under "Permissions and blocked actions" — this file doesn't restate it.

## Local-Only Settings

`~/.claude/settings.local.json` holds machine-specific Claude Code config (gitignored via `~/.config/git/ignore`). Current use: `permissions.additionalDirectories` trusts per-machine review-worktree paths (sibling `<repo>-review` dirs) so PR-review sessions can `cd` into review worktrees without approval prompts. Paths must be literal and absolute — no globs.
