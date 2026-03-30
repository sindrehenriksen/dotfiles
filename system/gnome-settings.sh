#!/bin/bash
# GNOME settings: keybindings, input methods, touchpad
# Idempotent — safe to re-run

#### Touchpad: two-finger tap/click = right-click
gsettings set org.gnome.desktop.peripherals.touchpad click-method 'fingers'

#### Lock screen: Super+Q (frees Super+L for dock)
gsettings set org.gnome.settings-daemon.plugins.media-keys screensaver "['<Super>q']"

#### Dock overlay numbers: Super+L
# Requires dash-to-dock extension
gsettings set org.gnome.shell.extensions.dash-to-dock shortcut "['<Super>l']"
gsettings set org.gnome.shell.extensions.dash-to-dock shortcut-text "'<Super>l'"

#### Input sources: Programmer Dvorak + local keyboard layout
# Adjust second layout to match your physical keyboard (e.g. 'no' for Norwegian)
gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us+dvp'), ('xkb', 'no')]"

#### Switch input method: Alt+Shift (default Super+Space conflicts with other uses)
gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Alt>Shift_L']"

#### Norwegian letters (å ø æ) via Right Alt + a/o/e on Programmer Dvorak
# Enables AltGr (Level 3) layer; also swaps Caps Lock and Escape
gsettings set org.gnome.desktop.input-sources xkb-options "['lv3:ralt_switch', 'caps:swapescape']"

#### Power button: handled by logind, not GNOME
# See system/logind.conf.override
