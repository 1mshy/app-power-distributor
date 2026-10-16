#!/bin/bash
# Builds "build/App Power Distributor.app" (with the apd CLI inside) from source.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="build/App Power Distributor.app"

swift build -c release --product AppPowerDistributor
swift build -c release --product apd
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AppPowerDistributor" "$BIN/apd" "$APP/Contents/MacOS/"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>App Power Distributor</string>
    <key>CFBundleDisplayName</key><string>App Power Distributor</string>
    <key>CFBundleIdentifier</key><string>com.1mshy.AppPowerDistributor</string>
    <key>CFBundleExecutable</key><string>AppPowerDistributor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. No sandbox — signalling other apps needs it off.
codesign --force --sign - "$APP/Contents/MacOS/apd"
codesign --force --sign - "$APP"
echo "Built $APP"
