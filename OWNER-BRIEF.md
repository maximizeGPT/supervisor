# Owner Brief

Last updated: 2026-06-03

## What shipped recently

- v0.9.0: the dispatch loop now idles gracefully on an empty queue. When
  there is no real queued work it stops calmly and waits for direction,
  instead of treating "no work" as a problem to fix and dispatching more
  work about its own spinning. This was the thrash that fired the loop
  8+ times in minutes and then crashed it.
- The loop's self-repair now runs only when the dispatcher genuinely
  breaks (a network error or an unreadable response), never on an empty
  queue or low confidence.
- A repetition breaker stops the loop if it proposes the same task twice
  in a row, while still letting two genuinely different tasks both run.
- The loop will no longer take on work about watching itself (thrash
  guards, spin detectors). If it notices it is spinning, it stops.
- Fixed a crash on the path that skips a closed proposal.
- v0.8.4: stable code signing so self-deploy keeps the Accessibility and
  Keychain grants across rebuilds.

## Most valuable thing remaining

The loop is reliable when it runs, but reliability is not the product's
real bottleneck. The honest next priority is getting Supervisor in front
of one real user and watching them use it, rather than adding more
internal machinery. Most of what the loop can safely build on its own is
already built; the remaining high-value work needs you (a user
conversation, an Anthropic key for calibration, a distribution
decision), not another autonomous dispatch.

## Needs your attention

The dispatch loop is currently turned off. The enable flag was removed
during the thrash incident, so nothing is dispatching right now. The
v0.9.0 fix is written, tested, and verified against both acceptance
simulations in the repo.

One thing to know before re-enabling: the copy of the hook installed at
`~/.claude/hooks/dispatch_loop_hook.py` is still the OLD code that
thrashed. The fix lives in the repo and has not been deployed to that
install path (deploying is your call, not the loop's). So re-enabling is
two steps, not one:

1. Copy the fixed hook into place:
   `cp Tools/dispatch-loop-hook/dispatch_loop_hook.py Tools/dispatch-loop-hook/dispatcher-system-prompt.txt ~/.claude/hooks/`
2. Restore the enable flag (the file `dispatch-loop-enabled.json` in
   `~/.claude/hooks/`).

If you would rather keep the loop off and drive work manually, that is a
reasonable call too. This is your decision, not the loop's.

## What the loop is doing next

Nothing. The loop is idle and disabled, waiting for your direction.
