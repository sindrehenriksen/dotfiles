#!/usr/bin/env bash
# Unprivileged half: fetch xremap and its GNOME extension. Pinned, because an
# input remapper silently changing behaviour under you is worse than an old one.
# Run setup-input.sh (with sudo) for the permissions half.
set -euo pipefail

XREMAP_VERSION=v0.15.12
EXT_UUID=xremap@k0kubun.com

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The gnome build is the one that talks to the Shell extension for the focused
# window; the plain build cannot do application-specific rules on Wayland.
curl -fsSL -o "$tmp/xremap.zip" \
    "https://github.com/xremap/xremap/releases/download/${XREMAP_VERSION}/xremap-linux-x86_64-gnome.zip"
unzip -oq "$tmp/xremap.zip" -d "$tmp"
mkdir -p ~/.local/bin
install -m755 "$tmp/xremap" ~/.local/bin/xremap

if [ ! -d "$HOME/.local/share/gnome-shell/extensions/$EXT_UUID" ]; then
    info=$(curl -fsSL "https://extensions.gnome.org/extension-info/?pk=5060&shell_version=46")
    url=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["download_url"])' <<<"$info")
    curl -fsSL -o "$tmp/ext.zip" "https://extensions.gnome.org${url}"
    gnome-extensions install --force "$tmp/ext.zip"
fi
gnome-extensions enable "$EXT_UUID" 2>/dev/null || \
    echo "note: enable $EXT_UUID after the next login — the Shell cannot see it until then"

echo "xremap $(~/.local/bin/xremap --version) installed."
