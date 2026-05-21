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

# Re-sign.
codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"

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
