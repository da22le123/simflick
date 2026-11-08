#!/bin/sh
# Builds the SwiftUI demo for arm64 simulators into build/SimflickDemo.app (no Xcode project needed).
set -e
cd "$(dirname "$0")"
APP=build/SimflickDemo.app
rm -rf "$APP" && mkdir -p "$APP"
swiftc -parse-as-library -target arm64-apple-ios17.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -O App.swift -o "$APP/SimflickDemo"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.simflick.demo</string>
  <key>CFBundleExecutable</key><string>SimflickDemo</string>
  <key>CFBundleName</key><string>SimflickDemo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UILaunchScreen</key><dict/>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign -s - "$APP" >/dev/null 2>&1
echo "built $APP"
