#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/.build/Wake Scenes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -g -target "$(uname -m)-apple-macosx14.0" Sources/*.swift -o "$APP/Contents/MacOS/WakeScenes" -framework AppKit -framework SwiftUI -framework AVFoundation -framework ServiceManagement -framework CryptoKit
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
