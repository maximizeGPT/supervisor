#!/bin/bash
# Build a minimal unsigned NotifySpike.app bundle for the Phase 0 notification probe.
# UNUserNotificationCenter requires a CFBundleIdentifier; a bare swift script
# returns nil for Bundle.main.bundleIdentifier and refuses to operate.
set -euo pipefail

cd "$(dirname "$0")"

APP="NotifySpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>live.supervisor.notifyspike</string>
  <key>CFBundleName</key>
  <string>NotifySpike</string>
  <key>CFBundleDisplayName</key>
  <string>Supervisor Notify Spike</string>
  <key>CFBundleExecutable</key>
  <string>NotifySpike</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

echo "compiling..."
swiftc notify_spike.swift -o "$APP/Contents/MacOS/NotifySpike"

echo "verifying signature state (we want unsigned):"
codesign -dv "$APP" 2>&1 || true

echo
echo "built: $APP"
ls -la "$APP/Contents/MacOS/"
echo
echo "run with: open -W $APP   (or directly: ./$APP/Contents/MacOS/NotifySpike)"
