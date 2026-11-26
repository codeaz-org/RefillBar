#!/bin/bash
# Builds RefillBar.app next to this script and opens it.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"
  exit 1
fi

APP="RefillBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary, so one build runs on both Apple Silicon and Intel Macs.
for arch in arm64 x86_64; do
  swiftc -O main.swift -target "$arch-apple-macos14.0" -o "$APP/Contents/MacOS/RefillBar-$arch" -framework Cocoa -framework WebKit
done
lipo -create "$APP/Contents/MacOS/RefillBar-arm64" "$APP/Contents/MacOS/RefillBar-x86_64" -output "$APP/Contents/MacOS/RefillBar"
rm "$APP/Contents/MacOS/RefillBar-arm64" "$APP/Contents/MacOS/RefillBar-x86_64"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>RefillBar</string>
  <key>CFBundleDisplayName</key><string>RefillBar</string>
  <key>CFBundleIdentifier</key><string>org.codeaz.refillbar</string>
  <key>CFBundleExecutable</key><string>RefillBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $(pwd)/$APP"
open "$APP"
