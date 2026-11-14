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

## Claude Code mods

A mod is a TypeScript module Claude Code loads into the session (the `plugin-authoring` skill): panes, slash commands that run code without the model, hooks on tool calls and prompts, and calls on the session itself, such as compacting with given instructions or submitting a prompt once the session is idle. Weighed in November 2026 against what the setup already does:

- **Not wanted for what already works.** The sessions overview lives in the notes buffer (state marks, `gx` to the tab) and Ghostty's tabs, so a pane inside one session would only duplicate it. The shell hooks work as they are.
- **The one gap worth a mod is compaction**: the keep-list used for unprompted compactions too, and a kick-off proposed after it (anthropics/claude-code#101309, where a commenter found the mod API has both calls). Submitting the kick-off is possible; leaving it unsent in the input box for review, the actual ask, has no call seen yet. Building it would also tell the issue whether the route works on an unmanaged machine.
- **A fallback for the Linux restart trigger**: a `/restart` command in place of Ghostty typing a bash-mode line, if that proves fragile.
- **Hiding the permission-mode label** under the prompt (anthropics/claude-code#89126): a render hook on `PromptHint` can rewrite that line. Untested whether the mode label sits in it.
- **Unchecked**: mods draw on the mobile surface too, which might make one useful through Remote Control.
- **Keep the lock-in thin.** A mod is an adapter: the behaviour stays in plain scripts and files any agent could call or read (`restart-session.sh`, `session-status.sh`, the keep-list as a file), and the mod only connects Claude Code's events to them, so moving to another agent means rewriting the glue, not the behaviour. Today's hooks already follow that split.

## Shell

- Reintroduce a plugin manager (`antidote` — pure zsh, static-file generation; or `sheldon` — Rust, TOML, but no apt package) if the plugin list outgrows the direct-sourcing setup in `.zshrc`. At four plugins the manager was pure overhead.
