# Three-column window layout

Modifiers, layers and app shortcuts live in [keyboard.md](keyboard.md). A change on one machine should be mirrored on the other — see "Parity" there.

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

## Directional window focus and swap

Alt-tabbing between columns is painful. Dvorak home row `h/t/n/s` = west/north/south/east, matching Ghostty's split nav cluster (`Ctrl+h/t/n/s`), but with different modifiers to avoid conflicts.

- **Focus**: hold Caps + `h/t/n/s` — move focus to the window in that direction (crosses screens). Caps is dual-function: tap for Escape, hold as a modifier (see `macos/README.md`).
- **Swap**: `Cmd+Ctrl+h/t/n/s` — exchange frames with the window in that direction (useful for reordering middle-column terminals).
- **Jump to app**: hold Caps + one letter, on the Dvorak top and bottom rows, clear of the home-row focus keys. Table in [keyboard.md](keyboard.md).

**macOS (Hammerspoon):** implemented via `hs.window.focusWindow{East,West,North,South}()` for focus and `windowsTo{...}` + frame-exchange for swap.

**Linux:** not built yet. Directional focus has no GNOME equivalent and comes with the extension below.

Swap uses the same chord on both OSes for muscle-memory transfer; the Caps-hold keys are macOS-only, since Caps depends on Hammerspoon. `Cmd+Ctrl` was chosen over `Ctrl+Alt+Shift` (too heavy) and `Cmd` alone (breaks hide/new/save).

## Why this shape

- Nvim is always visible — no split zoom dance, no focus-swap resize.
- Separate Ghostty tabs → separate nvim instances → no shared-state issues (LSP, cwd, buffers all per-project).
- Middle column is general-purpose terminal space; project-bound by habit, not by config — `cd` into the right project before running an agent.
- Fixed columns are predictable and kind to muscle memory.

## Implementation

### macOS — Hammerspoon

Single config file (`hammerspoon/init.lua`), symlinked to `~/.hammerspoon/init.lua`. Replaces Divvy.

**Picker:** `Opt+Cmd+T` enters a modal layout mode (alert shows "Layout"); press one key to place the focused window. Escape exits. Key scheme is Dvorak home row.

| Key | Action |
|---|---|
| `h` / `t` / `n` | left / center / right **third** (full height) |
| `g` / `c` / `r` | upper half of that column |
| `m` / `w` / `v` | lower half of that column |
| `Shift+h` / `t` / `n` | left / center / right **half** (wider than third) |
| `s` | full screen |
| `,` / `.` | **small** of a two-window pair, left / right |
| `o` / `e` | **large** of a two-window pair, left / right |

**Display cycling:** pressing the same key again when the window is already at that target cycles it to the next screen. Cross-screen moves apply `setFrame` twice (second via a 0.05s timer) to correct a mixed-DPI sizing glitch.

**Gaps:** `GAP` constant at the top of `init.lua` (default 10px) — air around every window including screen edges. Tune to taste.

Placement only places. An earlier version shoved the occupant of a target slot into the complementary slot; it went unused and was most of the file.

**Two-window pairs** (`,` `.` `o` `e`) are for the common case of one terminal and one browser, where the three-column grid is more structure than the situation needs. Each window sits a fixed margin in from its outer edge, so left and right mirror exactly and the two sides can be swapped without anything shifting.

Their geometry is per display, since the two screens do not want the same thing:

| | ultrawide (2.39:1) | laptop (16:10) |
|---|---|---|
| outer margin | 10% (344px) | 0.5% (10px) |
| small | 29.5% × 70% | 49% × 66% |
| large | 48% × 90% | 73% × 96% |
| between them | 86px gap | 442px overlap |
| vertical | both centred | large centred, small held near the top |

The ultrawide has room to tile both with air around them. The laptop does not, so the large window takes the screen and the small one floats over it, held high rather than centred — the small window is the terminal, and the space below it is where the large one stays readable. Screens are told apart by aspect ratio (wider than 2:1 counts as wide), not by resolution, so the split survives a different monitor.

### Linux/Ubuntu — GNOME Shell extension

Wayland blocks external window manipulation, so the only viable approach is a Shell extension that operates inside the compositor.

Written rather than adopted. The off-the-shelf tilers (Tiling Shell, Forge, PaperWM) each impose their own model — auto-tiling, tree layouts, or scrollable columns — and none offers a modal picker that drops a window into a named slot, which is the whole interaction here. Bending one into shape is more work than the placement maths, which is a dozen lines.

Ubuntu's own Tiling Assistant is enabled by default and unused; it goes when the extension lands.

## Key decisions

- **Replace Divvy** (macOS) rather than running both — they conflict on window frame ownership.
- **Static columns, no auto-swap** — predictability over cleverness.
- **Manual reorder in the middle column** — quick keybind to promote a window to the top slot, no focus-based magic.
