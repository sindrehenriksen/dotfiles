# Ideas

Unexplored directions worth revisiting. Nothing here is committed work — promote to `TODO.md` if/when it becomes concrete.

## Themes

Current: Gruvbox Dark Hard in both Ghostty and Neovim (`ellisonleao/gruvbox.nvim`).

Alternatives to try:

- **Kanagawa** — similar warmth, more muted/refined. Lua-native, Ghostty theme available.
- **Catppuccin Mocha** — cooler palette, extremely well-maintained, broadest plugin coverage. Ghostty theme available.

If switching, change both Ghostty theme and Neovim colorscheme together.

## Neovim

- **lualine.nvim** — statusline showing git branch, LSP server, diagnostics, filetype. Evaluate whether it's signal or noise day-to-day. If adding it, consider moving the Tree-sitter grammar warning autocmd (`nvim/lua/autocmds.lua`) into a statusline indicator.
- **nvim-treesitter main branch** — currently pinned to `master`. The `main` branch is a rewrite with a simpler API but still stabilizing. Revisit once it hits a stable release. Migration is small since only `ensure_installed` is used.
- **copilot.lua** — Lua port of `copilot.vim`. No pressing need to migrate; reconsider if the VimScript plugin starts lagging upstream.

## Session persistence

- **Zellij** as a layer inside one or more Ghostty tabs, if detach/reattach or named sessions per project become needed. The three-column + tabs model covers project switching today.

## Shell

- Replace `zplug` with `sheldon` (Rust, fast, TOML config) or `zinit` (feature-rich, active fork) — only worth doing if startup latency becomes annoying. The current plugin list is small.
