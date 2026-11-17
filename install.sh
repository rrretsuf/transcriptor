#!/bin/bash
# Installs the latest Transcriptor release on macOS:
#   curl -fsSL https://raw.githubusercontent.com/rrretsuf/transcriptor/main/install.sh | bash
# Your transcriptions and settings are never touched; they live outside the app.
set -euo pipefail

RELEASES=https://github.com/rrretsuf/transcriptor/releases/latest

if [ "$(uname)" != Darwin ]; then
    echo "This installer is for macOS. Windows and Linux downloads: $RELEASES"
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
    echo "Transcriptor needs macOS 15 or later. This Mac runs macOS $(sw_vers -productVersion)."
    exit 1
fi

TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mount" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "Downloading Transcriptor…"
curl -fL --progress-bar -o "$TMP/Transcriptor.dmg" "$RELEASES/download/Transcriptor.dmg"
hdiutil attach "$TMP/Transcriptor.dmg" -nobrowse -quiet -mountpoint "$TMP/mount"

pkill -x Transcriptor 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Transcriptor.app
cp -R "$TMP/mount/Transcriptor.app" /Applications/
open /Applications/Transcriptor.app
echo "Transcriptor is installed in /Applications and running in your menu bar."
