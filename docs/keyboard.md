# Keyboard model

How modifiers, layers and app shortcuts are arranged, on both machines. Window placement lives in [window-layout.md](window-layout.md); this file covers everything that is about keys rather than frames.

The two implementations are meant to stay in step — see "Parity" below.

## The shape of it

macOS gives you two separate command modifiers: Cmd for app commands (copy, new tab, save) and Ctrl for terminal control codes. Linux collapses both onto Ctrl, which is why terminals need `Ctrl+Shift+C` to copy — the plain chord is already taken by SIGINT.

The Linux setup buys the missing modifier back by making **Super the app-command key**, so `Super+C`/`Super+V`/`Super+T` mean the same thing in a terminal and a browser, and Ctrl is left alone for control codes. That is the single idea the rest of the Linux config serves.

## Modifier positions

Goal on both machines: the app-command modifier sits next to the space bar on both sides, as Cmd does on an Apple keyboard.

| | macOS | Linux |
|---|---|---|
| Caps | → F18, then tap/hold in software | → tap/hold layer |
| Left of space | Alt ↔ Cmd swapped (external kbd) | Alt ↔ Super to be swapped |
| Right of space | Alt ↔ Cmd swapped (external kbd) | AltGr → Super, Menu → AltGr |
| Bottom-left corner | fn ↔ Ctrl on the built-in keyboard | already Ctrl, nothing to do |

AltGr is load-bearing — it types the Norwegian letters on Programmer Dvorak — so it has to land somewhere. On the Mac's external keyboard it moves to the Menu key; the laptop has a Menu key to the right of space that goes unused, so it takes AltGr there too.

## Caps as a layer

Tap for Escape, hold as a modifier. Held:

- `h` / `t` / `n` / `s` — move focus west / north / south / east, across screens.
- one letter per app — jump to it, launching if needed.

The tap/hold split has to disambiguate a chord (letter released first) from a roll (Caps released first), since every letter bound here is also a vim command. macOS does this in `hammerspoon/init.lua` with an event tap and a buffer that replays keys once the decision lands.

### App jump keys

| Key | macOS | Linux |
|---|---|---|
| `c` | Chrome | Chrome |
| `g` | Ghostty | Ghostty |
| `z` | Safari | Brave |
| `b` | Finder | Files (nautilus) |
| `w` | Claude | Claude |
| `r` | Notes | *unmapped — see below* |
| `l` | Slack | *pending — not installed* |

`r` stays unmapped on Linux rather than pointed at a replacement. Apple Notes has no Linux client, and iCloud web paints the note body into a canvas, so selection and copy are pixels the browser cannot reach. What keeps it in use regardless is iPhone Spotlight: pull down from the home screen, type a note's name, and it is there without opening an app. No third-party notes app does that — Core Spotlight is open to them, but Obsidian, Joplin and Notesnook have never shipped it, and the end-to-end encrypted ones structurally cannot. The trade has been weighed once already; don't re-suggest a replacement without a new argument.

### An escape hatch for Cmd-bound web apps

iCloud's web apps bind their handlers to `metaKey`, which is exactly what Chrome reports for Super on Linux. A Super chord that reaches Chrome *untranslated* may therefore work where Ctrl does nothing — the one remaining lever on iCloud Notes' broken copy path. Translation is per-application and cannot see a URL, so keep one chord that passes Super through verbatim rather than exempting Chrome wholesale.

## Modifier taps

Tapping a modifier on its own sends a chord that otherwise needs two hands. Holding it, or using it with anything else, behaves normally.

- Left Ctrl → `Ctrl+Tab` (next tab)
- Left Shift → `Ctrl+Shift+Tab` (previous tab)

Two guards keep stray taps from firing, since both keys are ones the hand brushes constantly:

- **Quiet before** (300 ms): a real tap starts from rest, a stray one lands mid-burst. Tab is excluded from that clock, so the gesture cannot block itself and repeat taps still walk back several tabs.
- **Quiet after** (80 ms, Shift only): a Shift released a fraction early, just before the letter it was meant to capitalise, is indistinguishable from a deliberate tap until that letter lands.

`Shift+Tab` deliberately stays free — it is reverse focus traversal in GUI apps and the mode switch in Claude Code.

## Super as the app-command modifier (Linux)

Translate per application rather than remapping the key globally. A blanket Super→Ctrl remap would put `Super+C` back on SIGINT in a terminal, rebuilding the exact problem this is meant to solve.

- Apps with real keybinding config (Ghostty, editors) bind `super+…` natively. No translation, no window-detection race.
- Apps that cannot be told (Chrome, GTK apps) get their chords rewritten by app-conditional rules: `Super+V` → `Ctrl+Shift+V` in a terminal, → `Ctrl+V` elsewhere.
- Translate a **named list of keys**, never the modifier itself, or `Super+Tab`, `Super+Space` and every window-manager binding break.

### Text navigation

Emitted as sequences, which works in far more places than the nearest single chord would:

| Chord | Sends | Why not the obvious thing |
|---|---|---|
| `Super+←` / `→` | `Home` / `End` | |
| `Super+↑` / `↓` | `Ctrl+Home` / `Ctrl+End` | |
| `Super+Backspace` | `Shift+Home`, `Backspace` | `Ctrl+U` only works in readline, not GTK fields |

### GNOME shortcuts that have to move

`Super` is heavily spoken for out of the box:

| Binding | Default | Disposition |
|---|---|---|
| `toggle-message-tray` | `<Super>v`, `<Super>m` | must move — `Super+V` is paste |
| `focus-active-notification` | `<Super>n` | must move — `Super+N` is new window |
| `overlay-key` | `Super_L` | clear it; a bare tap of a heavily-held modifier should not open Activities |
| `switch-applications` | `<Super>Tab` | keep — already matches Cmd+Tab |
| `panel-main-menu` | `<Super>space` | keep — stands in for Spotlight |
| `minimize` | `<Super>h` | keep — matches Cmd+H |
| `show-desktop` | `<Super>d` | free it — bookmarking is the more useful chord |

## Layouts, and a trap worth knowing

The layout is Programmer Dvorak (`us+dvp`) with Norwegian as a second source. Two different naming worlds meet here:

- **GNOME shortcuts** (`gsettings`) are matched by **keysym** — write the letter you actually type.
- **keyd / xremap** work on **evdev keycodes**, which are physical positions named after the US-QWERTY letter that sits there. The key that types `n` on Dvorak is called `l` in an xremap config.

So every binding in `hammerspoon/init.lua`, which is written in Dvorak letters, needs translating when it is ported. Letter positions are the same in Programmer Dvorak as in plain Dvorak; only symbols and the number row differ.

| Types (Dvorak) | Config name (QWERTY position) |
|---|---|
| `h` `t` `n` `s` | `j` `k` `l` `;` |
| `g` `c` `r` `l` | `u` `i` `o` `p` |
| `m` `w` `v` | `m` `,` `.` |
| `b` `z` | `n` `/` |
| `,` `.` `o` `e` | `w` `e` `s` `d` |

## Parity

A change on one machine should be mirrored on the other, unless there is a reason not to and that reason is written down here. Divergences that are deliberate today:

- **fn ↔ Ctrl** is macOS-only. The laptop already has Ctrl in the corner.
- **`z` is Safari on macOS, Brave on Linux.** Brave is not used on the Mac.
- **`Super+D` is freed on Linux** so `Cmd+D` bookmarking works. Nothing to mirror: show-desktop on macOS is F11 and Mission Control, not Cmd+D.
- **Caps hold** is a software layer on macOS (Hammerspoon) and lives in the input remapper on Linux, but the bindings match.
- **Stray modifier taps are only suppressed on macOS.** Hammerspoon ignores a tap that lands mid-typing; xremap has no equivalent, so a brushed Shift can still switch tabs on Linux. Not a decision, a gap.
- **The two-window layouts are macOS-only for now.** They belong on both; the Linux side waits on the Shell extension.

## Status

macOS is built (`hammerspoon/init.lua`, `macos/keyboard-remap.sh`).

Linux has the keyboard layer but not the window layer, in `linux/` — see its README for how the pieces fit and what still needs confirming on first run. Everything on this page below "Caps as a layer" is implemented there except directional focus, which needs the GNOME Shell extension nobody has written yet.

The earlier attempt left two things that `linux/setup-input.sh` and `gnome-shortcuts.sh` clear out: `keyd`, installed and running against a 0-byte config, and Ubuntu's Tiling Assistant. The `xremap@k0kubun.com` entry in `enabled-extensions` was never backed by an installed extension at all.
