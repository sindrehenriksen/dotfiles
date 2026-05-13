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

- [ ] Investigate user-authored skills in Claude Desktop. Live experiment (2026-05-08) confirmed local-bundle edits at `~/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/<workspace>/<plugin>/` are wiped on app launch — Desktop syncs from a remote marketplace (`creatorType: "anthropic"` only; flags `remote_marketplace_migration_done_v1`, `dxt:allowlistCache`). Revisit if Anthropic ships a documented user-skill mechanism (DXT sideload, marketplace upload, `skill-creator`-driven registration that actually persists, etc.). Goal: get our `confluence` skill (and others) usable in Desktop instead of only Code.
- [ ] Consider replacing zplug with sheldon or zinit (only if startup latency becomes an issue)
- [ ] Set `hideVimModeIndicator: true` in `.claude/settings.json` once anthropics/claude-code#53556 ships, to remove the duplicate `-- INSERT --` line below the prompt (statusline.sh already renders `[N]`/`[I]`/`[V]` from `.vim.mode`)
- [ ] Add a permission/auto-mode segment to `.claude/statusline.sh` and hide the built-in indicator once anthropics/claude-code#46419 ships (canonical issue covering both `permission_mode` in statusLine JSON and a `hidePermissionModeIndicator` setting; our narrower JSON-only request is at #54032)
