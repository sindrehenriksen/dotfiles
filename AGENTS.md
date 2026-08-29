# Dotfiles Repo

Rules for working *in* this repo. The user-level instructions that apply in every project are also kept here, in `.agents/AGENTS.md` (symlinked to `~/.agents/AGENTS.md`, `~/.claude/CLAUDE.md` and `~/.claude-work/CLAUDE.md`), and load alongside this file. Anything general belongs there; this file carries only what is specific to the repo.

## This repo is PUBLIC

Pushed to a public GitHub repo. Never commit work-internal or employer-confidential content here:

- Internal hostnames/URLs, project or issue keys, internal tool/repo names, infra or resource names, customer data, or descriptions of internal processes/migrations.
- Secrets never go in any repo — use `~/.secrets*.env` (untracked, `chmod 600`).

Work-specific machine setup and agent config live in a **separate private repo**. When adding work-related tooling, config, skills, or instructions, put them there — not here. If unsure whether something is publishable, treat it as private and ask.

## Key entry points

- `setup.sh` — general machine setup (work-machine tooling lives in the private work repo)
- `~/.secrets.env` — untracked personal secrets (chmod 600, `export KEY=VALUE` format); sourced by shell configs. Work secrets live in the private work repo (gitignored), not under `~` — see that repo's setup.

## Auto-Approved Commands

`~/.claude/settings.json` (symlinked from this repo) defines which Bash commands are auto-approved vs prompted, so a permission-rule change is a commit here. What belongs in `allow`, `ask` or `deny` is settled in the global instructions under "Permissions and blocked actions" — this file doesn't restate it.
