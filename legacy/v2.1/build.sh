#!/bin/bash
set -e

if [ "$1" == "test" ]; then
    echo "Running tests..."
    swiftc HackCodeTests.swift CommandExecutor.swift CommandValidator.swift ProcessManager.swift SecurityModels.swift TerminalModels.swift LLMService.swift RiskEngine.swift CorrelationEngine.swift SlashCommandRegistry.swift -o test_runner
    ./test_runner
    rm test_runner
    exit 0
fi

APP_NAME="HackCode"
BUNDLE_DIR="${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"

echo "Building ${APP_NAME}..."

mkdir -p "${MACOS_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

swiftc -framework SwiftUI \
       -framework AppKit \
       -framework Combine \
       HackCodeApp.swift \
       ContentView.swift \
       MatrixRainView.swift \
       LLMService.swift \
       CommandExecutor.swift \
       CommandValidator.swift \
       ProcessManager.swift \
       SecurityModels.swift \
       TerminalModels.swift \
       SlashCommandRegistry.swift \
       SlashCommandPaletteView.swift \
       SecurityDashboardView.swift \
       SecurityTerminalView.swift \
       SecuritySidebarView.swift \
       SecurityEngine.swift \
       SecurityEngineComponents.swift \
       CorrelationEngine.swift \
       RiskEngine.swift \
       SecurityAdapter.swift \
       MacSecurityAdapter.swift \
       SecretsAdapter.swift \
       DNSAdapter.swift \
       NetworkScanner.swift \
       NetworkScannerView.swift \
       NetworkTopologyView.swift \
       PortScanAdapter.swift \
       -o "${MACOS_DIR}/${APP_NAME}"

cat > "${BUNDLE_DIR}/Contents/Info.plist" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.shaurya.HackCode</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>keychain-access-groups</key>
    <array>
        <string>com.shaurya.HackCode</string>
    </array>
</dict>
</plist>
EOF2

if [ -f "HackCode.icns" ]; then
    cp HackCode.icns "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"
fi

echo "Build complete! You can run it with: open ${BUNDLE_DIR}"
