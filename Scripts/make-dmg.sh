#!/bin/bash
# make-dmg.sh - Developer ID sign + package + notarize + staple a distributable
# .dmg (the public artifact format).
#
# Run AFTER `Scripts/build-app.sh release`. Produces a notarized, stapled
# dist/Supervisor.dmg that mounts and opens with NO Gatekeeper warning - a plain
# double-click, then drag Supervisor.app onto the bundled Applications symlink to
# install. This is the public distribution path for Supervisor - the Mac App
# Store is not an option (Supervisor needs to watch/inject/signal OTHER
# processes, which the App Sandbox forbids; default-entitlements.plist sets
# app-sandbox=false).
#
# For a fully clean Gatekeeper pass, BOTH the .app AND the .dmg must be Developer
# ID-signed + notarized + stapled. This script signs the app inside-out (same
# conventions as Scripts/notarize.sh), builds the .dmg, signs the .dmg, then
# notarizes + staples the .dmg. Re-signing the app here is idempotent, so this
# script is self-contained whether or not notarize.sh ran first.
#
# Re-run this for every release: notarization covers a specific build, so a new
# .app/.dmg needs a new notarization.
#
# DRY MODE - validate mechanics without uploading to Apple:
#   bash Scripts/make-dmg.sh --no-notarize
#   SUPERVISOR_SKIP_NOTARIZE=1 bash Scripts/make-dmg.sh
# Either form runs steps 1-5 + 7 (sign app + stage + build + sign dmg + local
# Gatekeeper check) but SKIPS step 6 (notarytool submit + staple). The default
# (no flag) runs the full notarized flow.
#
# One-time prerequisites on the build machine (same as notarize.sh):
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
DMG="dist/Supervisor.dmg"
VOLNAME="Supervisor"

# Parse args / env for the dry (no-notarize) mode.
SKIP_NOTARIZE="${SUPERVISOR_SKIP_NOTARIZE:-0}"
for arg in "$@"; do
  case "$arg" in
    --no-notarize) SKIP_NOTARIZE=1 ;;
    *) echo "[make-dmg] unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -d "$APP" ]] || { echo "[make-dmg] $APP missing - run Scripts/build-app.sh release first" >&2; exit 1; }

# --- 1+2. Sign the app inside-out (idempotent if notarize.sh already ran) ----
# The embedded companion binaries first, then the bundle. BOTH nested Mach-Os
# must be Developer-ID signed — build-app.sh embeds SupervisorHeartbeat AND
# SupervisorStatusBar (re-externalized this RC) in Contents/MacOS, and an
# ad-hoc-signed nested binary fails notarization. Hardened runtime
# (--options runtime) + a secure timestamp are both required for notarization.
echo "[make-dmg] signing nested SupervisorHeartbeat"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP/Contents/MacOS/SupervisorHeartbeat"
echo "[make-dmg] signing nested SupervisorStatusBar"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP/Contents/MacOS/SupervisorStatusBar"
echo "[make-dmg] signing Supervisor.app"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$IDENTITY" "$APP"

echo "[make-dmg] verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 3. Stage a dmg source dir: the app + a drag-to-install Applications link -
echo "[make-dmg] staging dmg source"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# --- 4. Create the compressed dmg --------------------------------------------
echo "[make-dmg] creating $DMG"
mkdir -p dist
rm -f "$DMG"
hdiutil create -fs HFS+ -format UDZO -volname "$VOLNAME" \
  -srcfolder "$STAGE" -ov "$DMG"

# Staging dir is no longer needed once the dmg image exists.
rm -rf "$STAGE"

# --- 5. Sign the dmg itself --------------------------------------------------
echo "[make-dmg] signing $DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

# --- 6. Notarize + staple the dmg (skipped in dry mode) ----------------------
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "[make-dmg] SUPERVISOR_SKIP_NOTARIZE / --no-notarize set - skipping notarytool submit + staple"
else
  echo "[make-dmg] submitting $DMG to Apple notary (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

  echo "[make-dmg] stapling the ticket to $DMG"
  xcrun stapler staple "$DMG"
fi

# --- 7. Local Gatekeeper verdict on the dmg ----------------------------------
# spctl exits non-zero when the dmg is not yet notarized (expected in dry mode),
# so capture its status without letting pipefail abort the script.
echo "[make-dmg] Gatekeeper verdict (dmg):"
SPCTL_OUT="$(spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1)" && SPCTL_RC=0 || SPCTL_RC=$?
echo "$SPCTL_OUT" | sed 's/^/    /'
if [[ "$SPCTL_RC" != "0" && "$SKIP_NOTARIZE" == "1" ]]; then
  echo "    (spctl rejected with status $SPCTL_RC - expected in dry mode; the dmg is signed but not yet notarized)"
fi

# --- Done --------------------------------------------------------------------
DMG_SIZE="$(du -h "$DMG" | cut -f1)"
echo
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "[make-dmg] ✓ dry build done - $DMG ($DMG_SIZE) is signed but NOT notarized."
  echo "    Re-run without --no-notarize (with the Developer ID + notary profile)"
  echo "    to produce the public, warning-free artifact."
else
  echo "[make-dmg] ✓ done - $DMG ($DMG_SIZE) is notarized + stapled (opens with no warning)."
fi
echo "    Install: open $DMG, then drag Supervisor.app onto Applications."
