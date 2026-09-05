#!/usr/bin/env bash
# Build, install and Secure Boot-sign a mainline kernel .deb.
#
#   ~/dotfiles/system/kernel-mainline-build.sh 7.2.3
#
# Why this exists at all, and when to stop using it: README.md, "Mainline
# kernel (self-built)".
set -euo pipefail

VERSION="${1:-}"
JOBS="${JOBS:-4}"
WORK="${WORK:-$HOME/src/kernel-mainline}"
MOK_KEY="$HOME/mok.key"
MOK_CRT="$HOME/mok.crt"

[ -n "$VERSION" ] || { echo "usage: ${0##*/} <version>   e.g. 7.2.3" >&2; exit 1; }
for f in "$MOK_KEY" "$MOK_CRT"; do
    [ -r "$f" ] || { echo "missing $f — Secure Boot needs it; see README 'MOK signing key'" >&2; exit 1; }
done

SERIES="v${VERSION%%.*}.x"
SRC="$WORK/linux-$VERSION"
mkdir -p "$WORK"

# 1. Fetch and verify. kernel.org's sha256sums.asc is the authority; a corrupt
#    tarball otherwise surfaces as a baffling compile error hours later.
cd "$WORK"
if [ ! -f "linux-$VERSION.tar.xz" ]; then
    curl -fL# -O "https://cdn.kernel.org/pub/linux/kernel/$SERIES/linux-$VERSION.tar.xz"
fi
want=$(curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/$SERIES/sha256sums.asc" \
       | awk -v f="linux-$VERSION.tar.xz" '$2 == f {print $1}')
got=$(sha256sum "linux-$VERSION.tar.xz" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "checksum mismatch or version not published" >&2; exit 1; }

[ -d "$SRC" ] || tar xf "linux-$VERSION.tar.xz"
cd "$SRC"

# 2. Seed from the running kernel, then strip what only Canonical can satisfy.
#    SYSTEM_TRUSTED_KEYS/SYSTEM_REVOCATION_KEYS point at cert files that exist
#    only inside Ubuntu's build tree; DEBUG_INFO costs an hour and gigabytes.
if [ ! -f .config ]; then
    cp "/boot/config-$(uname -r)" .config
    scripts/config --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS "" \
                   --disable DEBUG_INFO --disable DEBUG_INFO_BTF \
                   --disable DEBUG_INFO_BTF_MODULES --enable DEBUG_INFO_NONE
    make olddefconfig
fi

# 3. Build OUTSIDE the terminal's cgroup. Ghostty caps each tab at 6 GiB
#    (ghostty/config) and the vmlinux link peaks just under that, so building in
#    a tab gets the linker OOM-killed — everything in a tab also inherits
#    oom_score_adj=200, making it the kernel's preferred victim. Lower JOBS if
#    the link still dies; it is the memory peak, not the compiles.
systemd-run --user --scope --quiet -p MemoryHigh=infinity -p MemoryMax=infinity \
    nice -n 5 make -j"$JOBS" bindeb-pkg

# 4. Install. The postinst regenerates initramfs and GRUB on its own; the
#    -dbg and libc-dev packages are deliberately not installed.
cd "$WORK"
sudo dpkg -i "linux-image-${VERSION}_${VERSION}-1_amd64.deb" \
             "linux-headers-${VERSION}_${VERSION}-1_amd64.deb"

# 5. Sign, or Secure Boot refuses to boot it. sbsign cannot safely write over
#    the file it is reading, hence the temporary.
sudo sbsign --key "$MOK_KEY" --cert "$MOK_CRT" \
     --output "/tmp/vmlinuz-$VERSION.signed" "/boot/vmlinuz-$VERSION"
sudo mv "/tmp/vmlinuz-$VERSION.signed" "/boot/vmlinuz-$VERSION"
sudo sbverify --list "/boot/vmlinuz-$VERSION" | head -3

echo
echo "Installed and signed $VERSION. Reboot; GRUB defaults to the highest version."
echo "Check afterwards:  uname -r  and  cat /proc/sys/kernel/tainted  (expect 0)"
