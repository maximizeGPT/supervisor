#!/bin/bash
# deploy.sh — atomic-swap the freshly built Supervisor over the running
# install and relaunch it. Writes a self-rebuild marker so the new
# instance announces "Supervisor updated itself" on the hover.
#
# Usage: Scripts/deploy.sh [version-label]
#   version-label  optional string shown in the hover announcement,
#                  e.g. "v0.8.3". Defaults to empty (generic message).
#
# Run Scripts/build-app.sh first to produce build/Supervisor.app.

set -euo pipefail
cd "$(dirname "$0")/.."

# Version label shown in the "Supervisor updated itself" hover. When not
# passed explicitly, derive it from git (same source build-app.sh stamps into
# CFBundleShortVersionString) so the announcement matches the installed bundle
# instead of being a generic blank. Falls back to empty if git/tags are absent.
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    if VERSION=$(git describe --tags --always --dirty 2>/dev/null); then
        VERSION="${VERSION#v}"
    else
        VERSION=""
    fi
fi
SRC="build/Supervisor.app"
SRC_STATUSBAR="build/SupervisorStatusBar.app"
DEST="/Applications/Supervisor.app"
DEST_STATUSBAR="/Applications/SupervisorStatusBar.app"
APP_SUPPORT="$HOME/Library/Application Support/Supervisor"
MARKER="$APP_SUPPORT/self-rebuild.marker"

if [[ ! -d "$SRC" ]]; then
    echo "[deploy] ERROR: $SRC not found. Run Scripts/build-app.sh first." >&2
    exit 1
fi

swap_bundle() {
    local src="$1" dest="$2"
    [[ -d "$src" ]] || return 0
    if [[ -d "$dest" ]]; then
        # Update the bundle IN PLACE instead of `rm -rf dest && mv`. Deleting
        # and recreating the bundle makes macOS treat it as a brand-new app
        # and PRUNES its TCC grants (Accessibility, Keychain), so the
        # owner-granted Accessibility permission silently drops on every
        # self-deploy even though the Settings toggle still shows "on".
        # rsync --delete syncs the new contents and removes stale files
        # WITHOUT ever deleting the bundle the grant is attached to, so a
        # cert-based grant survives the deploy. The running app is already
        # stopped (step 1), so in-place mutation is safe. The signed
        # contents are copied faithfully, so the signature stays valid.
        rsync -a --delete "$src"/ "$dest"/
        echo "[deploy] updated $(basename "$dest") in place (preserves TCC grants)"
    else
        cp -R "$src" "$dest"
        echo "[deploy] installed $(basename "$dest")"
    fi
}

# 1. Stop the running instances.
echo "[deploy] stopping running Supervisor"
pkill -f "/Applications/Supervisor.app/Contents/MacOS/Supervisor" 2>/dev/null || true
pkill -f "/Applications/SupervisorStatusBar.app" 2>/dev/null || true
sleep 1

# 2. Atomic swap both bundles.
swap_bundle "$SRC" "$DEST"
swap_bundle "$SRC_STATUSBAR" "$DEST_STATUSBAR"

# 3. Record the self-rebuild so the new instance announces it.
mkdir -p "$APP_SUPPORT"
printf '%s' "$VERSION" > "$MARKER"
echo "[deploy] wrote self-rebuild marker (version='$VERSION')"

# 4. Relaunch. Record the log position first so the smoke test only
# reads lines this launch produces.
LOG="$HOME/Library/Logs/Supervisor/supervisor.log"
LOG_BEFORE=0
[[ -f "$LOG" ]] && LOG_BEFORE=$(wc -l < "$LOG")
echo "[deploy] relaunching"
open "$DEST"
[[ -d "$DEST_STATUSBAR" ]] && open "$DEST_STATUSBAR" || true

# 5. Post-deploy smoke test. The app's own trace is the authoritative
# signal: it logs the onboarding decision (with axOK) only after the
# first Keychain read succeeds, and it reaches "running state ready"
# only when the LLM client's key read succeeds too. A signing
# regression that broke the cert-based requirement shows up here as a
# Keychain hang (no onboarding line) or a dropped AX grant (axOK=false),
# instead of silently failing the next time the harness needs to fire.
echo "[deploy] smoke test: waiting for the new instance to report state"
KEYCHAIN_OK=0
AX_OK=0
for _ in $(seq 1 20); do          # up to ~10s
    sleep 0.5
    NEW="$(tail -n +"$((LOG_BEFORE + 1))" "$LOG" 2>/dev/null)"
    # Keychain: any onboarding decision means the first key read passed.
    if echo "$NEW" | grep -q "onboarding skipped"; then
        KEYCHAIN_OK=1; AX_OK=1; break
    fi
    if echo "$NEW" | grep -q "onboarding needed"; then
        KEYCHAIN_OK=1
        if echo "$NEW" | grep -q "axOK=true"; then AX_OK=1; fi
        break
    fi
done

echo ""
if [[ "$KEYCHAIN_OK" -eq 1 ]]; then
    echo "[deploy] smoke: Keychain read PASS (app read its API key)"
else
    echo "[deploy] smoke: Keychain read FAIL (no onboarding decision in ~10s;"
    echo "         the app likely hung on a Keychain access prompt, which means"
    echo "         the signing identity regressed). Run setup-signing-identity.sh." >&2
fi
if [[ "$AX_OK" -eq 1 ]]; then
    echo "[deploy] smoke: Accessibility PASS (grant survived the deploy)"
else
    echo "[deploy] smoke: Accessibility NOT granted for the running app." >&2
    echo "         Grant it once for the cert-signed app (onboarding Continue);" >&2
    echo "         with stable signing, later rebuilds keep it." >&2
fi

echo "[deploy] done. The hover should announce: Supervisor updated itself."

# Exit non-zero so a regression is loud. Distinct codes: 1 = Keychain
# (hard failure, the harness cannot run), 2 = Accessibility missing
# (the harness runs notify-only until granted once).
if [[ "$KEYCHAIN_OK" -ne 1 ]]; then exit 1; fi
if [[ "$AX_OK" -ne 1 ]]; then exit 2; fi
echo "[deploy] smoke test PASS"
