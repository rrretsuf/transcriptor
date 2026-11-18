#!/bin/bash
# ./build.sh       build Transcriptor.app, install it into /Applications and launch it
# ./build.sh dmg   build .build/Transcriptor.dmg for a release instead
set -euo pipefail
cd "$(dirname "$0")"

# One binary for Apple Silicon and Intel, running on macOS 13 and later. SwiftPM
# stamps the binary with the minimum version as its SDK version, and macOS then
# draws the app in the old design; stamping the real SDK keeps Liquid Glass on 26+.
MIN="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
SDK="$(xcrun --sdk macosx --show-sdk-version)"
FLAGS=(--arch arm64 --arch x86_64 -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN" -Xlinker "$SDK")
swift build -c release "${FLAGS[@]}"
BIN="$(swift build -c release "${FLAGS[@]}" --show-bin-path)"

APP=.build/Transcriptor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Transcriptor" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/icon.icns "$APP/Contents/Resources/"

# A self-signed "Transcriptor Local Signing" identity keeps the Accessibility grant
# across rebuilds and updates. Without one the app is ad-hoc signed and macOS asks
# again after each build.
IDENTITY="${SIGN_IDENTITY:-Transcriptor Local Signing}"
security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY="-"
codesign --force --deep --sign "$IDENTITY" "$APP"

if [ "${1:-}" = dmg ]; then
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f .build/Transcriptor.dmg
    hdiutil create -quiet -volname Transcriptor -srcfolder "$STAGE" -format UDZO .build/Transcriptor.dmg
    rm -rf "$STAGE"
    echo "Built .build/Transcriptor.dmg (signed: $IDENTITY)"
    exit
fi

pkill -x Transcriptor 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Transcriptor.app
cp -R "$APP" /Applications/
open /Applications/Transcriptor.app
echo "Installed /Applications/Transcriptor.app (signed: $IDENTITY)"
