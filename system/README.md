# System configuration

Scripts and configs for Linux (Ubuntu/GNOME) system-level setup.

## General (any Linux desktop)

### GNOME keybindings & input (`gnome-keybindings.sh`)

Run once (idempotent):

```bash
~/dotfiles/system/gnome-keybindings.sh
```

Sets up:
- **Super+Q** → lock screen (frees Super+L for dock)
- **Super+L** → dock overlay numbers (dash-to-dock)
- **Alt+Shift** → switch input method (default Super+Space conflicts)
- **Right Alt** → AltGr/Level 3 (Norwegian letters å ø æ via RAlt+a/o/e on Programmer Dvorak)
- **Caps Lock** ↔ **Escape** swap

To adapt for another machine: edit the `input-sources` and `xkb-options`
lines for your keyboard layout. The keybindings are layout-independent.

### Power button (`logind.conf.override`)

Hold power button ~1 second to suspend. `HandlePowerKey=ignore` in logind
lets firmware handle it directly (avoids double-suspend quirks).

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
sudo cp ~/dotfiles/system/logind.conf.override /etc/systemd/logind.conf.d/override.conf
sudo systemctl restart systemd-logind
```

### Battery optimization

TLP handles most tuning automatically:

```bash
sudo apt install tlp
sudo systemctl enable --now tlp
```

Verify: `sudo tlp-stat -s` (enabled), `sudo tlp-stat -r` (wifi power saving on).

### Note: avoid Toshy

[Toshy](https://github.com/RedBearAK/toshy) (Mac-style keybindings for Linux) conflicts
badly with Programmer Dvorak and custom keybindings — it remaps at a layer that
fights both the layout engine and personal shortcuts.

## Lenovo-specific

### Battery conservation mode (`battery-limit.service`)

Caps charge at ~80% via ideapad_acpi driver.

```bash
sudo cp ~/dotfiles/system/battery-limit.service /etc/systemd/system/
sudo systemctl enable --now battery-limit.service
```

For non-Lenovo laptops, use TLP thresholds instead:
`START_CHARGE_THRESH_BAT0=75` / `STOP_CHARGE_THRESH_BAT0=80` in `/etc/tlp.conf`
(if your hardware supports it — check `sudo tlp-stat -b`).

### Keyboard resume fix (`keyboard-reset`)

Some Lenovo models lose the internal keyboard after s2idle resume.
[This Reddit thread](https://www.reddit.com/r/Lenovo/comments/1q02pr7/solved_keyboard_not_working_after_suspendsleep_on/)
suggests disabling battery optimization via a udev rule as a fix, but that trades
battery life for reliability. Our approach keeps battery optimization and re-scans
the keyboard controller on resume instead.

```bash
sudo cp ~/dotfiles/system/keyboard-reset /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/lib/systemd/system-sleep/keyboard-reset
```

**TODO:** Test disabling this script after kernel updates — the bug may be
fixed upstream. If keyboard works after resume without it, remove it.

Manual workaround if keyboard dies: `kbr` alias (defined in `.shellrc`),
or directly: `sudo sh -c 'echo -n "rescan" > /sys/devices/platform/i8042/serio0/drvctl'`

### Lid close

Lid-close suspend is inconsistent due to Modern Standby (s2idle) firmware
on some Lenovo Ryzen models. Use the power button to suspend instead.
