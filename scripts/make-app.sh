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

if [ -n "${TABMAP_SIGN_IDENTITY:-}" ] && [ -n "${TABMAP_TEAM_ID:-}" ] && [ -n "${TABMAP_PROVISIONING_PROFILE:-}" ]; then
    # Signed with an Apple Developer ID and a provisioning profile that carries Apple's
    # web-browser passkey entitlement: WebKit then handles passkeys (iCloud Keychain, security
    # keys, phones) itself. See README "Passwords and passkeys".
    cp "$TABMAP_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
    ENTITLEMENTS="$(mktemp -t tabmap-entitlements).plist"
    cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>${TABMAP_TEAM_ID}.${BUNDLE_ID}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>${TABMAP_TEAM_ID}</string>
    <key>com.apple.developer.web-browser.public-key-credential</key>
    <true/>
</dict>
</plist>
PLIST
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --sign "$TABMAP_SIGN_IDENTITY" "$APP"
    rm -f "$ENTITLEMENTS"
else
    # Ad-hoc signature so macOS will run it locally.
    codesign --force --deep --sign - "$APP"
fi

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
