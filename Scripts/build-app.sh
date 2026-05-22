#!/bin/bash
# build-app.sh — produce signed .app bundles for the v0.1.0 executables.
# Wraps the SwiftPM-built binaries in minimal .app bundles with proper
# Info.plist + ad-hoc codesigning. Output in build/:
#
#   build/Supervisor.app              ← the main app
#   build/SupervisorHeartbeat.app     ← companion (also embedded inside
#                                       Supervisor.app/Contents/MacOS/ so
#                                       the running app can find it)
#   build/SupervisorStatusBar.app     ← companion
#
# All three signed via Scripts/sign-adhoc.sh, which asserts the
# CodeDirectory Identifier matches CFBundleIdentifier per Spike 2's
# finding. Sign failure → script failure.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"   # debug | release

echo "[build-app] swift build --configuration $CONFIG"
swift build --configuration "$CONFIG"

BIN_DIR=".build/arm64-apple-macosx/$CONFIG"
if [[ ! -d "$BIN_DIR" ]]; then
    BIN_DIR=$(dirname "$(find .build -name SupervisorHeartbeat -type f | head -1)")
fi
echo "[build-app] using bin dir: $BIN_DIR"

OUT_DIR="build"
mkdir -p "$OUT_DIR"

# ---- Generic bundler helper ---------------------------------------------

make_bundle() {
    local app_name=$1
    local bundle_id=$2
    local display_name=$3
    local source_bin=$4
    local out_app="$OUT_DIR/${app_name}.app"

    rm -rf "$out_app"
    mkdir -p "$out_app/Contents/MacOS"
    mkdir -p "$out_app/Contents/Resources"

    cat > "$out_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundleDisplayName</key>
    <string>${display_name}</string>
    <key>CFBundleExecutable</key>
    <string>${app_name}</string>
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
    cp "$source_bin" "$out_app/Contents/MacOS/${app_name}"
    # Log to stderr; print the bundle path on stdout so callers can
    # capture it via $(make_bundle ...) cleanly without trapping log lines.
    echo "[build-app] $out_app populated" >&2
    echo "$out_app"
}

# ---- Three bundles ------------------------------------------------------

HB_APP=$(make_bundle SupervisorHeartbeat live.supervisor.heartbeat "Supervisor Heartbeat" "$BIN_DIR/SupervisorHeartbeat")
SB_APP=$(make_bundle SupervisorStatusBar live.supervisor.statusbar "Supervisor Status Bar" "$BIN_DIR/SupervisorStatusBar")
APP_APP=$(make_bundle Supervisor          live.supervisor.app       "Supervisor"            "$BIN_DIR/Supervisor")

# Embed the heartbeat binary inside Supervisor.app so the running app can
# spawn it without depending on its sibling .app being installed.
cp "$BIN_DIR/SupervisorHeartbeat" "$APP_APP/Contents/MacOS/SupervisorHeartbeat"

# ---- Sign all three -----------------------------------------------------

Scripts/sign-adhoc.sh "$HB_APP"
Scripts/sign-adhoc.sh "$SB_APP"
Scripts/sign-adhoc.sh "$APP_APP"

echo
echo "[build-app] ✓ built and signed:"
echo "    $APP_APP   ← main (LSUIElement; menu-bar-app shape)"
echo "    $HB_APP    ← heartbeat companion (also embedded inside Supervisor.app)"
echo "    $SB_APP    ← status-bar companion"
echo
echo "First-run flow:"
echo "    open $APP_APP        # presents onboarding window"
echo "    open $SB_APP         # starts the menu-bar status icon"
echo
echo "Reset onboarding (delete the Keychain key + state):"
echo "    security delete-generic-password -s live.supervisor.api"
echo "    rm -rf ~/Library/Application\ Support/Supervisor"
echo "    rm -rf ~/Library/Logs/Supervisor"
