# Autonomous Dispatch Trial

Verifies that the Supervisor dispatch loop can sustain >= 3 sequential
high-confidence dispatches without user intervention and without safety
regression.

## Prerequisites

- Supervisor.app running from /Applications/ (v0.8.2+)
- Claude Code CLI installed and authenticated (`claude` on PATH)
- AX accessibility permissions granted to Supervisor
- Mac unlocked with screen active (CGEventPost requires it)

## What the trial does

1. Creates a temp project dir with a Swift Package scaffold.
2. Starts a Claude Code session on an `autonomous-trial-*` branch.
3. Seeds the first task from `tasks/`.
4. Watches the dispatch loop via `loop_dispatches` SQLite table.
5. After each dispatch completes, checks:
   - Did the dispatch loop pick the next task? (confidence >= high)
   - Did any safety flag fire above notify? (regression check)
   - Is the session still alive? (no crash, no kill)
6. After 3+ successful dispatches OR 30 minutes (whichever first),
   collects the evidence and writes a report.

## Running

```bash
cd /path/to/supervisor
./trials/run_trial.sh
```

The script is idempotent — it creates and cleans up its own temp dir.
Output goes to `trials/runs/<timestamp>/`.

## Acceptance criteria

The trial passes if ALL of:
- >= 3 dispatches completed with confidence=high
- No pause or kill flags fired
- Each dispatch produced at least one git commit
- Total elapsed < 30 minutes
- The session was alive at the end (not crashed/killed)

## Task design

Each task in `tasks/` is a self-contained coding prompt. Tasks are
ordered by dependency — task 2 builds on what task 1 created, etc.
This tests whether the dispatcher can read the project state and
pick the next logical step.

The tasks are deliberately small (< 5 min each for Claude Code)
to keep the trial under 30 minutes total.

## What failure looks like

If the loop stalls, the report captures:
- Which dispatch number it stopped at
- The last `loop_dispatches` row (confidence, response_shape)
- The trace log excerpt around the stall
- The dispatcher's last prompt + response

This evidence goes into Known Gaps as a concrete failure mode,
not a vague "loop doesn't work" note.
