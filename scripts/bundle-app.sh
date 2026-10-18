#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT/App" -c debug -Xswiftc -warnings-as-errors
BIN="$(swift build --package-path "$ROOT/App" -c debug --show-bin-path)/QAWorkbench"
APP="$ROOT/build/QA Workbench.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/QAWorkbench"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>QAWorkbench</string>
  <key>CFBundleIdentifier</key>
  <string>com.qaworkbench.app</string>
  <key>CFBundleName</key>
  <string>QA Workbench</string>
  <key>CFBundleDisplayName</key>
  <string>QA Workbench</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>The workbench installs APKs you choose from Downloads onto the emulator.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>The workbench installs APKs you choose from Documents onto the emulator.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>The workbench installs APKs you choose from Desktop onto the emulator.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$APP"
echo "$APP"
