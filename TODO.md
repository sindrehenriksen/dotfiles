# TODO

Concrete remaining work. Ideas and future experiments live in `docs/ideas.md`.

## Window layout

Three-column layout (browser | terminals | nvim tabs) — design in `docs/window-layout.md`.

- [x] macOS: Hammerspoon config (`~/.hammerspoon/init.lua`, goes in this repo, symlinked) — replaces Divvy
- [ ] Linux: Tiling Shell GNOME extension (try first); Forge as fallback
- [x] Cross-window directional focus and swap on Dvorak home row (macOS: Hammerspoon; Linux: TBD in the GNOME extension)

## Cleanup

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
- [ ] Drop `CLAUDE_CODE_NO_FLICKER=1` from `_claude-run` once anthropics/claude-code#13591 ships a proper sticky-input fix (currently relying on fullscreen rendering mode as a workaround)
- [ ] Set `hideVimModeIndicator: true` in `.claude/settings.json` once anthropics/claude-code#53556 ships, to remove the duplicate `-- INSERT --` line below the prompt (statusline.sh already renders `[N]`/`[I]`/`[V]` from `.vim.mode`)
- [ ] Add a permission/auto-mode segment to `.claude/statusline.sh` once anthropics/claude-code#52510 exposes `permission_mode` in the statusLine JSON (currently no way to surface auto/plan/bypass state)
