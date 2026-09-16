#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
rm -rf Transcriber.app
mkdir -p Transcriber.app/Contents/MacOS Transcriber.app/Contents/Resources
cp "$BIN/Transcriber" Transcriber.app/Contents/MacOS/
cp Resources/Info.plist Transcriber.app/Contents/
cp Resources/icon.icns Resources/trayTemplate.png Resources/trayTemplate@2x.png \
   Resources/trayActiveTemplate.png Resources/trayActiveTemplate@2x.png \
   Transcriber.app/Contents/Resources/
codesign --force --deep --sign "Transcriber Local Signing" Transcriber.app
echo "Built $(pwd)/Transcriber.app"
