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
- [ ] Add a permission/auto-mode segment to `claude/statusline.sh` once `permission_mode` lands in the statusLine JSON (tracked at anthropics/claude-code#77910; re-file chain: #54032 → #66318 → #77910). Scoped to exposing it for our own statusline — hiding the built-in indicator (old #46419 framing) is deliberately not tracked.
- [ ] Watch anthropics/claude-code#90879 — the startup warning on allow rules whose wildcard precedes the subcommand (`Bash(git -C * status)` and the four commit rules, nine lines on every launch). Filed by someone else; commented ([#issuecomment-5551369810](https://github.com/anthropics/claude-code/issues/90879#issuecomment-5551369810)) with the trigger mechanism — the scan needs a fully literal token to terminate, so `aws * describe-*` is silent and rules ending `:*` are skipped outright, the silent forms being the broader ones — and the fix worth having: a wildcard that refuses to match option-shaped tokens, which closes the vector the warning names without enumeration, a deny mirror, or a suppression switch. Neither of its two suggestions can be followed here: the slot is a path, and worktree paths are made per task. Also asked for realpath deduping, which is what printed each finding twice before the payload moved out of `.claude/`.
- [ ] Watch anthropics/claude-code#66402 — `/model` and `/effort` persist to global `settings.json`, so switching in one session leaks into every other live session (and breaks agents/fleet view); no non-persisting per-session/per-agent scope. Subscribed; commented ([#issuecomment-4999128779](https://github.com/anthropics/claude-code/issues/66402#issuecomment-4999128779)) arguing the real gap is *scope*: keep the persisted default, add a session-only change that touches no other session, with explicit opt-in to persist (`/model --save` or `/model-default`). Directly affects this repo: `claude/settings.json` is tracked, so `/model` writes `"model": ...` into a committed file (multi-hunk diff from reserialization). Supersedes stale-closed #43061 (auto-closed as a "duplicate" of the fixed #20745, though the session-only ask was never actually delivered). Workaround today: `CLAUDE_CODE_EFFORT_LEVEL=<level> claude` is per-process and outranks settings.json. The model half is handled locally (2bdc637): the `model` key stays out of the tracked file and `ANTHROPIC_DEFAULT_MODEL` pins it, which works only while that key is absent. The effort half is not, and the two variables are not symmetric — `CLAUDE_CODE_EFFORT_LEVEL` outranks settings rather than filling in for a missing key, so exporting it would also make `/effort` refuse live changes ("Not applied: … overrides effort this session"). Left unset deliberately: that costs a control to defend against something seen once, and the file being tracked is what catches a stray write. Observed once on 2.1.261 — `modelSettings.claude-opus-5.effortLevel` went xhigh → high with no `/effort` typed, and did not recur on later runs; key reordering accompanies any write, so it distinguishes nothing. `/effort` has the same two-branch shape `/model` turned out to have ("saved as your default for new sessions" vs "this session only"), and `/effort auto` clears the key. Upstream surface is wider than #66402: #78329 (session-only `s` in the /effort picker), #86873 (`s` honoured for model but effort still written), #89548 (session-only flag for typed commands), #81950 (remote attach shows/resets to high). Remote Control may set `effortLevel` on a session via `apply_flag_settings`, which is the likeliest source of a write nobody typed; if it recurs, #81950 is where it goes.
