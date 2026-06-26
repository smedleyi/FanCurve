#!/bin/bash
# Rebuild FanCurve and update the .app bundle in place
set -e
cd "$(dirname "$0")"

echo "→ Building…"
swift package clean
swift build -c release

echo "→ Copying binary…"
cp .build/arm64-apple-macosx/release/FanCurve FanCurve.app/Contents/MacOS/FanCurve

echo "→ Copying icon…"
cp Resources/AppIcon.icns FanCurve.app/Contents/Resources/AppIcon.icns

echo "→ Signing…"
codesign --force --deep --sign - FanCurve.app

# Also update installed copy if present
if [ -d "$HOME/Applications/FanCurve.app" ]; then
    echo "→ Updating ~/Applications/FanCurve.app…"
    cp FanCurve.app/Contents/MacOS/FanCurve "$HOME/Applications/FanCurve.app/Contents/MacOS/FanCurve"
    cp Resources/AppIcon.icns "$HOME/Applications/FanCurve.app/Contents/Resources/AppIcon.icns"
    codesign --force --deep --sign - "$HOME/Applications/FanCurve.app"
fi

echo "→ Restarting…"
pkill -9 FanCurve 2>/dev/null || true
sleep 0.5
open "${HOME}/Applications/FanCurve.app" 2>/dev/null || open FanCurve.app

echo "✓ Done."
