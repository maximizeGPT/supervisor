#!/bin/bash
# build-app.sh — produce signed .app bundles for the Supervisor executables.
# Wraps the SwiftPM-built binaries in minimal .app bundles with proper
# Info.plist + ad-hoc codesigning. Output in build/:
#
#   build/Supervisor.app              ← the main app (owns the menu-bar
#                                       status item in-process)
#   build/SupervisorHeartbeat.app     ← companion (also embedded inside
#                                       Supervisor.app/Contents/MacOS/ so
#                                       the running app can find it)
#
# Both signed via Scripts/sign-adhoc.sh, which asserts the CodeDirectory
# Identifier matches CFBundleIdentifier per Spike 2's finding. Sign
# failure → script failure.

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"   # debug | release

echo "[build-app] swift build --configuration $CONFIG"
swift build --configuration "$CONFIG"

# Regenerate AppIcon.icns from the 1024px brand master if stale. This
# MUST run before any sign-adhoc.sh call — otherwise the codesign
# signature won't cover the embedded icns and Gatekeeper (or its
# unsigned-dev-build equivalent on first launch) will reject the bundle.
# make-icns.sh is a no-op when the icns is already fresh, so calling it
# every build is cheap.
echo "[build-app] regenerating app icon"
Scripts/make-icns.sh

BIN_DIR=".build/arm64-apple-macosx/$CONFIG"
if [[ ! -d "$BIN_DIR" ]]; then
    BIN_DIR=$(dirname "$(find .build -name SupervisorHeartbeat -type f | head -1)")
fi
echo "[build-app] using bin dir: $BIN_DIR"

OUT_DIR="build"
mkdir -p "$OUT_DIR"
ICNS_SRC="branding/AppIcon.icns"

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

    # Both bundles share the same AppIcon.icns — copied in, then
    # referenced from Info.plist via CFBundleIconFile. The .icns lives
    # in branding/ so the source bundle layout stays icon-free; the build
    # step injects it. Done before signing (see Scripts/make-icns.sh
    # for the pre-sign ordering rationale).
    cp "$ICNS_SRC" "$out_app/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>4</string>
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

# ---- Two bundles --------------------------------------------------------

HB_APP=$(make_bundle SupervisorHeartbeat live.supervisor.heartbeat "Supervisor Heartbeat" "$BIN_DIR/SupervisorHeartbeat")
APP_APP=$(make_bundle Supervisor          live.supervisor.app       "Supervisor"            "$BIN_DIR/Supervisor")

# Embed the companion binaries inside Supervisor.app so the running app can
# spawn them without depending on their sibling .app being installed. Both are
# located via Bundle.main (Contents/MacOS/<name>) by startHeartbeat /
# startStatusBar.
cp "$BIN_DIR/SupervisorHeartbeat" "$APP_APP/Contents/MacOS/SupervisorHeartbeat"
# Menu-bar HEALTH icon is an out-of-process companion again (a v0.3.0 RC folded
# it into the main app, which broke honest health — an in-process NSStatusItem
# can't survive a crash or report a hang). SupervisorStatusBar reads the
# heartbeat and drives red/amber/green; embed its binary so the app can spawn it.
cp "$BIN_DIR/SupervisorStatusBar" "$APP_APP/Contents/MacOS/SupervisorStatusBar"

# SwiftPM resource bundle for the status-bar companion's branded icon. The
# companion resolves this bundle by hand (non-trapping: it probes next to its
# binary for dev runs and Contents/Resources/ for this packaged layout) and
# degrades to an SF Symbol when the bundle is absent — so this copy is
# optional, hence the existence guard instead of a hard cp failure. Copied
# pre-sign (same step as AppIcon.icns) so the signature covers it.
STATUSBAR_BUNDLE="$BIN_DIR/Supervisor_SupervisorStatusBar.bundle"
if [[ -d "$STATUSBAR_BUNDLE" ]]; then
    mkdir -p "$APP_APP/Contents/Resources"
    cp -R "$STATUSBAR_BUNDLE" "$APP_APP/Contents/Resources/"
    echo "[build-app] embedded status-bar resource bundle in $APP_APP/Contents/Resources/" >&2
else
    echo "[build-app] WARNING: $STATUSBAR_BUNDLE not found — branded status icon will fall back to SF Symbols" >&2
fi

# SwiftPM resource bundle for SupervisorUI (onboarding wordmark). Same class of
# bug as the status-bar bundle above: the UI code resolves it non-trapping and
# degrades to a text wordmark when absent, so the copy is optional — but
# without it every packaged build shows the fallback. Copied pre-sign.
UI_BUNDLE="$BIN_DIR/Supervisor_SupervisorUI.bundle"
if [[ -d "$UI_BUNDLE" ]]; then
    mkdir -p "$APP_APP/Contents/Resources"
    cp -R "$UI_BUNDLE" "$APP_APP/Contents/Resources/"
    echo "[build-app] embedded SupervisorUI resource bundle in $APP_APP/Contents/Resources/" >&2
else
    echo "[build-app] WARNING: $UI_BUNDLE not found — onboarding wordmark will fall back to text" >&2
fi

# Menu-bar glyph PNGs. The out-of-process SupervisorStatusBar loads its branded
# icon from the SPM resource bundle embedded above and falls back to an SF
# Symbol when that isn't present, so these Contents/Resources copies are a
# belt-and-suspenders for any code path that still reads Bundle.main. Copied
# pre-sign (same step as AppIcon.icns) so the signature covers them.
cp "branding/StatusBarIcon.png"    "$APP_APP/Contents/Resources/StatusBarIcon.png"
cp "branding/StatusBarIcon@2x.png" "$APP_APP/Contents/Resources/StatusBarIcon@2x.png"

# Generic default PRINCIPLES.md: the operating manual the triage / dispatcher /
# answerer read. Bundled as the fallback so the answer + dispatch features work
# on a fresh install (the app loads it via Bundle.main only when the user has
# not placed their own copy in Application Support, which always wins). This is
# the GENERIC default in branding/, not anyone's personal manual. Copied pre-
# sign (same step as the icons) so the signature covers it.
cp "branding/PRINCIPLES.default.md" "$APP_APP/Contents/Resources/PRINCIPLES.md"

# ---- Sign both ----------------------------------------------------------

Scripts/sign-adhoc.sh "$HB_APP"
Scripts/sign-adhoc.sh "$APP_APP"

echo
echo "[build-app] ✓ built and signed:"
echo "    $APP_APP   ← main (LSUIElement; menu-bar-app shape; owns the status item)"
echo "    $HB_APP    ← heartbeat companion (also embedded inside Supervisor.app)"
echo
echo "First-run flow:"
echo "    open $APP_APP        # presents onboarding; the menu-bar icon"
echo "                          # appears once the app enters its running state"
echo
echo "Reset onboarding (delete the Keychain key + state):"
echo "    security delete-generic-password -s live.supervisor.api"
echo "    rm -rf ~/Library/Application\ Support/Supervisor"
echo "    rm -rf ~/Library/Logs/Supervisor"
