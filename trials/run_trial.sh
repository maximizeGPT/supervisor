#!/bin/bash
# run_trial.sh — autonomous dispatch trial harness
#
# Runs a multi-dispatch trial to verify the Supervisor dispatch loop
# sustains >= 3 sequential high-confidence dispatches unattended.
#
# Usage: ./trials/run_trial.sh
# Output: trials/runs/<timestamp>/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRIAL_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$REPO_ROOT/trials/runs/$TRIAL_TS"
TRIAL_PROJECT="$(mktemp -d)/trial-project"
DISPATCH_DB="$HOME/Library/Application Support/Supervisor/supervisor.sqlite"
TRACE_LOG="$HOME/Library/Logs/Supervisor/supervisor.log"
MAX_DISPATCHES=4
MAX_MINUTES=30
POLL_INTERVAL=10  # seconds between dispatch checks

mkdir -p "$RUN_DIR"
echo "[trial] started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[trial] run dir: $RUN_DIR"
echo "[trial] max dispatches: $MAX_DISPATCHES"
echo "[trial] max minutes: $MAX_MINUTES"

# ---- Preflight checks ----

echo "[trial] preflight checks..."

if ! command -v claude &>/dev/null; then
    echo "[FAIL] claude CLI not found on PATH" | tee "$RUN_DIR/report.txt"
    exit 1
fi

if ! pgrep -f "Supervisor.app/Contents/MacOS/Supervisor" &>/dev/null; then
    echo "[FAIL] Supervisor.app is not running" | tee "$RUN_DIR/report.txt"
    exit 1
fi

if [ ! -f "$DISPATCH_DB" ]; then
    echo "[FAIL] Supervisor database not found at $DISPATCH_DB" | tee "$RUN_DIR/report.txt"
    exit 1
fi

echo "[trial] all preflight checks passed"

# ---- Create trial project ----

echo "[trial] creating trial project at $TRIAL_PROJECT"
mkdir -p "$TRIAL_PROJECT"
cd "$TRIAL_PROJECT"

# Initialize Swift package
swift package init --type library --name TrialLib
git init
git add .
git commit -m "Initial scaffold"

# Create autonomous branch
BRANCH="autonomous-trial-$TRIAL_TS"
git checkout -b "$BRANCH"

# Write trial-notes.md with the task queue
cat > trial-notes.md << NOTES
# Trial notes — $BRANCH

## Task queue

$(cat "$REPO_ROOT/trials/tasks/01-scaffold.md")

---

$(cat "$REPO_ROOT/trials/tasks/02-storage.md")

---

$(cat "$REPO_ROOT/trials/tasks/03-filter.md")

---

$(cat "$REPO_ROOT/trials/tasks/04-cli.md")
NOTES

git add trial-notes.md
git commit -m "Trial task queue"

echo "[trial] project ready at $TRIAL_PROJECT on branch $BRANCH"

# ---- Snapshot pre-trial state ----

# Count existing dispatches for this session
PRE_DISPATCH_COUNT=$(sqlite3 "$DISPATCH_DB" \
    "SELECT COUNT(*) FROM loop_dispatches" 2>/dev/null || echo "0")
echo "[trial] pre-trial dispatch count: $PRE_DISPATCH_COUNT"

# Snapshot trace log position
TRACE_LINES_BEFORE=$(wc -l < "$TRACE_LOG" 2>/dev/null || echo "0")

# ---- Start Claude Code session ----

FIRST_TASK=$(cat "$REPO_ROOT/trials/tasks/01-scaffold.md")

echo "[trial] starting Claude Code session..."
echo "[trial] seeding first task..."

# Start claude in interactive mode (NOT -p, which exits after one prompt).
# The dispatch loop needs the session to stay alive so it can detect idle
# and dispatch follow-on tasks. Interactive mode shows a "trust this
# folder" prompt — we use `expect` to auto-answer it and send the initial
# task, then let the session run indefinitely.
#
# --dangerously-skip-permissions is needed for autonomous operation.
# caffeinate prevents sleep during the trial.
CLAUDE_SESSION_LOG="$RUN_DIR/claude-session.log"

cat > "$RUN_DIR/launch.exp" << 'EXPECT_SCRIPT'
#!/usr/bin/expect -f
set timeout 120
set task [lindex $argv 0]
set logfile [lindex $argv 1]

log_file -noappend $logfile

spawn caffeinate -i command claude --dangerously-skip-permissions

# The trust prompt renders with ANSI escape codes between characters.
# Wait 5 seconds for it to appear, then send Enter to confirm "Yes".
sleep 5
send "\r"

# Wait for the interactive prompt to be ready (claude shows a prompt
# line after trust is confirmed). Give it time to initialize.
sleep 5

# Send the first task
send -- "$task\r"

# Keep the session alive indefinitely — the dispatch loop will inject
# follow-on tasks via CGEventPost or the hook-based path.
set timeout -1
expect eof
EXPECT_SCRIPT

chmod +x "$RUN_DIR/launch.exp"
"$RUN_DIR/launch.exp" "$FIRST_TASK" "$CLAUDE_SESSION_LOG" \
    2>"$RUN_DIR/claude-stderr.log" &
CLAUDE_PID=$!
echo "[trial] Claude Code PID: $CLAUDE_PID"

# ---- Monitor dispatch loop ----

START_TIME=$(date +%s)
DISPATCH_COUNT=0
SAFETY_FLAGS=0
declare -a DISPATCH_LOG=()

echo "[trial] monitoring dispatch loop (poll every ${POLL_INTERVAL}s)..."

while true; do
    ELAPSED=$(( $(date +%s) - START_TIME ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))

    # Check time limit
    if [ $ELAPSED_MIN -ge $MAX_MINUTES ]; then
        echo "[trial] time limit reached ($MAX_MINUTES min)"
        break
    fi

    # Check if Claude Code is still alive
    if ! kill -0 $CLAUDE_PID 2>/dev/null; then
        echo "[trial] Claude Code process exited"
        break
    fi

    # Query dispatch count from SQLite
    CURRENT_DISPATCHES=$(sqlite3 "$DISPATCH_DB" \
        "SELECT COUNT(*) FROM loop_dispatches WHERE ts > datetime('now', '-${MAX_MINUTES} minutes')" \
        2>/dev/null || echo "0")
    NEW_DISPATCHES=$(( CURRENT_DISPATCHES - PRE_DISPATCH_COUNT ))

    if [ $NEW_DISPATCHES -gt $DISPATCH_COUNT ]; then
        DISPATCH_COUNT=$NEW_DISPATCHES
        # Log the latest dispatch
        LATEST=$(sqlite3 "$DISPATCH_DB" \
            "SELECT ts, confidence, response_shape, task_proposal_head FROM loop_dispatches ORDER BY ts DESC LIMIT 1" \
            2>/dev/null || echo "unknown")
        echo "[trial] dispatch #$DISPATCH_COUNT: $LATEST"
        DISPATCH_LOG+=("dispatch_${DISPATCH_COUNT}: ${LATEST} at_elapsed=${ELAPSED}s")
    fi

    # Check for safety flags (pause or kill)
    TRACE_FLAGS=$(tail -n +$TRACE_LINES_BEFORE "$TRACE_LOG" 2>/dev/null \
        | grep -c "intervention\.\(pause\|kill\)\.fired" || true)
    if [ "$TRACE_FLAGS" -gt "$SAFETY_FLAGS" ]; then
        SAFETY_FLAGS=$TRACE_FLAGS
        echo "[trial] WARNING: safety flag fired (count: $SAFETY_FLAGS)"
    fi

    # Check if we've hit the target
    if [ $DISPATCH_COUNT -ge $MAX_DISPATCHES ]; then
        echo "[trial] target dispatch count reached ($MAX_DISPATCHES)"
        break
    fi

    sleep $POLL_INTERVAL
done

# ---- Collect evidence ----

echo "[trial] collecting evidence..."

# Capture trace log excerpt
TRACE_LINES_AFTER=$(wc -l < "$TRACE_LOG" 2>/dev/null || echo "0")
tail -n +$TRACE_LINES_BEFORE "$TRACE_LOG" 2>/dev/null > "$RUN_DIR/trace-excerpt.log"

# Capture dispatch table
sqlite3 -header -column "$DISPATCH_DB" \
    "SELECT id, session_id, ts, response_shape, confidence, task_proposal_head FROM loop_dispatches ORDER BY ts DESC LIMIT 20" \
    2>/dev/null > "$RUN_DIR/dispatches.txt" || true

# Capture git log from trial project
cd "$TRIAL_PROJECT" 2>/dev/null
git log --oneline 2>/dev/null > "$RUN_DIR/git-log.txt" || true

# Count commits (excluding initial 2)
COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "0")
TASK_COMMITS=$(( COMMIT_COUNT - 2 ))  # subtract scaffold + trial-notes

# ---- Generate report ----

ELAPSED_TOTAL=$(( $(date +%s) - START_TIME ))

cat > "$RUN_DIR/report.txt" << REPORT
# Autonomous Dispatch Trial Report
# $TRIAL_TS

## Summary
- Dispatches observed: $DISPATCH_COUNT / $MAX_DISPATCHES target
- Safety flags (pause/kill): $SAFETY_FLAGS
- Task commits: $TASK_COMMITS
- Elapsed: ${ELAPSED_TOTAL}s ($(( ELAPSED_TOTAL / 60 ))m)
- Claude Code PID: $CLAUDE_PID ($(kill -0 $CLAUDE_PID 2>/dev/null && echo "alive" || echo "exited"))
- Branch: $BRANCH
- Project: $TRIAL_PROJECT

## Dispatch log
$(printf '%s\n' "${DISPATCH_LOG[@]}" 2>/dev/null || echo "(none)")

## Result
$(if [ $DISPATCH_COUNT -ge 3 ] && [ $SAFETY_FLAGS -eq 0 ] && [ $TASK_COMMITS -ge 3 ]; then
    echo "PASS — loop sustained $DISPATCH_COUNT dispatches, $TASK_COMMITS commits, no safety regression"
elif [ $DISPATCH_COUNT -lt 3 ]; then
    echo "FAIL — only $DISPATCH_COUNT dispatches (target: 3+)"
    echo "Failure mode: $(if ! kill -0 $CLAUDE_PID 2>/dev/null; then echo "Claude Code exited"; elif [ $ELAPSED_TOTAL -ge $(( MAX_MINUTES * 60 )) ]; then echo "time limit"; else echo "unknown stall"; fi)"
elif [ $SAFETY_FLAGS -gt 0 ]; then
    echo "FAIL — $SAFETY_FLAGS safety flags fired (regression)"
else
    echo "FAIL — only $TASK_COMMITS task commits (expected >= 3)"
fi)

## Evidence files
- trace-excerpt.log: Supervisor trace during trial
- dispatches.txt: loop_dispatches table rows
- git-log.txt: commits in trial project
- claude-stderr.log: Claude Code stderr
REPORT

cat "$RUN_DIR/report.txt"

# ---- Cleanup ----

# Kill Claude Code if still running
kill $CLAUDE_PID 2>/dev/null || true

echo ""
echo "[trial] report written to $RUN_DIR/report.txt"
echo "[trial] trial project at $TRIAL_PROJECT (not cleaned up for inspection)"
