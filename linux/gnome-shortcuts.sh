#!/usr/bin/env bash
# GNOME defaults that collide with Super as the app-command modifier.
# Idempotent; safe to re-run. See ../docs/keyboard.md for what stays and why.
set -euo pipefail

# Super+V is paste and Super+N is new-window, so the notification bindings move
# out of the way. Super+M goes with the tray since it is the same action.
gsettings set org.gnome.shell.keybindings toggle-message-tray "[]"
gsettings set org.gnome.shell.keybindings focus-active-notification "[]"

# Super+D becomes bookmark. macOS never bound show-desktop there either.
gsettings set org.gnome.desktop.wm.keybindings show-desktop "[]"

# A bare tap of a modifier held dozens of times an hour should not open the
# overview. Super+Space still does.
gsettings set org.gnome.mutter overlay-key ""

# xremap owns Caps now: tap for Escape, hold for the layer. The xkb swap would
# fight it. lv3:ralt_switch stays — the Menu key becomes the right Alt that
# feeds it.
gsettings set org.gnome.desktop.input-sources xkb-options "['lv3:ralt_switch']"

# Tiling Assistant is Ubuntu's snapping, unused and in the way of the grid.
current=$(gsettings get org.gnome.shell enabled-extensions)
for ext in tiling-assistant@ubuntu.com; do
    current=$(python3 - "$current" "$ext" <<'PY'
import ast, sys
lst = ast.literal_eval(sys.argv[1])
print([e for e in lst if e != sys.argv[2]])
PY
)
done
gsettings set org.gnome.shell enabled-extensions "$current"

echo "GNOME shortcuts applied. Kept: Super+Tab, Super+Space, Super+H."
