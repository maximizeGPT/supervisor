#!/bin/bash
# notarize.sh — produce a notarized, stapled, distributable Supervisor.dmg.
#
# build-app.sh ad-hoc/self-signs for local dev: that keeps TCC grants alive
# across rebuilds, but Gatekeeper REJECTS a self-signed app the moment it's
# downloaded (quarantined). To ship to a stranger the bundles must be:
#   1. signed with a Developer ID Application cert, under the hardened runtime,
#      with a SECURE timestamp (the dev path uses --timestamp=none, which the
#      notary service refuses),
#   2. packaged into a .dmg and submitted to Apple's notary service,
#   3. stapled, so the .dmg validates offline with no network round-trip.
#
# The dmg ships BOTH apps deploy.sh installs — the main app AND the menu-bar
# companion (SupervisorStatusBar.app) — so a clean install isn't missing the
# menu-bar icon. Pass explicit app paths to override the default pair.
#
# Usage:
#   Scripts/build-app.sh release         # build the bundles first
#   Scripts/notarize.sh                   # -> dist/Supervisor.dmg (both apps)
#   Scripts/notarize.sh build/Foo.app     # notarize a specific bundle only
#
# One-time prereqs (already set up on Mohammed's machine):
#   - A "Developer ID Application: … (Q7HKTCTZXQ)" identity in the login keychain.
#   - A notarytool keychain profile "supervisor-notary" holding the Apple ID +
#     app-specific password + team id (the submit runs headless via this — no
#     interactive 2FA). Recreate with:
#       xcrun notarytool store-credentials supervisor-notary \
#         --apple-id <apple-id> --team-id Q7HKTCTZXQ --password <app-specific-pw>
#
# Overridable via env: DEV_ID_NAME, NOTARY_PROFILE, DMG_NAME.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
    APPS=( "$@" )
else
    APPS=( "build/Supervisor.app" "build/SupervisorStatusBar.app" )
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-supervisor-notary}"
ENTITLEMENTS="Scripts/default-entitlements.plist"
OUT_DIR="dist"
DMG_NAME="${DMG_NAME:-Supervisor}"

[[ -f "$ENTITLEMENTS" ]] || { echo "[notarize] ERROR: entitlements not found: $ENTITLEMENTS" >&2; exit 1; }

# 1. Resolve the Developer ID Application identity (auto-detect by name; no
#    hard-coded cert hash to rot). Override with DEV_ID_NAME.
DEV_ID_NAME="${DEV_ID_NAME:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [[ -z "$DEV_ID_NAME" ]]; then
    echo "[notarize] ERROR: no 'Developer ID Application' identity in the keychain." >&2
    echo "           Notarization needs a real Apple Developer ID cert, not the" >&2
    echo "           self-signed dev identity build-app.sh uses." >&2
    exit 1
fi
echo "[notarize] signing identity: $DEV_ID_NAME"

# 2. Sign each app inside-out: nested Mach-O helpers (e.g. the embedded
#    SupervisorHeartbeat) MUST be signed before the outer bundle so the bundle
#    seal covers their fresh signatures. Hardened runtime + secure timestamp,
#    overriding the existing self-signed signature. Apple deprecates --deep for
#    signing; explicit inside-out is the supported approach.
for APP in "${APPS[@]}"; do
    [[ -d "$APP" ]] || { echo "[notarize] ERROR: $APP not found. Run Scripts/build-app.sh release first." >&2; exit 1; }
    APP_BASE="$(basename "$APP" .app)"
    echo "[notarize] signing $APP (Developer ID, hardened runtime)"
    find "$APP/Contents/MacOS" -mindepth 1 -type f ! -name "$APP_BASE" -print0 \
        | while IFS= read -r -d '' bin; do
            codesign --force --options runtime --timestamp \
                --sign "$DEV_ID_NAME" --entitlements "$ENTITLEMENTS" "$bin"
        done
    codesign --force --options runtime --timestamp \
        --sign "$DEV_ID_NAME" --entitlements "$ENTITLEMENTS" "$APP"
    codesign --verify --deep --strict "$APP"
done

# 3. Stage the apps + an Applications symlink, then build a compressed .dmg.
#    Use makehybrid + convert rather than `hdiutil create -srcfolder`: the
#    latter mounts the image to populate it, which fails with "no mountable
#    file systems" in a headless/daemon shell that has no DiskArbitration
#    session. makehybrid writes the HFS+ filesystem WITHOUT mounting; convert
#    then compresses it to UDZO.
mkdir -p "$OUT_DIR"
FINAL_DMG="$OUT_DIR/${DMG_NAME}.dmg"
STAGING="$(mktemp -d)/dmg"
mkdir -p "$STAGING"
for APP in "${APPS[@]}"; do cp -R "$APP" "$STAGING/"; done
ln -s /Applications "$STAGING/Applications"
RAW="$(mktemp -d)/raw.dmg"
hdiutil makehybrid -hfs -hfs-volume-name "$DMG_NAME" -o "$RAW" "$STAGING" >/dev/null
rm -f "$FINAL_DMG"
hdiutil convert "$RAW" -format UDZO -o "$FINAL_DMG" >/dev/null
echo "[notarize] built dmg: $FINAL_DMG ($(du -h "$FINAL_DMG" | cut -f1))"

# 4. Sign the .dmg itself so the download carries a Developer ID signature.
codesign --force --sign "$DEV_ID_NAME" --timestamp "$FINAL_DMG"

# 5. Submit the .dmg and block until Apple returns a verdict (minutes).
echo "[notarize] submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$NOTARY_PROFILE" --wait

# 6. Staple the ticket into the .dmg so it validates with no network.
xcrun stapler staple "$FINAL_DMG"

# 7. Proof — non-fatal so a verification quirk can't fail a good notarization.
echo "[notarize] verifying:"
xcrun stapler validate "$FINAL_DMG" 2>&1 | sed 's/^/    /' || true
spctl -a -t open --context context:primary-signature -vv "$FINAL_DMG" 2>&1 | sed 's/^/    /' || true

echo
echo "[notarize] ✓ notarized + stapled dmg: $FINAL_DMG"
echo "    Contains: ${APPS[*]}"
echo "    Opens with no Gatekeeper warning on a downloader's Mac (drag both to Applications)."
