# Owner Brief

Last updated: 2026-06-03

## What shipped recently

- v0.9.1: the action flash finally shows on screen. When Supervisor takes
  a real action (pause, send a task, update itself), the hover now flashes
  and shows a plain-language label ("Paused Claude Code", "Supervisor
  updated itself") instead of being instantly overwritten by background
  activity. Verified by watching the actual screen, not just the code.
- v0.9.1: the loop stops proposing work that is already done. It now
  checks that a task's premise is true before proposing it, and it will
  never propose "rewrite the owner brief" (this file writes itself every
  cycle).
- v0.9.1: the hook always works from the repo root, even if a session
  starts in a subfolder, so it stops writing this brief into the wrong
  directory.
- v0.9.0: the dispatch loop idles calmly when there is no real work,
  instead of thrashing (it used to fire 8+ times in minutes and crash).
- Self-watch fix: the "your installed app is stale" check no longer cries
  wolf on a build that is actually current.
- v0.8.4: stable code signing, so when the app rebuilds itself it keeps
  its Accessibility and Keychain permissions.

## Most valuable thing remaining

The biggest open quality gap is calibration (Issue #12): Supervisor
catches roughly 75 to 87 percent of what it should flag, and the bar is
95 percent. Closing it needs an ANTHROPIC_API_KEY to run the calibration
sweeps, which autonomous sessions do not have, so this is blocked on you.

Beyond that, most of what can be built from inside this repo is built.
The honest next step is external: putting Supervisor in front of one real
user and watching them use it. That is a decision and an action only you
can take. The autonomous loop cannot manufacture it.

## Needs your attention

- An ANTHROPIC_API_KEY to unblock the calibration work (Issue #12).
  Without it, autonomous sessions can only do pure-code tasks.
- The dispatch loop is currently ON. It is stable (it will not thrash) and
  now declines already-done work, so it is much less likely to propose
  busywork. On this branch it has largely run out of genuinely new work,
  so expect it to idle often. Turning it off is a clean option:
  rm ~/.claude/hooks/dispatch-loop-enabled.json
- This branch (autonomous-20260525T193906Z) has the v0.9.0, self-watch,
  and v0.9.1 fixes. They are not pushed and not merged to main, ready for
  your review whenever you want them.

## What the loop is doing next

Evaluating on the next idle. With the actionable queue largely empty, it
should either idle and wait for direction or surface a low-confidence
proposal, rather than dispatch new work.
