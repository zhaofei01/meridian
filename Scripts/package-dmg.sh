#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d dist/Meridian.app ]]; then
  Scripts/package-app.sh
fi
STAGE="dist/dmg-root"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R dist/Meridian.app "$STAGE/Meridian.app"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Meridian.dmg
hdiutil create -volname Meridian -srcfolder "$STAGE" -ov -format UDZO dist/Meridian.dmg
echo "built dist/Meridian.dmg"
