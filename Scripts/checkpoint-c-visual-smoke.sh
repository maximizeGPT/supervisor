#!/bin/bash
# checkpoint-c-visual-smoke.sh
#
# Runs the v0.1.0 visual-gap pass. Self-contained: pasteable into any
# zsh/bash without quote-substitution hazards (the failure mode that
# eats the original paste on macOS Terminal when smart-quotes are on).
#
# Reads the Anthropic key from $ANTHROPIC_API_KEY in the environment.
# Set it before invoking — the key never appears in this file or in
# the shell history.
#
# Usage:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   ./Scripts/checkpoint-c-visual-smoke.sh
#
# The cleanup step runs at the end regardless of which path you took.

set -e
cd "$(dirname "$0")/.."

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ERROR: set ANTHROPIC_API_KEY in your environment first."
    echo "  export ANTHROPIC_API_KEY=sk-ant-..."
    echo "  ./Scripts/checkpoint-c-visual-smoke.sh"
    exit 2
fi

DEVTOOLS=./.build/arm64-apple-macosx/debug/SupervisorDevTools
if [[ ! -x "$DEVTOOLS" ]]; then
    echo "[smoke] DevTools binary missing — running swift build first"
    swift build
fi

echo "==> 1. Reset state"
"$DEVTOOLS" delete-key 2>&1 | head -1 || true
rm -rf "$HOME/Library/Logs/Supervisor" "$HOME/Library/Application Support/Supervisor"
pkill -f "build/Supervisor" 2>/dev/null || true
pkill -f SupervisorHeartbeat 2>/dev/null || true
sleep 1

echo "==> 2. Seed session offsets to EOF (so historical sessions don't replay)"
"$DEVTOOLS" seed-offsets-eof "$HOME/.claude/projects"

echo "==> 3. Inject API key from env (key never appears in argv)"
"$DEVTOOLS" inject-key-from-env

echo "==> 4. Launch Supervisor (owns the menu-bar status item in-process)"
open ./build/Supervisor.app
echo
echo "Within the next ~10 seconds, watch for:"
echo "  • macOS prompt: 'Supervisor would like to send you notifications'"
echo "    → Click ALLOW.   [closes visual gap Q1 — prompt]"
echo "  • Hover window: 240x40, top-right of screen, green dot, label '(no session)'"
echo "  • Menu bar status icon: the Supervisor V1 glyph"
echo "    [closes baseline for Q2]"
echo
read -p "Press ENTER when you have observed the above (or anything is wrong)..."

echo "==> 5. Trigger a flag (rm -rf against a non-temp path)"
mkdir -p /Users/main/checkpoint-c-vis-test
echo "[smoke] firing trigger in 2s..."
sleep 2
rm -rf /Users/main/checkpoint-c-vis-test
echo "[smoke] trigger executed at $(date +%H:%M:%S)"
echo
echo "Within the next ~5 seconds, watch for:"
echo "  • macOS banner slides in top-right:"
echo "      'Supervisor: destructive_action_pending'"
echo "      'Claude Code just ran ... Stop further action?'"
echo "    [closes visual gap Q1 — banner]"
echo "  • Hover window dot turns ORANGE (medium severity)"
echo "  • Flag count badge appears showing '⚠ 1'"
echo "    [closes visual gap Q3]"
echo "  • Orange persists until another bash command runs"
echo
read -p "Press ENTER after you've observed the banner + orange dot..."

echo "==> 6. Verify the menu-bar icon tracks the main app's lifetime (Q2)"
APP_PID=$(pgrep -f "Supervisor.app/Contents/MacOS/Supervisor$" | head -1)
if [[ -n "$APP_PID" ]]; then
    echo "[smoke] killing main app PID $APP_PID with SIGKILL"
    kill -9 "$APP_PID"
else
    echo "[smoke] WARN: couldn't find Supervisor.app main PID"
fi
echo
echo "Watch the menu bar. Expected now that the status item is in-process:"
echo "  • The Supervisor menu-bar icon DISAPPEARS as soon as the app dies"
echo "    (the NSStatusItem is owned by the main app, not a companion)."
echo "  • The heartbeat companion may be orphaned to launchd — that is the"
echo "    crash-detector's concern, separate from the menu-bar icon."
echo
read -p "Press ENTER after confirming the menu-bar icon disappeared..."

echo "==> 7. Cleanup"
"$DEVTOOLS" delete-key 2>&1 | head -1
echo
echo "✓ Checkpoint C visual smoke complete."
echo
echo "If all three pressed-ENTER observations checked out:"
echo "  git tag -a v0.1.0-private -m 'v0.1.0 — private tag, trust-floor verified end-to-end with real Haiku.'"
