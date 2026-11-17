#!/bin/bash
# Builds Tabmap in release mode and wraps it in a double-clickable Tabmap.app.
# Usage: scripts/make-app.sh            (output: build/Tabmap.app)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Tabmap"

APP="build/Tabmap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tabmap"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will run it locally.
codesign --force --deep --sign - "$APP"

# Install over /Applications/Tabmap.app (what Spotlight opens) when we can.
if [ -w /Applications ]; then
    ditto "$APP" /Applications/Tabmap.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tabmap.app || true
    echo "Installed /Applications/Tabmap.app"
else
    echo "Skipped installing: /Applications is not writable"
fi

echo "Built $APP"
echo "Run it with: open $APP"
