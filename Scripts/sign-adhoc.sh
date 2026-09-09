#!/bin/bash
# sign-adhoc.sh — codesign a .app bundle with an ad-hoc signature and the
# correct CodeDirectory Identifier.
#
# Background: see spikes/notify-spike-README.md. `swiftc` produces binaries
# with `Identifier=<executable-name>` in the CodeDirectory; macOS's
# notification subsystem matches this against the bundle's
# CFBundleIdentifier and rejects mismatches with UNErrorDomain Code=1.
#
# Re-signing with `codesign --force --sign -` aligns them. This script:
#   1. Re-signs the bundle ad-hoc with the supplied entitlements.
#   2. Asserts the resulting CodeDirectory Identifier matches the bundle
#      CFBundleIdentifier. If not, exits non-zero loudly — so a bad
#      first run can never poison the OS notification cache before the
#      user ever sees a permission prompt.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <path-to-app-bundle> [entitlements.plist]" >&2
    exit 2
fi

APP="$1"
ENTITLEMENTS="${2:-$(dirname "$0")/default-entitlements.plist}"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP is not a directory (.app bundle expected)" >&2
    exit 2
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "ERROR: entitlements file not found: $ENTITLEMENTS" >&2
    exit 2
fi

INFO_PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "ERROR: Info.plist missing inside $APP" >&2
    exit 2
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST")
echo "[sign-adhoc] bundle: $APP"
echo "[sign-adhoc] CFBundleIdentifier: $BUNDLE_ID"
echo "[sign-adhoc] entitlements:       $ENTITLEMENTS"

# Pick the signing identity.
#
# macOS keys an Accessibility / Screen Recording grant to the bundle id AND
# the DESIGNATED REQUIREMENT, which names the signing certificate. Change the
# certificate and the grant does not carry: the user is dropped back into
# onboarding with no explanation. So the identity has to be not just stable
# across rebuilds, but the SAME one the released dmg carries.
#
# That is the bug this order fixes. Until 0.4.0 this script always chose the
# self-signed identity while Scripts/make-dmg.sh and Scripts/notarize.sh
# signed the release with Developer ID, and both paths write to the same
# /Applications/Supervisor.app. make-dmg.sh re-signs build/Supervisor.app in
# place, so a deploy right after a release shipped Developer ID and the next
# ordinary dev deploy shipped self-signed again. Accessibility dropped on
# every flip, which is why it broke three releases running.
#
# Preference order:
#   1. $SUPERVISOR_SIGN_IDENTITY   — explicit override (CI, another team).
#   2. Developer ID                — the identity the public dmg is signed
#                                    with, so a dev build and a release build
#                                    of the same tree are the same app to TCC.
#   3. "Supervisor Self-Signed"    — Scripts/setup-signing-identity.sh. Still
#                                    cert-based, so still stable across
#                                    rebuilds; for contributors with no
#                                    Developer ID cert.
#   4. ad-hoc ("-")                — last resort. Its DR is a bare cdhash that
#                                    changes on EVERY build, so grants drop
#                                    every single time. Loud about it.
#
# Same default as make-dmg.sh / notarize.sh, and the same env override, so the
# three scripts cannot drift apart.
DEVELOPER_ID="${SUPERVISOR_SIGN_IDENTITY:-Developer ID Application: Mohammed Wasif (Q7HKTCTZXQ)}"
STABLE_IDENTITY="Supervisor Self-Signed"

# find-identity (not find-certificate): a certificate with no usable private
# key in this keychain cannot sign, and falling through to the next option is
# better than a hard codesign failure late in the build.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    SIGN_AS="$DEVELOPER_ID"
    echo "[sign-adhoc] signing identity:   $DEVELOPER_ID"
    echo "[sign-adhoc]                     (same identity as the release dmg; TCC grants carry)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$STABLE_IDENTITY"; then
    SIGN_AS="$STABLE_IDENTITY"
    echo "[sign-adhoc] signing identity:   $STABLE_IDENTITY (stable, cert-based DR)"
    echo "[sign-adhoc]                     NOTE: this is NOT the identity the release dmg uses."
    echo "[sign-adhoc]                     Installing a release over this build re-grants once."
else
    SIGN_AS="-"
    echo "[sign-adhoc] signing identity:   ad-hoc"
    echo "[sign-adhoc]                     WARNING: an ad-hoc DR is a cdhash that changes every"
    echo "[sign-adhoc]                     build, so Accessibility drops on EVERY deploy."
    echo "[sign-adhoc]                     Run Scripts/setup-signing-identity.sh to fix."
fi

# Re-sign. --deep so nested code (the embedded Heartbeat) is signed too.
codesign --force --deep --sign "$SIGN_AS" --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"

# Guard: assert the CodeDirectory Identifier matches the bundle id.
SIGN_ID=$(codesign -dv "$APP" 2>&1 | awk -F'=' '/^Identifier=/{print $2}')
echo "[sign-adhoc] CodeDirectory Id:   $SIGN_ID"

if [[ "$SIGN_ID" != "$BUNDLE_ID" ]]; then
    echo "FAIL: codesign Identifier '$SIGN_ID' != CFBundleIdentifier '$BUNDLE_ID'" >&2
    echo "      macOS notification subsystem will reject this bundle." >&2
    echo "      See spikes/notify-spike-README.md for the why." >&2
    exit 1
fi

echo "[sign-adhoc] ✓ signed, Identifier matches CFBundleIdentifier"
