# Three-column window layout

## Goal

A predictable, static three-column layout on widescreen: browser on the left, project terminals in the middle, nvim on the right. Project switching happens inside Ghostty tabs on the right; middle-column terminals are reordered manually as needed. No auto-resize on focus.

## Layout

```
┌─────────┬──────────┬──────────┐
│         │ proj A   │          │
│         │ (top:    │ Ghostty  │
│ Browser │  ~50%)   │ tabs:    │
│ (~1/3)  ├──────────┤  proj A  │
│         │ proj B   │  proj B  │
│         │          │  proj C  │
│         ├──────────┤          │
│         │ proj C   │ (each    │
│         │          │  runs    │
│         │          │  nvim)   │
└─────────┴──────────┴──────────┘
    1/3       1/3        1/3
```

- **Left (~1/3):** Browser. Persistent.
- **Middle (~1/3):** Up to 3 Ghostty terminal windows, one per active project (convention, not enforced). Master-stack sizing — top window ~50% height, the rest share the remaining 50%. Each window has its own tabs for agents/services/shells within that project.
- **Right (~1/3):** One Ghostty window with tabs — one tab per project. Each tab runs its own nvim instance (full isolation: per-project LSP, cwd, buffers). Buffer switching within a project stays inside nvim (telescope, `:bnext`/`:bprev`) — no nvim splits.

## Project switching

- **Code:** `Ctrl+Tab` / `Alt+N` in the right Ghostty window to switch nvim tab (= switch project).
- **Terminal:** click or keybind to the matching project terminal in the middle column. Reorder manually to put the active one in the top (50%) slot if wanted. No automatic swap on focus.

## Directional window focus (across columns)

Alt-tabbing between columns is painful. Use `Super+h/t/n/s` (Dvorak home row) for focus left/up/down/right across OS windows.

- **macOS (Hammerspoon):** `hs.window.focusWindowEast/West/North/South()`
- **Linux:** built into Tiling Shell, Forge, and PaperWM. Configure in the extension's settings.

Same binding on both OSes for muscle-memory transfer. Same cluster as Ghostty split nav (`Ctrl+h/t/n/s`), different modifier. Avoid `Ctrl+h/j/k/l` (former Neovim window nav) and `Ctrl+h/t/n/s` (Ghostty splits).

## Why this shape

- Nvim is always visible — no split zoom dance, no focus-swap resize.
- Separate Ghostty tabs → separate nvim instances → no shared-state issues (LSP, cwd, buffers all per-project).
- Middle column is general-purpose terminal space; project-bound by habit, not by config — `cd` into the right project before running an agent.
- Fixed columns are predictable and kind to muscle memory.

## Implementation

### macOS — Hammerspoon

- Three-column layout via grid/layout definitions.
- Divvy-equivalent shortcuts in the same config for one-off window placement.
- Single config file (`~/.hammerspoon/init.lua`) — goes in this repo, symlinked.
- Master-stack middle column: custom Lua function that sizes stacked windows.

### Linux/Ubuntu — GNOME Shell extension

Wayland blocks external window manipulation, so the only viable approach is a Shell extension that operates inside the compositor.

**Options:**

- **Tiling Shell** — explicit layout ratios via Fancy Zones-style editor. Likely the best fit for the fixed-column + master-stack model. https://github.com/domferr/tilingshell
- **Forge** — i3/sway-style tree tiling with vim keybindings. Master-stack is native but less GUI-friendly for column ratios. https://github.com/forge-ext/forge
- **PaperWM** — scrollable tiling, focused window naturally takes more space. Better for dynamic focus-swap, less natural for fixed columns. Probably not the right fit. https://github.com/paperwm/PaperWM

Try Tiling Shell first; Forge as a fallback.

## Key decisions

- **Replace Divvy** (macOS) rather than running both — they conflict on window frame ownership.
- **Static columns, no auto-swap** — predictability over cleverness.
- **Manual reorder in the middle column** — quick keybind to promote a window to the top slot, no focus-based magic.
