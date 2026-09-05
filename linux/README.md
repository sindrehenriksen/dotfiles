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

keyd is the better tool for pure key-position remapping and it works at the console, but it has no idea which window has focus. Making Super behave like Cmd needs exactly that: `Super+V` has to become `Ctrl+Shift+V` in a terminal and `Ctrl+V` everywhere else. Only xremap can ask, via its GNOME Shell extension. Running both would mean two processes grabbing the same devices and chaining virtual keyboards in the right order, for no gain.

## Verifying

Two values in `xremap.yml` were written from documentation and have since been confirmed on this machine. Both are worth re-checking on different hardware, since each fails quietly:

- **The Menu key sends `KEY_COMPOSE`.** It carries AltGr, so the Norwegian letters depend on it. A keyboard without that key loses them. `RUST_LOG=debug xremap --watch=config,device ~/.config/xremap/config.yml` names each key as you press it; the keyboard's capability map answers the same question without stopping the service:

```sh
grep -A6 'AT Translated' /proc/bus/input/devices   # bit 127 of B: KEY= is KEY_COMPOSE
```

- **Ghostty's window class is `com.mitchellh.ghostty`.** If this were wrong the terminal would fall into the general Super translation, and `Super+C` would interrupt rather than copy:

```sh
busctl --user call org.gnome.Shell /com/k0kubun/Xremap com.k0kubun.Xremap WMClasses
```

## Known gaps

- **Directional window focus and the placement grid are missing.** Both need a GNOME Shell extension that has not been written. Caps + `h/t/n/s` does nothing yet.
- **Stray modifier taps fire more often than on macOS.** Hammerspoon suppresses a tap that lands mid-typing; xremap has no equivalent, so a brushed Shift can still switch tabs.
- **Slack and Notes are unmapped** on the Caps layer. Slack is not installed; Notes is a decision recorded in the keyboard doc.
