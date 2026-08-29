# dotfiles

Personal dev environment: zsh, Neovim, Ghostty, Git, AI agent configs. Cross-platform (macOS + Ubuntu).

## Layout

| Path | What |
|---|---|
| `.zshrc`, `.zprofile`, `.bashrc`, `.profile`, `.shellrc` | Shell init; `.shellrc` is sourced by both bash and zsh |
| `.gitconfig`, `.gitlint` | Git config and commit linting |
| `.fzf_config` | fzf defaults (rg-backed file list) |
| `nvim/` | Neovim Lua config (lazy.nvim, native LSP, blink.cmp, telescope, gitsigns, diffview, gruvbox.nvim) |
| `ghostty/config` | Ghostty terminal config (Fira Code, Gruvbox Dark Hard, split nav on Dvorak home row) |
| `hammerspoon/init.lua` | macOS window layout (picker on `Opt+Cmd+T`, three-column + one-off placement) — see `docs/window-layout.md` |
| `.claude/` | Claude Code global config (`CLAUDE.md`, `settings.json`) |
| `.agents/skills/` | Agent skills — single source, symlinked to `~/.agents/skills/` and `~/.claude/skills/` (global) plus `~/dotfiles/.claude/skills/` for repo-only skills |
| `secrets/` | Example secrets templates (real secrets live in `~/.secrets.env`, untracked) |
| `macos/` | macOS-only: keyboard remapping (Caps Lock, fn/Ctrl swap) via `hidutil` and a login agent — see `macos/README.md` |
| `system/` | Linux-only: GNOME keybinds, logind, battery conservation, systemd user-manager OOM policy — see `system/README.md` |
| `git-hooks/` | Repo-local git hooks (`core.hooksPath`): `commit-msg` enforces 50/72 title + reflows body at 72, `pre-commit` delegates to the `pre-commit` framework if installed |

## Setup

On a fresh machine:

1. Run `setup.sh` step-by-step (it's a checklist, not a script — different steps for macOS vs Ubuntu).
2. Run `install_symlinks.sh` to place the symlinks.
3. Work machines need additional setup, which is kept out of this repo.
4. Copy `secrets/secrets.env.example` to `~/.secrets.env`, edit, `chmod 600`.
5. Open nvim — lazy.nvim bootstraps itself and installs plugins. `:Mason` to install LSP servers.

## Platform notes

- **macOS:** Homebrew for packages, including all zsh plugins (`$HOMEBREW_PREFIX` is `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel — shell config resolves either). Ghostty config at `~/Library/Application Support/com.mitchellh.ghostty/config`.
- **Linux (Ubuntu):** `apt` for base packages and most zsh plugins; pure isn't packaged, so it's cloned to `~/.local/share/zsh/plugins/pure`. Ghostty config at `~/.config/ghostty/config`. See `system/` for GNOME settings, power management, keyboard fixes.

Conditional logic in `.zshrc` and `install_symlinks.sh` handles the divergence. Detection uses `uname` / `IS_MAC` in shell, `vim.fn.has('macunix')` in Lua.

## Prerequisites

Ghostty 1.3+, Neovim 0.11+, zsh, mise (for node/python), ripgrep, fzf, eza. `fonts-firacode` / `font-fira-code` for ligatures.

## Ghostty usage

One Ghostty window per role, tabs for project switching. Splits are available (`Ctrl+h/t/n/s` for nav — Dvorak home row) but not core to the workflow. Cross-window focus and the broader layout design: see `docs/window-layout.md`.

## Neovim

Lua config under `nvim/lua/`: `options.lua`, `keymaps.lua`, `autocmds.lua`, `plugins/*.lua`. Leader is `<space>`. Native LSP configured via `vim.lsp.config()` / `vim.lsp.enable()` (Neovim 0.11 API). Language servers installed via mason.nvim. Formatting via conform.nvim, linting via nvim-lint, completion via blink.cmp. File picker: telescope.nvim with fzf-native. Git: gitsigns + diffview. File browser: oil.nvim (open with `-`). LaTeX: vimtex. Inline AI completions: copilot.vim. Keymap discovery: which-key.

`vim-slime` is installed (target=neovim) but not actively used — candidate for removal.

## AI agents

- **Claude Code** is the primary agent. Global instructions in `.agents/AGENTS.md` (vendor-neutral, with `.claude/CLAUDE.md` a symlink to it), settings in `.claude/settings.json`; both are symlinked to `~/.claude/`. Two accounts are isolated via `CLAUDE_CONFIG_DIR`: `~/.claude/` (personal, default) and `~/.claude-work/` (work). Shell functions `claude-personal` / `claude-work` in `.shellrc` set the config dir before launching; bare `claude` resolves the account from `$CLAUDE_DEFAULT_ACCOUNT`, then the shared `$DEFAULT_ACCOUNT`, defaulting to `personal`. Set the account in `~/.shellrc.early` (untracked, supplied by the overlay): `export DEFAULT_ACCOUNT=work` flips every account-aware tool at once, or use `CLAUDE_DEFAULT_ACCOUNT` to override just this one. Shared config (CLAUDE.md, settings, skills) is symlinked from `~/.claude/` into `~/.claude-work/` via `install_symlinks.sh` — credentials in each dir's `.credentials.json` are not shared. `claude-*` also exports `GH_CONFIG_DIR` so the bundled `gh` CLI targets the matching account.
- **gh CLI** uses the same pattern: `gh-personal` / `gh-work` shell functions point at `~/.config/gh-personal` / `~/.config/gh-work`; bare `gh` honors an explicit `$GH_CONFIG_DIR` first (so `claude-*` sessions inherit their account), then `$GH_DEFAULT_ACCOUNT`, then the shared `$DEFAULT_ACCOUNT`, defaulting to `personal`. Per-process env vars mean concurrent sessions don't stomp each other. The wrapper auto-injects `--insecure-storage` on `auth login` / `auth refresh` so tokens land in each dir's `hosts.yml` (chmod 600) instead of the system keyring — the keyring is keyed by host only, so two accounts would otherwise collide on one entry and the last write would silently win for both (`gh auth status` reads the user label from `hosts.yml`, not the actual token, so the breakage isn't obvious). Use `command gh ...` to bypass the wrapper.
- **Copilot CLI** and **Codex CLI** have MCP setup in `setup.sh` but haven't been validated in a real workflow yet — see `TODO.md`.
- **Skills** in `.agents/skills/` cover: `pr-description`, `ci-debugging`, `browser`, `coderabbit`, `execution`, `sync`. Symlinked into both Codex and Claude locations via `install_symlinks.sh`. (Skills specific to a project, system or employer are kept out of this repo and linked in separately — the pattern for that, and for composing this repo with a more specific setup generally, is in `docs/overlays.md`.)

## Work-specific setup

Anything tied to an employer, a client, or an internal project — tooling, secrets, skills, agent config, git identity — is kept out of this repo, and work machines set it up separately.

What this repo provides is two untracked hooks for it to attach to, both no-ops when the file is absent: `.shellrc` sources `~/.shellrc.early` (ahead of the mise block, so it can set env mise depends on), and `.gitconfig` includes `~/.gitconfig.local` (after `[user]`, so it can override the identity or add conditional includes). `docs/overlays.md` writes up why the reference runs in that direction, the full set of slots a more specific setup can attach to, and the rest of the tiering pattern.

## Outstanding work

See `TODO.md` for concrete remaining items and `docs/ideas.md` for unexplored directions.
