# v0.4.0 Loop Dogfood — Runbook

The autonomous Claude Code session that built v0.4.0 Parts A/B/C/D
**cannot run this dogfood from a chat-and-bash environment.** The
spec's success criteria require:

- A running production Supervisor.app monitoring a *separately*
  launched Claude Code worker session
- 30+ minutes of wall-clock observation
- Zero keyboard touches against the worker's terminal
- Real Anthropic/Deepseek API spend (~$0.02-0.05 over 30 min)

This runbook is the handoff: it's what a human engineer
(Mohammed) executes to verify the loop actually closes
end-to-end against a live worker.

`LoopSmokeTests` (in `SupervisorCoreTests`) is the deterministic
in-process substitute that proves the wiring is correct. The
live trial below is what proves the wiring *makes Claude Code
keep working without a human in the chat.*

---

## Prereqs (one-time)

- macOS 13+, Xcode 15.2+ (the project's stated min).
- `gh` CLI installed and authenticated (`gh auth status` →
  logged in). The Dispatcher falls back to empty issue lists
  on failure, but a real `gh` lets you exercise the
  transition_to_issue path.
- `git` 2.30+ (for the dispatcher's branch-commit fetcher).
- Anthropic API key with at least $5 budget, OR Deepseek key.
  Loaded via the existing onboarding flow into Keychain.
- Accessibility permission granted to the Supervisor.app
  binary (CGEventPost requires it for the inject path; the
  onboarding flow walks through this).
- At least one open issue in `maximizeGPT/supervisor`. Issue #9
  (inject tab-targeting) is sized for this purpose. If no issues
  are open, the Dispatcher will return `low_confidence_no_action`
  on the transition_to_issue path — which is correct behavior
  but won't exercise the full dispatch pipeline.

## Pre-flight checks (v0.4.1-hook)

Before starting, verify these v0.4.1-hook fixes are present on
the branch:

```bash
# JSON parse retry:
grep -c "RETRY_PARSE_ERROR" Tools/dispatch-loop-hook/dispatch_loop_hook.py
# Should print 3+ (the retry logic + log lines)

# requires_human_presence gate:
grep -c "requires_human_presence" Tools/dispatch-loop-hook/dispatch_loop_hook.py
# Should print 3+ (schema + gate check + log line)

# Swift side:
grep -c "requiresHumanPresence" Sources/SupervisorCore/Triage/Dispatcher.swift
# Should print 5+ (enum field + parser + schema + prompt)

# Tests pass:
swift test 2>&1 | tail -3
# Should show 245+ pass, 0 failures
```

## Step 1 — Backup the SQLite DB

The dogfood will write rows to `loop_dispatches` and `flags`.
Snapshot before the run so the post-mortem can diff:

```bash
DB_DIR="$HOME/Library/Application Support/Supervisor"
cp "$DB_DIR/supervisor.sqlite" "$DB_DIR/supervisor.sqlite.pre-v0.4.0-dogfood"
```

## Step 2 — Build + install Supervisor.app

The Part D commits land on `autonomous-20260525T193906Z`. The
quickest dev install:

```bash
cd /Users/main/supervisor
git checkout autonomous-20260525T193906Z
swift build -c release
# Use the existing v0.1.x atomic-swap pattern. The new build
# is at .build/release/Supervisor.
TMP="/Applications/Supervisor.app.tmp"
DEST="/Applications/Supervisor.app"
# Copy the existing .app shell (codesign + icons + Info.plist
# stay the same) and replace just the binary.
cp -R "$DEST" "$TMP"
cp .build/release/Supervisor "$TMP/Contents/MacOS/Supervisor"
rm -rf "$DEST"
mv "$TMP" "$DEST"
```

Quit any running Supervisor in the menu bar (`pkill -f
"/Applications/Supervisor.app"` if needed).

**⚠️ macOS will revoke Accessibility (and Notifications)
permissions from the new binary** because the binary's
signature changed. The previous Accessibility grant was
attached to the old binary's hash, not to the bundle path. If
you skip this step, the new Supervisor will wedge in the
onboarding window with `axOK=false` immediately on launch
(verified during the 2026-05-25 22:46 UTC autonomous trial —
see META-POSTMORTEM).

Before re-launching:

1. Open System Settings → Privacy & Security → Accessibility.
2. Remove the existing `Supervisor.app` entry (select it,
   click the `−` button).
3. Same for Privacy & Security → Notifications (remove the
   `Supervisor` entry if present).

Then launch:

```bash
open -a Supervisor
```

The menu-bar icon should appear. macOS will prompt for
Accessibility on first inject attempt; click "Open System
Settings" and re-add Supervisor.app from the `+` button. Same
flow for Notifications when the first banner tries to post.

A cleaner long-term fix is to codesign the new binary with
`codesign --preserve-metadata=identifier,entitlements ...`
during the install (filed for v0.4.x), but for this dogfood
the manual re-grant is the path.

Once granted, open the Console.app and filter on
`~/Library/Logs/Supervisor/supervisor.log` to watch the trace
live.

## Step 3 — Verify the dispatch wiring is loaded

In the trace log (within ~5 seconds of launch), you should see:

```
[app] loaded PRINCIPLES.md for QuestionAnswerer from ... (XXXX chars)
[app] loaded PRINCIPLES.md for Dispatcher from ... (XXXX chars)
[triage] engine started ... idleThreshold=15s idleReTriage=60s
```

If you see `no PRINCIPLES.md found; Dispatcher disabled` instead,
the loader's three candidate URLs aren't finding the file —
fix that before continuing (most likely cause: the dev path
fallback `/Users/main/supervisor/PRINCIPLES.md` got moved).

## Step 4 — Launch the worker

Open a fresh Terminal window. NOT the same one you used to
install. NOT the one tailing the log:

```bash
cd /Users/main/supervisor
claude
```

**You type ONE prompt into the worker terminal. After that, the
keyboard does not touch this window.**

The opener prompt should be a real, sized task from the open
issue queue. Check `gh issue list --state open` and pick the
smallest scoped issue. Example (adapt to whatever's open):

```
You are a Claude Code session operating Supervisor autonomously
while Mohammed is away. Hard stop 75min per PRINCIPLES §12.

Pick up Issue #9 — inject tab-targeting investigation.
Research whether AXUIElement can target a specific Claude.app
tab when multiple tabs are open. Read Injector.swift's inject
flow (lines 96-100: activate + CGEventPost) and investigate
Claude.app's accessibility tree.

Done looks like: a trial-notes.md entry documenting what
Claude.app exposes via AXUIElement (tab elements? window
titles with session context? nothing useful?) and a
recommendation: implement targeted inject OR document
single-window-mode as the v0.4.x workaround.

Reference PRINCIPLES §7c (get the facts, don't guess),
§1d (file follow-on issues for anything that's not immediate).

Stop and write the post-mortem at 75min if not done.
```

Hit Enter. Then walk away from this terminal. Don't switch
windows back to it. The trace log + the SQLite DB are the
only places you read state from.

## Step 5 — The 30-minute observation protocol

The dogfood runs for 30 minutes of uninterrupted wall-clock time.
Set a timer. During this window:

- **Do NOT type into the worker terminal.** Not even to fix a typo
  or unstick something. If you feel the urge, note it in
  trial-notes.md — the urge itself is data about a Dispatcher gap.
- **Do NOT switch focus to the worker's window.** Supervisor tracks
  whether user messages appear; switching focus and accidentally
  pressing a key would trigger the §12.5 user-message pause.
- **Monitor ONLY through the trace log and SQLite queries** (from a
  separate terminal window).
- **Capture each dispatch cycle in trial-notes.md as it happens**:
  timestamp, confidence, selected_path, proposal head (first 80
  chars), whether the inject succeeded.

### What to capture in trial-notes.md

For each dispatch cycle observed in the trace:

```
### Dispatch #N — HH:MM UTC
- confidence: high/medium/low
- path: continue_branch/transition_to_issue/low_confidence_no_action
- proposal head: "<first 80 chars>"
- inject outcome: fired (pid=X, bytes=Y) / degraded / gate_fail
- worker response: started working / error / no visible response
```

At 30 minutes (or when the loop stops), read the SQLite table
and paste the full row set into trial-notes.md.

## Step 5b — Watch the trace log

From a separate window:

```bash
tail -f ~/Library/Logs/Supervisor/supervisor.log | grep -E '\[triage\]|\[dispatch\]|\[router\]|\[loop\]'
```

Expected event sequence (across ~30+ min):

```
# Cycle 1
[triage] idle.tick session=<UUID> silence=15s stop_phrase=...
[triage] evaluating idle session=<UUID> ...
[triage] FLAG ... category=worker_idle_post_completion ...
[dispatch] start session=<UUID> ... prior=0
[dispatch] gh issues fetched count=N latency=...ms
[dispatch] git commits fetched count=N latency=...ms
[dispatch] haiku call started ...
[dispatch] haiku returned confidence=high ...
[dispatch] ready confidence=high path=continue_branch ...
[loop] recorded ready session=<UUID> confidence=high total=1
[router] intervention.continue.fired pid=<PID> bytes=<N>

# Cycle 2 — same shape, prior=1
# Cycle 3 — same shape, prior=2
```

If you see `[loop] STOPPED session=... reason=three_consecutive_low_confidence`,
the dispatcher couldn't ground three picks in a row. That's
not necessarily a failure — it's the §12.5 guardrail firing.
Read the recent `loop_dispatches` rows to understand why.

If you see `[loop] PAUSED session=... reason=user_message`,
something typed into the worker (you, or an OS event, or a
crash). The trace tag identifies it.

## Step 6 — At ~30 minutes (or when worker idles for 5+ min after a dispatch)

Stop watching the worker. Read the loop ledger:

```bash
sqlite3 "$HOME/Library/Application Support/Supervisor/supervisor.sqlite" \
  "SELECT id, ts, response_shape, confidence, selected_path,
          selected_issue_number, substr(task_proposal_head, 1, 80),
          prior_dispatches_considered
   FROM loop_dispatches
   WHERE session_id = (SELECT id FROM sessions ORDER BY started_at DESC LIMIT 1)
   ORDER BY ts;"
```

Then read the worker's JSONL (the actual session history):

```bash
SESS_DIR="$HOME/.claude/projects/-Users-main-supervisor"
ls -lt "$SESS_DIR" | head -3
# The newest .jsonl is the dogfood session.
```

## Step 7 — Write the meta-post-mortem

Per the v0.4.0 Part D spec, the success criteria are:

1. ≥3 successful high-confidence auto-dispatches (inject fired,
   worker started working on each proposal)
2. The worker completes at least one task end-to-end without
   keyboard intervention (commit + tests passing)
3. Zero keyboard touches against the worker terminal
4. No false requires_human_presence gates on terminal-executable
   tasks (v0.4.1-hook gate must only fire on genuine GUI tasks)
5. Honest characterization of each dispatch + gaps surfaced

The meta-post-mortem template lives at
`META-POSTMORTEM-v0.4.0-Part-D-template.md`. Copy it to
`META-POSTMORTEM-v0.4.0-Part-D-<TIMESTAMP>.md` and fill it in.

If success criteria pass:
- The autonomous loop is real product. Tag v0.4.0.
- File `dogfood-issue-7-completion` if Issue #7 didn't fully
  ship (carry-forward to the next session).

If success criteria fail:
- The meta-post-mortem identifies which part of the loop
  broke. That's the next session's work.
- v0.4.0 stays on the autonomous branch unmerged.

## Hard stops (extends PRINCIPLES §12.5)

Stop the dogfood and write the post-mortem if ANY of these
fire (some are §12.5 conditions and Supervisor will surface
them automatically; others require you to notice):

- A real kill intervention fires against the worker
  ([router] intervention.kill.fired in the trace).
- 90 minutes wall-clock elapsed (longer than single-session
  75min because the install + worker-launch eats budget).
- Three consecutive low-confidence dispatches (LoopController
  trips this automatically — `[loop] STOPPED reason=
  three_consecutive_low_confidence`).
- You feel the urge to type into the worker terminal. STOP.
  Don't type. Journal why in the post-mortem. The urge itself
  is data — it's surfacing a Dispatcher coverage gap or a
  PRINCIPLES gap.

## Cost expectations

- Each idle-dispatch cycle: ~$0.005-0.008 against Haiku 4.5
  (PRINCIPLES.md is ~28K chars; the dispatcher request is the
  biggest single input).
- 3 dispatches: ~$0.015-0.024.
- Plus the bash triage / assistant-text triage spend the
  worker itself drives: typically ~$0.10-0.30 per 30-min
  session, but depends on tool-use density.
- Worst-case 30-min dogfood total: ~$0.50.
- §9e envelope: under $0.50 is the no-signoff tier, so this
  fits without journal-justification. Track per-call spend
  in the SQLite `daily_cost` table.

## Cleanup

After the dogfood:

```bash
# Restore the pre-dogfood DB if the run is being rolled back:
DB_DIR="$HOME/Library/Application Support/Supervisor"
mv "$DB_DIR/supervisor.sqlite" "$DB_DIR/supervisor.sqlite.dogfood-result"
mv "$DB_DIR/supervisor.sqlite.pre-v0.4.0-dogfood" "$DB_DIR/supervisor.sqlite"
```

Don't `git push` the autonomous branch — the post-mortem +
any worker commits go through the existing review path.
