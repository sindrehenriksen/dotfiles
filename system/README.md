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

Some Lenovo models lose the internal keyboard entirely after s2idle resume.
Same root cause as the Fn media keys bug below (EC timing race on resume from
deep sleep). Both are fixed by the DKMS module below — script is currently
**disabled** (`chmod -x`) and kept as a fallback only.

[This Reddit thread](https://www.reddit.com/r/Lenovo/comments/1q02pr7/solved_keyboard_not_working_after_suspendsleep_on/)
suggests disabling battery optimization via a udev rule as a fix, but that trades
battery life for reliability. Our approach keeps battery optimization and re-scans
the keyboard controller on resume instead.

```bash
sudo cp ~/dotfiles/system/keyboard-reset /usr/lib/systemd/system-sleep/
sudo chmod +x /usr/lib/systemd/system-sleep/keyboard-reset
```

Manual workaround if keyboard dies: `kbr` alias (defined in `.shellrc`),
or directly: `sudo sh -c 'echo -n "rescan" > /sys/devices/platform/i8042/serio0/drvctl'`

### Lid close

Lid-close suspend is inconsistent due to Modern Standby (s2idle) firmware
on some Lenovo Ryzen models. Use the power button to suspend instead.

### Fn media keys stop working after long suspend

After s2idle resumes past roughly 15 minutes, all Fn media keys
(brightness, volume, mic-mute, airplane) stop emitting events. The EC
forwards raw scancodes to i8042 instead of translating them to media
keycodes, so `KEY_F1..F12` appear on the AT keyboard where
`KEY_VOLUMEUP` etc. should. `/dev/input/event6` ("Ideapad extra
buttons") goes silent.

Until fixed upstream, only reboot resolves a broken state.

Upstream bug: https://bugzilla.kernel.org/show_bug.cgi?id=221383

Status (2026-04-28): root cause identified (EC firmware timing race on
deep sleep entry), fix patch reviewed by Mario Limonciello (AMD) and
submitted to `platform-driver-x86@vger.kernel.org`.

**Workaround (active):** DKMS module from https://github.com/DanielGibson/amd_pmc-ideapad
installed at `~/src/amd_pmc-ideapad/`. Replaces the in-kernel `amd_pmc` module
with a patched version that adds a 2.5s delay before deep sleep. Auto-rebuilds
on kernel updates. Verify with:
```bash
ls /sys/module/amd_pmc/parameters/delay_suspend   # file exists = patched module loaded
journalctl -b | grep "platform bug"               # appears after first suspend
```

**When the upstream fix lands in an Ubuntu kernel update, clean up:**
- `sudo dkms remove amd_pmc/0.0.1 --all` and `rm -rf ~/src/amd_pmc-ideapad`
- Re-enable or remove the keyboard-reset script
- Remove `~/mok.key`, `~/mok.crt`, `~/mok.der` and `/var/lib/dkms/mok.*`
- Remove `~/kernel-bug-221383/` (diagnostic artifacts, no longer needed)
- Remove this section and the keyboard-reset section from this README

### MOK signing key

A Machine Owner Key was enrolled (2026-04-27) to load test modules under
Secure Boot. Key files at `~/mok.key` / `~/mok.crt` — reuse to sign future
test modules without another enrollment reboot.
