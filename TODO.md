# TODO

Concrete remaining work. Ideas and future experiments live in `docs/ideas.md`.

## Window layout

Three-column layout (browser | terminals | nvim tabs) — design in `docs/window-layout.md`.

- [x] macOS: Hammerspoon config (`~/.hammerspoon/init.lua`, goes in this repo, symlinked) — replaces Divvy
- [ ] Linux: Tiling Shell GNOME extension (try first); Forge as fallback
- [ ] Cross-window directional focus: `Super+h/t/n/s` for focus left/up/down/right across OS windows. Same cluster as Ghostty splits, different modifier

## Cleanup

- [ ] Remove `.tmux.conf` from the repo and `install_symlinks.sh`
- [ ] Decide whether to drop `vim-slime` (installed but unused)

## Agent CLIs

- [ ] Test Copilot CLI end-to-end, adapt skills/prompts where needed
- [ ] Test Codex CLI end-to-end (reads `AGENTS.md` for project context)
- [ ] Decide whether agent-workflow nvim keymaps are worth adding (`<leader>dv` for DiffviewOpen, etc.) or if the defaults are fine

## Verification

- [ ] Test native LSP in a real Python project (basedpyright: go-to-definition, completions, format-on-save)
- [ ] Test native LSP in a real TypeScript project (ts_ls)
- [ ] Verify true color + undercurl in Ghostty → Neovim (check `TERM`, inspect diagnostics underlines)
- [ ] Verify clipboard: yank in nvim → paste in browser; copy in one Ghostty tab → paste in another; OSC 52 over SSH

## Low priority

- [ ] Consider replacing zplug with sheldon or zinit (only if startup latency becomes an issue)
