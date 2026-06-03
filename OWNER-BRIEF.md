# Owner Brief

Last updated: 2026-06-03

## What shipped recently

- v0.9.0: the dispatch loop now idles calmly when there is no real work,
  instead of thrashing. The old behavior treated "no work" as a failure,
  dispatched more work about its own spinning, fired 8+ times in minutes,
  and crashed. Fixed, with regression tests covering both the empty-queue
  case and the "don't over-correct on real work" case.
- Self-watch fix: the "your installed app is stale, rebuild it" check no
  longer cries wolf on a build that is actually current. It was misreading
  git diff output and warning every time, which is what triggered a
  pointless "deploy" dispatch earlier today against an already-current app.
- v0.8.4: stable code signing, so when the app rebuilds itself it keeps
  its Accessibility and Keychain permissions instead of making you
  re-grant them after every self-deploy.
- Smaller fixes: action-log labels no longer clip version numbers, and now
  use proper sentence detection.
- v0.8.3: a neutral Override button, plainer notification wording, an
  onboarding Continue step, and a "Supervisor updated itself" note after
  self-deploys.

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
- The dispatch loop is currently ON. It is stable now (it will not
  thrash), but on this branch it has largely run out of genuinely new
  work, so it tends to propose tasks that are already done. It is safe,
  just not adding much right now. Turning it off is a clean option:
  rm ~/.claude/hooks/dispatch-loop-enabled.json
- This branch (autonomous-20260525T193906Z) has the v0.9.0 and self-watch
  fixes committed but not pushed and not merged to main. They are ready
  for your review whenever you want them.

## What the loop is doing next

Evaluating on the next idle. With the actionable queue largely empty, it
should either idle and wait for direction or surface a low-confidence
proposal, rather than dispatch new work.
