# TODO

Concrete remaining work. Ideas and future experiments live in `docs/ideas.md`.

## Window layout

Three-column layout (browser | terminals | nvim tabs) — design in `docs/window-layout.md`.

- [x] macOS: Hammerspoon config (`~/.hammerspoon/init.lua`, goes in this repo, symlinked) — replaces Divvy
- [ ] Linux: Tiling Shell GNOME extension (try first); Forge as fallback
- [x] Cross-window directional focus and swap on Dvorak home row (macOS: Hammerspoon; Linux: TBD in the GNOME extension)

## Agent CLIs

- [ ] Linux: gh comes from mise (`aqua:cli/cli`, machine-local `~/.config/mise/config.toml`), pinned at 2.103.2 on 2026-10-24, with `expiring_credentials` enabled (public preview): the token sits in plain text in `hosts.yml`, so a leaked copy should die within hours. The setting applies only to a new login, so the token there stays the old, non-expiring one until GitHub CLI is revoked under github.com/settings/applications and `gh auth login` is run again. Nothing here caches `gh auth token`, which is the one thing the switch breaks.
- [ ] Re-tune for Opus 5.5, what is still open. Method and findings are in `docs/agent-setup-retune.md`. Open: subagent effort levels, which were not measured — the move of well-specified Opus-class jobs to `medium` gets checked around mid-November 2026, comparing rework and tokens of medium against high subagent jobs with `claude/claude-usage-baseline`, which records effort per call; and whether the provider's advisor tool would earn its place beside the question path.
- [ ] Decide whether agent-workflow nvim keymaps are worth adding (`<leader>dv` for DiffviewOpen, etc.) or if the defaults are fine

## Verification

- [ ] Test native LSP in a real Python project (basedpyright: go-to-definition, completions, format-on-save)
- [ ] Test native LSP in a real TypeScript project (ts_ls)
- [ ] Verify true color + undercurl in Ghostty → Neovim (check `TERM`, inspect diagnostics underlines)
- [ ] Verify clipboard: yank in nvim → paste in browser; copy in one Ghostty tab → paste in another; OSC 52 over SSH

## Low priority

- [ ] Upgrade `ghostty@tip` to a build with [#14691](https://github.com/ghostty-org/ghostty/pull/14691) (merged 2026-10-13), the likely fix for the hang where a display hot-plug leaves a window's renderer stuck in `CVDisplayLinkStop` and the next resize freezes the app ([discussion #14427](https://github.com/ghostty-org/ghostty/discussions/14427), upvoted). The cask quits Ghostty before replacing it, so run `brew upgrade --cask ghostty@tip` from Terminal.app at a stopping point, then reopen the sessions. If it recurs on the new build, that is worth a comment on #14427.
- [ ] Move back to the stable `ghostty` cask once a release carries the macOS 27 titlebar-tabs fix ([#13069](https://github.com/ghostty-org/ghostty/pull/13069), merged 2026-06-22, absent from 1.3.1). With `macos-titlebar-style = tabs` the stable build collapses the tab bar into a stub box beside the `+` on macOS 26/27, so this machine runs `ghostty@tip` (1.3.2-main) for the fix and tracks main as the price. Reversing it is `brew uninstall --cask ghostty@tip` then `brew install --cask ghostty`; the config needs no edit, since `tabs` is what both builds are configured for. Several other Tahoe-era titlebar-tab bugs are open upstream, so check the release notes rather than assuming one fix settles it.
- [ ] Investigate user-authored skills in Claude Desktop. Live experiment (2026-05-08) confirmed local-bundle edits at `~/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/<workspace>/<plugin>/` are wiped on app launch — Desktop syncs from a remote marketplace (`creatorType: "anthropic"` only; flags `remote_marketplace_migration_done_v1`, `dxt:allowlistCache`). Revisit if Anthropic ships a documented user-skill mechanism (DXT sideload, marketplace upload, `skill-creator`-driven registration that actually persists, etc.). Goal: get our `confluence` skill (and others) usable in Desktop instead of only Code.
- [ ] Add a permission/auto-mode segment to `claude/statusline.sh` once `permission_mode` lands in the statusLine JSON; check for the field on upgrades. Asked for in anthropics/claude-code#89126 and #93803.
- [ ] Watch anthropics/claude-code#90879, the startup warning on the `git -C * <subcommand>` allow rules: when it is fixed, check the warning is gone. The rules stay as they are (`AGENTS.md`, "Auto-Approved Commands").
- [ ] Watch anthropics/claude-code#66402, `/model` and `/effort` persisting to the global `settings.json`: when a session-only scope lands, use it. Until then the `model` key stays out of the tracked file (`ANTHROPIC_DEFAULT_MODEL` in `.shellrc`), a stray `effortLevel` write shows in `git diff`, and `CLAUDE_CODE_EFFORT_LEVEL` stays unset because it makes `/effort` refuse live changes.
- [ ] Watch anthropics/claude-code#95929, full diffs in the transcript for files a shell command changed (a `git pull`, a rebase): no setting turns it off, so set one when it lands.
- [ ] Watch anthropics/claude-code#76684, no redo in vim mode: when `chat:redo` lands, bind it and drop the Ctrl+R unbind in `claude/keybindings.json`.
- [ ] Watch anthropics/claude-code#100828 (ours), no `VimNormal` keybinding context: when it lands, turn off `/` opening history search and bind Ctrl+R to redo in normal mode only.
- [ ] Watch anthropics/claude-code#101309 (ours), instructions for unprompted compactions and a prefilled kick-off: `claude/hooks/compact-handoff.sh` stands in on two undocumented behaviours (PreCompact stdout joins the instructions, idle compaction runs at all), so recheck them on upgrades, and shrink or drop the hook when either ask lands.
- [ ] Watch anthropics/claude-code#103483 (ours), `idleCompaction: true` as an opt-in that also runs under the prompt-cache keepalive: set it when it lands.
