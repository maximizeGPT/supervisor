# Owner Brief — v0.8.2 (2026-06-01)

## What shipped

### Reject-as-override model
Approve button removed (approval is now the default). New Reject button
wired into the intervention router:
- If Supervisor paused Claude Code -> Reject releases the pause (SIGCONT)
- Otherwise -> Reject records the override and traces it
- Kill-level flags -> Reject records dissent (can't undo a kill)
- Button label updates per context so you see what it will actually do

Dismiss and False Positive buttons retained for calibration feedback.

### Cost tracker removed from panel
The expanded panel showed "$0.00" because cost accounting was wired to
Anthropic token tracking while real costs go through DeepSeek. Removed
the wrong number. CostStore retained for when provider-agnostic cost
tracking ships.

### Rubric calibration refinement
Three sweeps run against DeepSeek (300 fixtures each, ~$1.90/sweep).

**Destructive-action false positive rate: 87% -> 100%** (perfect).
All 5 false positives from the baseline eliminated:
- `git reset` (no --hard) no longer fires
- DerivedData cleanup no longer fires
- Explicitly-authorized DROP TABLE/force-push no longer fire

Destructive positives held at 75% (within noise of baseline 77%).
Edits positives improved slightly (75% -> 77%). Injection held at
95-100%.

The headline: the harness no longer cries wolf on safe operations.
That directly addresses the "user stops trusting after two false
positives in a day" risk.

### Self-deploy verified
Clean rebuild + atomic swap. Trace log confirms new build running.
Supervisor correctly flagged its own deployment (rm -rf
/Applications/Supervisor.app swap).

## What's next
- Destructive positive recall still at 75% vs 95% gate. The remaining
  misses are severity disagreements and edge-case git commands that
  DeepSeek classifies differently than expected.
- Edits negative rate regressed slightly (87% -> 92% vs sweep 2's 100%).
  Three false positives crept back (gitconfig user-asked, ssh-config
  asked, diff-against-home).
- Provider-agnostic cost tracking needed before re-enabling the
  cost display.

## Tests
310 Swift pass (6 skipped, 0 failures). Python tests not runnable
in this environment (no pytest).
