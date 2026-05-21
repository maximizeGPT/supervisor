#!/bin/bash
# build-app.sh — produce signed .app bundles for the v0.1.0 companion
# processes. Wraps the SwiftPM-built executables in minimal .app bundles
# with proper Info.plist + ad-hoc codesigning so macOS treats them as real
# apps (required for menu-bar status item + future notification posting).
#
# Output: build/SupervisorHeartbeat.app and build/SupervisorStatusBar.app.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"   # debug | release

echo "[build-app] swift build --configuration $CONFIG"
swift build --configuration "$CONFIG"

BIN_DIR=".build/arm64-apple-macosx/$CONFIG"
if [[ ! -d "$BIN_DIR" ]]; then
    # Fall back to whatever architecture SwiftPM emitted.
    BIN_DIR=$(dirname "$(find .build -name SupervisorHeartbeat -type f | head -1)")
fi
echo "[build-app] using bin dir: $BIN_DIR"

OUT_DIR="build"
mkdir -p "$OUT_DIR"

# ---- SupervisorHeartbeat.app ---------------------------------------------

HB_APP="$OUT_DIR/SupervisorHeartbeat.app"
rm -rf "$HB_APP"
mkdir -p "$HB_APP/Contents/MacOS"
mkdir -p "$HB_APP/Contents/Resources"

cat > "$HB_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>live.supervisor.heartbeat</string>
    <key>CFBundleName</key>
    <string>SupervisorHeartbeat</string>
    <key>CFBundleDisplayName</key>
    <string>Supervisor Heartbeat</string>
    <key>CFBundleExecutable</key>
    <string>SupervisorHeartbeat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
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

cp "$BIN_DIR/SupervisorHeartbeat" "$HB_APP/Contents/MacOS/SupervisorHeartbeat"
Scripts/sign-adhoc.sh "$HB_APP"

# ---- SupervisorStatusBar.app ---------------------------------------------

SB_APP="$OUT_DIR/SupervisorStatusBar.app"
rm -rf "$SB_APP"
mkdir -p "$SB_APP/Contents/MacOS"
mkdir -p "$SB_APP/Contents/Resources"

cat > "$SB_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>live.supervisor.statusbar</string>
    <key>CFBundleName</key>
    <string>SupervisorStatusBar</string>
    <key>CFBundleDisplayName</key>
    <string>Supervisor Status Bar</string>
    <key>CFBundleExecutable</key>
    <string>SupervisorStatusBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
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

cp "$BIN_DIR/SupervisorStatusBar" "$SB_APP/Contents/MacOS/SupervisorStatusBar"
Scripts/sign-adhoc.sh "$SB_APP"

echo
echo "[build-app] ✓ built:"
echo "    $HB_APP"
echo "    $SB_APP"
echo
echo "Run them like this:"
echo "    open $HB_APP    # menu-bar-less heartbeat"
echo "    open $SB_APP    # menu-bar status icon"
