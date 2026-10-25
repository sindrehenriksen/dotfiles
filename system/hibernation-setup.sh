#!/bin/bash
# Make hibernation work: grow /swap.img to hold a RAM image, tell the kernel and
# initramfs where to resume from, and lift Ubuntu's polkit refusal. Run with
# sudo; takes effect at the next boot.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

swapoff /swap.img
rm /swap.img
fallocate -l 16G /swap.img
chmod 600 /swap.img
mkswap /swap.img
swapon /swap.img

uuid=$(findmnt -no UUID /)
# First physical block of the file, in 4 KiB filesystem blocks = pages.
offset=$(filefrag -v /swap.img | awk '$1=="0:" {sub(/\.\./, "", $4); print $4}')
[ -n "$offset" ] || { echo "could not read swap file offset" >&2; exit 1; }

# update-initramfs warns "no matching swap device" for this: its check knows
# swap partitions only. The setting is copied into the initramfs regardless.
echo "RESUME=UUID=$uuid" > /etc/initramfs-tools/conf.d/resume
cat > /etc/default/grub.d/hibernate.cfg <<EOF
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT resume=UUID=$uuid resume_offset=$offset"
EOF
cp "$(dirname "$0")/allow-hibernate.rules" /etc/polkit-1/rules.d/50-allow-hibernate.rules

update-initramfs -u -k all
update-grub
echo "done: resume=UUID=$uuid resume_offset=$offset"
