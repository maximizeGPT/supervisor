#!/bin/bash
# make-icns.sh — generate branding/AppIcon.icns from the 1024px brand master.
#
# Inputs:
#   branding/supervisor-appicon-1024.png   (1024×1024 RGBA, squircle baked in)
#
# Outputs:
#   branding/AppIcon.icns                  (committed; .iconset/ is intermediate)
#
# The .icns is the only artifact the rest of the build chain reads. The
# .iconset/ directory is staged in branding/ during the build and then
# removed — .gitignore already covers it, but we also clean up explicitly
# so a developer running the script locally doesn't get a dirty tree.
#
# Skips work if branding/AppIcon.icns is already newer than the master
# PNG — letting build-app.sh call this on every build without paying the
# 10×sips + iconutil cost when nothing changed.
#
# Pre-sign step: must finish before Scripts/sign-adhoc.sh, otherwise the
# signature won't cover the embedded icns and the Gatekeeper-equivalent
# check on first launch fails. build-app.sh orders these correctly.

set -euo pipefail

cd "$(dirname "$0")/.."

MASTER="branding/supervisor-appicon-1024.png"
ICNS="branding/AppIcon.icns"
ICONSET="branding/AppIcon.iconset"

if [[ ! -f "$MASTER" ]]; then
    echo "[make-icns] ERROR: master not found at $MASTER" >&2
    exit 1
fi

# Skip if icns is fresh. Use perl + stat for portability — macOS stat doesn't
# share GNU's -c "%Y" syntax.
if [[ -f "$ICNS" ]]; then
    MASTER_MTIME=$(stat -f %m "$MASTER")
    ICNS_MTIME=$(stat -f %m "$ICNS")
    if (( ICNS_MTIME >= MASTER_MTIME )); then
        echo "[make-icns] $ICNS is up to date (older $MASTER), skipping."
        exit 0
    fi
fi

echo "[make-icns] regenerating $ICNS from $MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Standard macOS iconset sizes. Each size is a separate sips pass against
# the 1024px master — sips handles squircle alpha without recomposing it.
sips -z 16 16     "$MASTER" --out "$ICONSET/icon_16x16.png"          >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_16x16@2x.png"       >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_32x32.png"          >/dev/null
sips -z 64 64     "$MASTER" --out "$ICONSET/icon_32x32@2x.png"       >/dev/null
sips -z 128 128   "$MASTER" --out "$ICONSET/icon_128x128.png"        >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_128x128@2x.png"     >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_256x256.png"        >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_256x256@2x.png"     >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_512x512.png"        >/dev/null
cp "$MASTER"                  "$ICONSET/icon_512x512@2x.png"

iconutil --convert icns "$ICONSET" --output "$ICNS"
rm -rf "$ICONSET"

echo "[make-icns] ✓ wrote $ICNS ($(du -h "$ICNS" | cut -f1))"
