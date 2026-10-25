#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Meridian
APP="dist/Meridian.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Meridian "$APP/Contents/MacOS/Meridian"
cp App/Info.plist "$APP/Contents/Info.plist"
cp Scripts/build-guest-image.py Guest/meridian-agent.py Guest/guest-init.sh "$APP/Contents/Resources/"
codesign --force --sign - --entitlements App/Meridian.entitlements "$APP"
echo "built $APP"
