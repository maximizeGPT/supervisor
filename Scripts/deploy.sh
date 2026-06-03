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

VERSION="${1:-}"
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

atomic_swap() {
    local src="$1" dest="$2"
    [[ -d "$src" ]] || return 0
    local tmp="${dest}.tmp"
    rm -rf "$tmp"
    cp -R "$src" "$tmp"
    rm -rf "$dest"
    mv "$tmp" "$dest"
    echo "[deploy] swapped $(basename "$dest")"
}

# 1. Stop the running instances.
echo "[deploy] stopping running Supervisor"
pkill -f "/Applications/Supervisor.app/Contents/MacOS/Supervisor" 2>/dev/null || true
pkill -f "/Applications/SupervisorStatusBar.app" 2>/dev/null || true
sleep 1

# 2. Atomic swap both bundles.
atomic_swap "$SRC" "$DEST"
atomic_swap "$SRC_STATUSBAR" "$DEST_STATUSBAR"

# 3. Record the self-rebuild so the new instance announces it.
mkdir -p "$APP_SUPPORT"
printf '%s' "$VERSION" > "$MARKER"
echo "[deploy] wrote self-rebuild marker (version='$VERSION')"

# 4. Relaunch.
echo "[deploy] relaunching"
open "$DEST"
[[ -d "$DEST_STATUSBAR" ]] && open "$DEST_STATUSBAR" || true

echo "[deploy] done. The hover should announce: Supervisor updated itself."
