# dotfiles

Personal dev environment: zsh, Neovim, Ghostty, Git, AI agent configs. Cross-platform (macOS + Ubuntu).

## Layout

| Path | What |
|---|---|
| `.zshrc`, `.zprofile`, `.bashrc`, `.profile`, `.shellrc` | Shell init; `.shellrc` is sourced by both bash and zsh |
| `.shellrc-visma` | Work-specific shell additions, sourced via `.shellrc` |
| `.gitconfig`, `.gitlint` | Git config and commit linting |
| `.fzf_config` | fzf defaults (rg-backed file list) |
| `nvim/` | Neovim Lua config (lazy.nvim, native LSP, blink.cmp, telescope, gitsigns, diffview, gruvbox.nvim) |
| `ghostty/config` | Ghostty terminal config (Fira Code, Gruvbox Dark Hard, split nav on Dvorak home row) |
| `hammerspoon/init.lua` | macOS window layout (picker on `Opt+Cmd+T`, three-column + one-off placement) — see `docs/window-layout.md` |
| `.claude/` | Claude Code global config (`CLAUDE.md`, `settings.json`) |
| `.agents/skills/` | Agent skills — single source, symlinked to `~/.agents/skills/` and `~/.claude/skills/` (global) plus `~/dotfiles/.claude/skills/` for repo-only skills |
| `copilot-prompts/` | VS Code Copilot instructions (symlinked into VS Code user prompts dir) |
| `secrets/` | Example secrets templates (real secrets live in `~/.secrets.env`, untracked) |
| `system/` | Linux-only: GNOME keybinds, logind, battery conservation — see `system/README.md` |
| `git-hooks/` | Repo-local git hooks (`core.hooksPath`): `commit-msg` enforces 50/72 title + reflows body at 72, `pre-commit` delegates to the `pre-commit` framework if installed |

## Setup

On a fresh machine:

1. Run `setup.sh` step-by-step (it's a checklist, not a script — different steps for macOS vs Ubuntu).
2. Run `install_symlinks.sh` to place the symlinks.
3. For work machines: also run `setup-visma.sh` and `install_symlinks_visma.sh`.
4. Copy `secrets/secrets.env.example` to `~/.secrets.env`, edit, `chmod 600`.
5. Open nvim — lazy.nvim bootstraps itself and installs plugins. `:Mason` to install LSP servers.

## Platform notes

- **macOS:** Homebrew for packages, zplug via `/opt/homebrew/opt/zplug`. Ghostty config at `~/Library/Application Support/com.mitchellh.ghostty/config`.
- **Linux (Ubuntu):** `apt` for base packages, zplug cloned to `~/.zplug`. Ghostty config at `~/.config/ghostty/config`. See `system/` for GNOME settings, power management, keyboard fixes.

Conditional logic in `.zshrc` and `install_symlinks.sh` handles the divergence. Detection uses `uname` / `IS_MAC` in shell, `vim.fn.has('macunix')` in Lua.

## Prerequisites

Ghostty 1.3+, Neovim 0.11+, zsh, mise (for node/python), ripgrep, fzf, eza. `fonts-firacode` / `font-fira-code` for ligatures.

## Ghostty usage

One Ghostty window per role, tabs for project switching. Splits are available (`Ctrl+h/t/n/s` for nav — Dvorak home row) but not core to the workflow. Cross-window focus and the broader layout design: see `docs/window-layout.md`.

## Neovim

Lua config under `nvim/lua/`: `options.lua`, `keymaps.lua`, `autocmds.lua`, `plugins/*.lua`. Leader is `<space>`. Native LSP configured via `vim.lsp.config()` / `vim.lsp.enable()` (Neovim 0.11 API). Language servers installed via mason.nvim. Formatting via conform.nvim, linting via nvim-lint, completion via blink.cmp. File picker: telescope.nvim with fzf-native. Git: gitsigns + diffview. File browser: oil.nvim (open with `-`). LaTeX: vimtex. Inline AI completions: copilot.vim. Keymap discovery: which-key.

`vim-slime` is installed (target=neovim) but not actively used — candidate for removal.

## AI agents

- **Claude Code** is the primary agent. Global instructions in `.claude/CLAUDE.md`, settings in `.claude/settings.json` (both symlinked to `~/.claude/`).
- **Copilot CLI** and **Codex CLI** have MCP setup in `setup.sh` but haven't been validated in a real workflow yet — see `TODO.md`.
- **Skills** in `.agents/skills/` cover: `pr-review`, `pr-description`, `browser`, `sync`, `confluence` (work-only), `adding-skills`. Symlinked into both Codex and Claude locations via `install_symlinks.sh`.
- VS Code Copilot prompts in `copilot-prompts/` (`general.instructions.md`, `git.instructions.md`).

## Work-specific setup

`setup-visma.sh` handles Atlassian MCP, Azure, and other work-only tooling. `install_symlinks_visma.sh` adds the Confluence skill and `.shellrc-visma`. Work secrets live in `~/.secrets-visma.env`.

## Outstanding work

See `TODO.md` for concrete remaining items and `docs/ideas.md` for unexplored directions.
