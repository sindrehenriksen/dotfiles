# Linux keyboard setup

The Linux half of the model in [../docs/keyboard.md](../docs/keyboard.md) — read that first; it says what the bindings are and why Super carries app commands. This file is only how the pieces fit together on this machine. Window placement is not built yet.

## What is here

| file | what it is |
|---|---|
| `xremap.yml` | the remapping itself, symlinked to `~/.config/xremap/config.yml` |
| `xremap.service` | user service, symlinked into `~/.config/systemd/user/` |
| `focus-or-launch` | app-jump helper for the Caps layer, symlinked into `~/.local/bin` |
| `install.sh` | fetches xremap and its GNOME extension; no root |
| `setup-input.sh` | input-device permissions, and removes keyd; needs root |
| `gnome-shortcuts.sh` | clears the GNOME defaults that collide with Super |

## First run

```sh
linux/install.sh
sudo linux/setup-input.sh
linux/gnome-shortcuts.sh
# log out and back in
systemctl --user enable --now xremap
```

The log-out is not optional. Group membership only applies to a new session, and GNOME Shell cannot see a newly installed extension until it restarts — which on Wayland means logging out.

## Why xremap rather than keyd

keyd is the better tool for pure key-position remapping and it works at the console, but it has no idea which window has focus. Making Super behave like Cmd needs exactly that: `Super+V` has to become `Ctrl+Shift+V` in a terminal and `Ctrl+V` everywhere else. Only xremap can ask, via its GNOME Shell extension.

A second remapper alongside it buys nothing while the difference is only key positions, which both tools do. It stops being true if the tap-hold behaviour under Known gaps is ever wanted — kanata has primitives xremap lacks, and that is a real gain rather than a duplicated one.

## Verifying

One value in `xremap.yml` was written from documentation and has since been confirmed on this machine. It is worth re-checking on different hardware, since it fails quietly:

- **Ghostty's window class is `com.mitchellh.ghostty`.** If this were wrong the terminal would fall into the general Super translation, and `Super+C` would interrupt rather than copy:

```sh
busctl --user call org.gnome.Shell /com/k0kubun/Xremap com.k0kubun.Xremap WMClasses
```

## Known gaps

- **Directional window focus and the placement grid are missing.** Both need a GNOME Shell extension that has not been written. Caps + `h/t/n/s` does nothing yet.
- **Stray modifier taps fire more often than on macOS.** Hammerspoon suppresses a tap that lands mid-typing; xremap has no equivalent, so a brushed Shift can still switch tabs.
- **The Caps layer waits.** It engages on hold time (`hold_threshold_millis`) rather than on which key is released first, so the layer costs a real pause that macOS does not.

  Both of the above are fixable, but only by adding [kanata](https://github.com/jtroo/kanata) alongside xremap: it has `tap-hold-order`, which resolves purely by release order with no timeout, and `(require-prior-idle <ms>)`, which suppresses a tap that follows recent typing. Neither exists in xremap. kanata cannot replace it, having no window awareness for the per-application Super translation, so this means two remappers chained — kanata grabbing the keyboard and emitting a virtual device, xremap reading only that. Not done, because it doubles the input stack for a question of feel.
- **Slack and Notes are unmapped** on the Caps layer. Slack is not installed; Notes is a decision recorded in the keyboard doc.
- **Super is only on the left of the space bar**, unlike the Mac. The key right of it carries a small menu glyph but is a Copilot key: one press emits `KEY_LEFTMETA` + `KEY_LEFTSHIFT` + `KEY_F23` together, so nothing can be mapped onto it — its Meta and Shift are the same events the real keys produce. Read the scancodes rather than the legend. AltGr therefore stays where it is, on the right of the space bar.

  That chord is also why input sources are bound to `Super+Shift+Space` rather than GNOME's default `Alt+Shift`: after the modifier swap the Copilot key emits Alt+Shift, so it was switching layout on every press.

  To see what a key really sends, stop the service and read the device — `RUST_LOG=debug` works too but writes every keystroke to the journal:

```sh
systemctl --user stop xremap   # it holds an exclusive grab
sudo evtest /dev/input/event2  # or read it directly; the input group suffices
systemctl --user start xremap
```
