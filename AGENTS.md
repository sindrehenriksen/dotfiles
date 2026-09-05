# Dotfiles Repo

Rules for working *in* this repo. The user-level instructions that apply in every project are also kept here, in `agents/AGENTS.md` (symlinked to `~/.agents/AGENTS.md`, `~/.claude/CLAUDE.md` and `~/.claude-work/CLAUDE.md`), and load alongside this file. Anything general belongs there; this file carries only what is specific to the repo.

## This repo is PUBLIC

Pushed to a public GitHub repo. Never commit work-internal or employer-confidential content here:

- Internal hostnames/URLs, project or issue keys, internal tool/repo names, infra or resource names, customer data, or descriptions of internal processes/migrations.
- Secrets never go in any repo — use `~/.secrets*.env` (untracked, `chmod 600`).

Anything tied to an employer, a client, or an internal project — machine setup, tooling, config, skills, agent instructions — stays out of this repo entirely. If unsure whether something is publishable, treat it as private and ask.

## Key entry points

- `setup.sh` — general machine setup; nothing work-specific
- `~/.secrets.env` — untracked personal secrets (chmod 600, `export KEY=VALUE` format); sourced by shell configs. Work secrets are kept outside this repo and outside `~`.
- `~/.shellrc.early` and `~/.gitconfig.local` — untracked hooks the shell and git configs pull in if present. Machine-local setup goes there rather than in a tracked file.

## Dotted means local, undotted means installed

A dotted directory holds config for working *in* this repo; an undotted one holds payload `install_symlinks.sh` places under `~`. So `agents/` and `claude/` are the source for `~/.agents/`, `~/.claude/` and `~/.claude-work/`, while `.claude/` carries only what Claude Code should read with cwd here — `settings.local.json` and the repo-local skills linked into `.claude/skills/`. Keeping the payload undotted is what stops a session started here loading the same user-level settings a second time as project settings.

## macOS and Linux stay in step

The keyboard and window setups exist twice — `hammerspoon/` and `macos/` on one side, the Linux input remapper and GNOME extension on the other. `docs/keyboard.md` and `docs/window-layout.md` hold the shared model both implementations serve; read them before changing either.

A change to one side should be mirrored on the other. Where it should not be, say why in `docs/keyboard.md` under "Parity" rather than leaving the two to drift silently.

## Auto-Approved Commands

`~/.claude/settings.json` (symlinked from this repo) defines which Bash commands are auto-approved vs prompted, so a permission-rule change is a commit here. What belongs in `allow`, `ask` or `deny` is settled in the global instructions under "Permissions and blocked actions" — this file doesn't restate it.
