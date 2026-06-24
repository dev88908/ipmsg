#!/bin/bash
# Build IPMsgMac and wrap the binary into a distributable .app bundle.
# A bundle (with Info.plist) is required so macOS shows the Local Network
# permission prompt — without it, UDP broadcast discovery is silently blocked.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/IPMsgMac"
APP="build/IP Messenger.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/IPMsgMac"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>IP Messenger</string>
    <key>CFBundleDisplayName</key>     <string>IP Messenger</string>
    <key>CFBundleIdentifier</key>      <string>org.ipmsg.mac</string>
    <key>CFBundleExecutable</key>      <string>IPMsgMac</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>IP Messenger discovers and exchanges messages and files with other devices on your local network.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Local Network entitlement is honoured on recent macOS.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Built: $APP"
echo "    open \"$APP\""
