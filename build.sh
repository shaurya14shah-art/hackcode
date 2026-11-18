#!/bin/bash
# Builds HackCode.app from the Swift package.
#   ./build.sh          release build → ./HackCode.app
#   ./build.sh debug    debug build (enables the HACKCODE_DEV_NVIDIA_API_KEY env fallback)
#   ./build.sh test     run the test suite (same as ./test.sh)
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" == "test" ]; then
    exec ./test.sh
fi

CONFIG="${1:-release}"
APP="HackCode.app"
echo "Building HackCode ($CONFIG)…"
swift build -c "$CONFIG" --product HackCode
BIN="$(swift build -c "$CONFIG" --show-bin-path)/HackCode"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HackCode"
[ -f HackCode.icns ] && cp HackCode.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HackCode</string>
    <key>CFBundleIdentifier</key><string>com.shaurya.HackCode</string>
    <key>CFBundleName</key><string>HackCode</string>
    <key>CFBundleDisplayName</key><string>HackCode</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.1</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Shaurya Shah.</string>
    <key>NSDesktopFolderUsageDescription</key><string>HackCode reads file sizes in Desktop only when you ask it to scan that folder.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>HackCode reads file sizes in Documents only when you ask it to scan that folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>HackCode reads file sizes in Downloads only when you ask it to scan that folder.</string>
    <key>NSAppleEventsUsageDescription</key><string>HackCode uses the macOS administrator prompt only when you authorize a firewall remediation.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime (no developer certificate required).
codesign --force --sign - --options runtime --timestamp=none "$APP" >/dev/null
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1)). Launch with: open $APP"
