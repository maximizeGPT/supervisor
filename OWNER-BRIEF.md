# Owner Brief

Last updated: 2026-06-03

## What shipped recently

- v0.9.3: self-deploy no longer silently drops the Accessibility
  permission. The deploy was deleting and recreating the app bundle each
  time, which made macOS treat it as a new app and forget the permission
  you granted (so the keystroke-into-terminal path was blocked even though
  Settings still showed it on). The deploy now updates the app in place and
  keeps the grant. See "Needs your attention" for the one-time step to
  restore it.
- v0.9.2: Supervisor now answers Claude Code's routine mid-session
  questions from context instead of leaving you to. A commit/push/A-or-B
  question is decided from the live branch + recent commits + conventions
  (e.g. "yes, commit it", "push the branch for CI"), and only genuinely
  high-stakes calls (a protected branch, deleting data, credentials) are
  escalated to you. NOTE: typing the answer straight into the terminal
  needs Accessibility permission granted to Supervisor (currently not
  granted); without it the answer surfaces as a banner instead.
- v0.9.2: the dispatcher can no longer fabricate work. Every function or
  file a proposal names is checked against the real code before it runs;
  if it names something that does not exist (the hallucinated-symbol bug),
  the proposal is discarded and the loop idles.
- v0.9.1: the action flash is visible on screen. A real action (pause,
  send a task, self-update) now flashes the hover and shows a plain label
  ("Paused Claude Code", "Supervisor updated itself") instead of being
  instantly overwritten. Verified by watching the actual screen.
- v0.9.1: the loop stops proposing work that is already done, and never
  proposes rewriting this brief or building new machinery for itself.
- v0.9.1: the hook always works from the repo root, even when a session
  starts in a subfolder.
- Fixed both self-watch false alarms (stale-build and ineffective-change)
  that were misreading timestamps and triggering pointless rebuilds.
- v0.9.0: the loop idles calmly on an empty queue instead of thrashing.

## Most valuable thing remaining

The biggest open quality gap is calibration (Issue #12): Supervisor
catches roughly 75 to 87 percent of what it should flag, and the bar is
95 percent. It needs an ANTHROPIC_API_KEY to run the sweeps, so it is
blocked on you.

Beyond that, the internally-buildable work is essentially done. The honest
next step is external: putting Supervisor in front of one real user. The
autonomous loop cannot manufacture that.

## Needs your attention

- ONE-TIME: re-grant Accessibility to Supervisor so it can type answers
  into the terminal. The old grant was broken by past deploys. In System
  Settings > Privacy & Security > Accessibility, remove the "Supervisor"
  entry (the minus button) and re-add /Applications/Supervisor.app with the
  toggle on. This is a security toggle only you can flip; I can't do it for
  you. After this once, the deploy fix keeps the grant across future
  rebuilds. (Until then, answers surface as banners instead of being typed.)
- The dispatch loop is now OFF. I turned it off: over six straight
  dispatches it produced no genuine work (already-done tasks, proposals to
  build itself features, and finally a request to fix a self-watch check
  that does not exist). It had run out of real work on this branch and was
  fabricating it, which only burned API calls and interrupted you. The
  reliability fixes it prompted along the way are all shipped. Re-enable it
  whenever there is a real queue: echo '{}' > ~/.claude/hooks/dispatch-loop-enabled.json
- An ANTHROPIC_API_KEY would unblock the calibration work (Issue #12).
- This branch (autonomous-20260525T193906Z) has the v0.9.0 and v0.9.1
  fixes committed, not pushed and not merged to main, ready for review.

## What the loop is doing next

Nothing. It is disabled and will not dispatch until you re-enable it.
