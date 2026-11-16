#!/bin/zsh
# Builds SyncSpeakers.app (and SyncSpeakers.zip to copy to other Macs).
# Usage: ./build.sh && open SyncSpeakers.app
set -euo pipefail
cd "$(dirname "$0")"
APP=SyncSpeakers.app
rm -rf "$APP" SyncSpeakers.zip
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos14.4 \
  -framework SwiftUI -framework CoreAudio -framework AudioToolbox -framework AppKit -framework Network \
  Sources/*.swift -o "$APP/Contents/MacOS/SyncSpeakers"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SyncSpeakers</string>
  <key>CFBundleIdentifier</key><string>com.prakash.syncspeakers</string>
  <key>CFBundleExecutable</key><string>SyncSpeakers</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>SyncSpeakers plays this Mac's sound on all your speakers and Macs at once.</string>
  <key>NSLocalNetworkUsageDescription</key><string>SyncSpeakers finds your other Macs on the Wi-Fi and streams sound to them.</string>
  <key>NSBonjourServices</key><array><string>_syncspk._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" SyncSpeakers.zip
echo "Built $PWD/$APP"
