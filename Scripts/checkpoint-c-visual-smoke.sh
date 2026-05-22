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

echo "==> 4. Launch Supervisor + status-bar companion"
open ./build/Supervisor.app
open ./build/SupervisorStatusBar.app
echo
echo "Within the next ~10 seconds, watch for:"
echo "  • macOS prompt: 'Supervisor would like to send you notifications'"
echo "    → Click ALLOW.   [closes visual gap Q1 — prompt]"
echo "  • Hover window: 240x40, top-right of screen, green dot, label '(no session)'"
echo "  • Menu bar status icon: green checkmark.circle.fill"
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

echo "==> 6. Verify the §11.4 SIGTERM-orphan limit (Q2 part 1)"
APP_PID=$(pgrep -f "Supervisor.app/Contents/MacOS/Supervisor$" | head -1)
if [[ -n "$APP_PID" ]]; then
    echo "[smoke] killing main app PID $APP_PID with SIGKILL"
    kill -9 "$APP_PID"
else
    echo "[smoke] WARN: couldn't find Supervisor.app main PID"
fi
echo
echo "Watch the menu bar for ~30 seconds. Expected behavior in v0.1.0:"
echo "  • Status bar icon STAYS GREEN"
echo "  • This is the documented §11.4 limitation — orphaned heartbeat"
echo "    keeps writing because macOS reparented it to launchd."
echo "  • v0.1.1's mach-port liveness check is the targeted fix."
echo
read -p "Press ENTER after confirming status bar stays green for 30+ seconds..."

echo "==> 7. Verify the heartbeat-direct-death path (Q2 part 2)"
echo "[smoke] killing heartbeat companion"
pkill -f SupervisorHeartbeat 2>/dev/null || true
echo
echo "Watch the menu bar for ~30 seconds. Expected:"
echo "  • Status bar transitions through amber (~10s after kill)"
echo "  • Then to RED (~30s after kill)"
echo "  • This is the Phase A.6-verified path — heartbeat absence -> red."
echo
read -p "Press ENTER after confirming red transition..."

echo "==> 8. Cleanup"
"$DEVTOOLS" delete-key 2>&1 | head -1
echo
echo "✓ Checkpoint C visual smoke complete."
echo
echo "If all three pressed-ENTER observations checked out:"
echo "  git tag -a v0.1.0-private -m 'v0.1.0 — private tag, trust-floor verified end-to-end with real Haiku.'"
