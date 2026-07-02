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

# ---- Version stamp ------------------------------------------------------
# Was hardcoded CFBundleShortVersionString=0.1.0 / CFBundleVersion=1 forever,
# so every build across the whole history was indistinguishable once
# installed. Derive both from git:
#   CFBundleShortVersionString ← `git describe --tags` (nearest tag, minus the
#                                 leading v), reduced to the semver core so it
#                                 stays a valid dotted-numeric "marketing"
#                                 version; falls back to VERSION_FALLBACK.
#   CFBundleVersion            ← `git rev-list --count HEAD` (monotonic build
#                                 number); falls back to 1.
# Robust when git or tags are absent (fresh clone with no tags, tarball build).
VERSION_FALLBACK="0.3.0"
if GIT_DESCRIBE=$(git describe --tags --always --dirty 2>/dev/null); then
    SHORT_VERSION="${GIT_DESCRIBE#v}"          # v0.3.0 -> 0.3.0
else
    GIT_DESCRIBE=""
    SHORT_VERSION="$VERSION_FALLBACK"
fi
# Marketing version = semver core, before any `-<N>-g<sha>` / `-dirty` suffix.
MARKETING_VERSION="${SHORT_VERSION%%-*}"
# If describe returned only a bare SHA (repo never tagged), that isn't a
# valid dotted version — fall back so CFBundleShortVersionString stays legal.
if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    MARKETING_VERSION="$VERSION_FALLBACK"
fi
if ! BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null); then
    BUILD_NUMBER=1
fi
echo "[build-app] version: $MARKETING_VERSION (build $BUILD_NUMBER; describe: ${GIT_DESCRIBE:-none})"

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

    # All three bundles share the same AppIcon.icns — copied in, then
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
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
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

# Bundle the generic default PRINCIPLES.md so a fresh install ships with
# working judgment for answering engineering questions (the QuestionAnswerer
# and Dispatcher both load it). A user overrides it by dropping their own at
# ~/Library/Application Support/Supervisor/PRINCIPLES.md — the loader prefers
# that override over this bundled copy. Copied before signing so the
# signature covers it. Only the main app needs it (not the companions).
cp "Resources/PRINCIPLES.default.md" "$APP_APP/Contents/Resources/PRINCIPLES.md"

# ---- Sign all three -----------------------------------------------------

Scripts/sign-adhoc.sh "$HB_APP"
Scripts/sign-adhoc.sh "$SB_APP"
Scripts/sign-adhoc.sh "$APP_APP"

# Record the resolved version so the release/notarize step can name the DMG
# without re-deriving it (Scripts/notarize.sh names the DMG via DMG_NAME).
# See docs/RELEASE-CHECKLIST.md for the versioned-DMG + stable-copy step.
printf '%s\n' "$MARKETING_VERSION" > "$OUT_DIR/VERSION"

echo
echo "[build-app] ✓ built and signed $MARKETING_VERSION (build $BUILD_NUMBER):"
echo "    $APP_APP   ← main (LSUIElement; menu-bar-app shape)"
echo "    $HB_APP    ← heartbeat companion (also embedded inside Supervisor.app)"
echo "    $SB_APP    ← status-bar companion"
echo
echo "To package a versioned, notarized DMG for release (keeps the stable"
echo "Supervisor.dmg the README download URL points at):"
echo "    DMG_NAME=\"Supervisor-$MARKETING_VERSION\" Scripts/notarize.sh"
echo "    cp \"dist/Supervisor-$MARKETING_VERSION.dmg\" dist/Supervisor.dmg"
echo
echo "First-run flow:"
echo "    open $APP_APP        # presents onboarding window"
echo "    open $SB_APP         # starts the menu-bar status icon"
echo
echo "Reset onboarding (delete the Keychain key + state):"
echo "    security delete-generic-password -s live.supervisor.api"
echo "    rm -rf ~/Library/Application\ Support/Supervisor"
echo "    rm -rf ~/Library/Logs/Supervisor"
