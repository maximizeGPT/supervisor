#!/bin/bash
# notarize.sh — Developer ID sign + notarize + staple the release build.
#
# Run AFTER `Scripts/build-app.sh release`. Produces a notarized, stapled
# dist/Supervisor.zip that opens with NO Gatekeeper warning (a plain
# double-click), instead of the right-click -> Open dance an unsigned build
# needs. This is the distribution path for Supervisor — the Mac App Store is
# not an option (Supervisor needs to watch/inject/signal OTHER processes, which
# the App Sandbox forbids; default-entitlements.plist sets app-sandbox=false).
#
# Re-run this for every release: notarization covers a specific build, so a new
# .app needs a new notarization.
#
# One-time prerequisites on the build machine:
#   1. The "Developer ID Application: Mohammed Wasif (Q7HKTCTZXQ)" cert in the
#      login keychain (signing).
#   2. A notarytool credential profile named below, holding the Apple ID +
#      app-specific password + team id (the password lives in the Keychain, not
#      here):
#        xcrun notarytool store-credentials supervisor-notary \
#          --apple-id <your-apple-id> --team-id Q7HKTCTZXQ \
#          --password <app-specific-password>
#      (app-specific password: appleid.apple.com -> Sign-In and Security.)

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SUPERVISOR_SIGN_IDENTITY:-Developer ID Application: Mohammed Wasif (Q7HKTCTZXQ)}"
PROFILE="${SUPERVISOR_NOTARY_PROFILE:-supervisor-notary}"
ENT="Scripts/default-entitlements.plist"
APP="build/Supervisor.app"
ZIP="dist/Supervisor.zip"

[[ -d "$APP" ]] || { echo "[notarize] $APP missing — run Scripts/build-app.sh release first" >&2; exit 1; }

# Sign inside-out: the embedded companion binaries first, then the bundle.
# BOTH nested Mach-Os must be Developer-ID signed — build-app.sh embeds
# SupervisorHeartbeat AND SupervisorStatusBar (re-externalized this RC) in
# Contents/MacOS, and an ad-hoc-signed nested binary fails notarization.
# Hardened runtime (--options runtime) + a secure timestamp are both required
# for notarization.
echo "[notarize] signing nested SupervisorHeartbeat"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP/Contents/MacOS/SupervisorHeartbeat"
echo "[notarize] signing nested SupervisorStatusBar"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP/Contents/MacOS/SupervisorStatusBar"
echo "[notarize] signing Supervisor.app"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP"

echo "[notarize] verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "[notarize] packaging for submission"
mkdir -p dist
SUBMIT_ZIP="$(mktemp -d)/Supervisor-notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "[notarize] submitting to Apple notary (this takes a few minutes)"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

echo "[notarize] stapling the ticket to the app"
xcrun stapler staple "$APP"

echo "[notarize] re-zipping the stapled app -> $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "[notarize] Gatekeeper verdict:"
spctl -a -t exec -vvv "$APP" 2>&1 | sed 's/^/    /'
echo "[notarize] ✓ done — $ZIP is notarized + stapled (opens with no warning)"
