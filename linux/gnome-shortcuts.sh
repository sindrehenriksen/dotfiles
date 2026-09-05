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

# Input sources move off Alt+Shift. The key right of the space bar is a Copilot
# key, not the Menu key it looks like: it emits Meta+Shift+F23 in one press, and
# the modifier swap below turns that Meta into Alt — so the key was switching
# layout every time it was touched. Nothing can be mapped onto it either, since
# its Meta and Shift are indistinguishable from the real ones.
gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super><Shift>space']"
gsettings set org.gnome.desktop.wm.keybindings switch-input-source-backward "[]"

# The overview moves off a bare Super tap and onto Super+Space, which is the
# Mac arrangement: tapping Cmd does nothing, Cmd+Space searches. A modifier
# held dozens of times an hour should not open anything on its own. GNOME
# ships panel-main-menu on that chord, which does nothing at all in Shell 46,
# and leaves toggle-overview unbound.
gsettings set org.gnome.mutter overlay-key ""
gsettings set org.gnome.desktop.wm.keybindings panel-main-menu "[]"
gsettings set org.gnome.shell.keybindings toggle-overview "['<Super>space']"

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
