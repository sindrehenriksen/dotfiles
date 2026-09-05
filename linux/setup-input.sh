#!/usr/bin/env bash
# Privileged half of the keyboard setup: let this user read input devices and
# create a virtual one, so xremap runs as a user service rather than as root.
# Running it as root would keylog every user on the machine and keep remapping
# while the screen is locked.
#
# Run once with sudo, then log out and back in — group membership and the
# GNOME extension both need a fresh session.
set -euo pipefail

[ "${EUID}" -eq 0 ] || { echo "run this with sudo" >&2; exit 1; }
target_user="${SUDO_USER:-}"
[ -n "$target_user" ] || { echo "run via sudo, not as root directly" >&2; exit 1; }

# keyd was an earlier attempt at the same job. It cannot do the part that
# matters — remapping differently per application — and two remappers grabbing
# the same devices is a needless source of confusion.
if systemctl list-unit-files keyd.service >/dev/null 2>&1; then
    systemctl disable --now keyd.service || true
fi
rm -f /usr/local/bin/keyd /usr/local/bin/keyd-application-mapper
rm -rf /etc/keyd
rm -f /etc/systemd/system/keyd.service /usr/local/lib/systemd/system/keyd.service
systemctl daemon-reload

gpasswd -a "$target_user" input

echo 'KERNEL=="uinput", GROUP="input", TAG+="uaccess", MODE:="0660", OPTIONS+="static_node=uinput"' \
    > /etc/udev/rules.d/99-input.rules

echo uinput > /etc/modules-load.d/uinput.conf
modprobe uinput
udevadm control --reload-rules
udevadm trigger

echo
echo "Done. Log out and back in, then: systemctl --user enable --now xremap"
