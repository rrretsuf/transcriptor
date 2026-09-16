#!/bin/bash
# Build Transcriptor.app, install it into /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=.build/Transcriptor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Transcriptor" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/icon.icns "$APP/Contents/Resources/"

# A self-signed "Transcriptor Local Signing" identity keeps the Accessibility grant
# across rebuilds. Without one the app is ad-hoc signed and macOS asks again after each build.
IDENTITY="${SIGN_IDENTITY:-Transcriptor Local Signing}"
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY="-"
codesign --force --deep --sign "$IDENTITY" "$APP"

pkill -x Transcriptor 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Transcriptor.app
cp -R "$APP" /Applications/
open /Applications/Transcriptor.app
echo "Installed /Applications/Transcriptor.app (signed: $IDENTITY)"
