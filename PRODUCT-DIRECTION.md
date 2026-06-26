# Product Direction

This file is the project owner's plain-language statement of what this
project is trying to become. The Dispatcher reads it on every call as
the primary reference for "what does forward mean." Replace this file
with your own direction when pointing the dispatch loop at a different
repository.

---

## What this project is

Supervisor is a native macOS safety harness for Claude Code sessions.
It watches what the coding agent does in real time — bash commands,
file edits, assistant reasoning — and intervenes when it detects
destructive, unauthorized, or injection-shaped patterns. The
interventions range from a notification banner (cheap, informational)
through keystroke injection (answering the agent's question from
project context) to SIGSTOP/SIGTERM (stopping or killing the process
before damage lands).

## Where it's going

The harness is evolving from a passive watcher into an active
collaborator. Three vectors:

**1. Autonomous continuous dispatch.** When the coding agent finishes
a task and goes idle, Supervisor evaluates what to work on next and
either auto-dispatches (high confidence) or surfaces a proposal
(medium). The dispatch loop (v0.4.0+) plus the SelfExtender (v0.5.0)
keep a session productive without user intervention. The end state:
the owner queues direction, the loop executes, safety gates stay
enforced.

**2. Calibration depth.** The triage rubric is calibrated against a
300-fixture corpus with per-category gates (95% positive, 95%
negative). Each rubric change requires a sweep before ship. The
calibration is the trust contract — without it the harness loses
authority. Pushing the positive-recall gap (currently 75-87% on
destructive/edits) toward the 95% gate is standing work.

**3. Artifact quality.** Recovery docs, banners, trace logs, prompt
bodies — these are the product surfaces the user touches. Every
artifact has a spec, tests, and voice constraints. The hover panel,
the onboarding flow, the recovery doc template are all artifacts
that mature with each release.

**4. Owner-facing intelligence.** Supervisor talks UP to the project
owner, not just down to the worker. The owner brief
(OWNER-BRIEF.md) surfaces what shipped, what's stuck, and what
needs a human — in plain language. The self-watch catches stale
builds, stuck workers, and ineffective changes before the owner
has to notice them.

## The next phase: drive a session to its objective

Today the dispatch loop reasons LOCALLY. On each idle it asks "is there an
obvious mechanical follow-on from this branch's commits, the open issues, or the
last few turns?" When the immediate thread looks done it idles — because its
governing rule is "an ignorable proposal is worse than idle," and it has no
model of the USER'S objective or whether that objective is met. That
conservatism was the right fix for an earlier failure (re-proposing rejected and
false-premise tasks), but it's the wrong DEFAULT for what Supervisor is
becoming: a harness you give one prompt to, screen-record, and watch carry the
session to completion — prompting the worker the whole way, going quiet only
when the thing is built.

Three pieces are missing:

- **A session objective.** Capture the user's initial prompt as the
  through-line and anchor every idle-time decision on "what's the next concrete
  step toward THIS objective?" — which yields a step even when repo state is
  quiet. An objective-anchored step is grounded work, not invented scope (it
  does not violate the "don't invent scope" rule below — the objective IS the
  grounding).
- **A completion model.** Judge whether the objective is MET. This is the
  keystone — it's what lets the loop be relentless WITHOUT running past the
  finish or manufacturing busywork. "Done" becomes objective-complete, not
  "three idle rounds in a row."
- **A confidence bias that favors driving.** With a clear, unmet objective, the
  next step toward it is rarely ignorable, so "keep driving" should beat "idle
  when unsure." The conservative default still applies when there is NO captured
  objective.

The safety rails are orthogonal and stay enforced: `wrong_trajectory` still
redirects a thrashing worker, pause/kill still stop genuine danger. In the ideal
run none of them fire — the loop just drives the worker from the opening prompt
to the finished artifact.

### First slice — anchor in, completion out

Smallest end-to-end version, verifiable on a real canary (§6d), which doubles as
the screen-record demo:

1. **Capture the objective** — persist each session's first substantive user
   prompt so it survives the rolling event window (the transcript's first user
   turn is the source; store it per-session).
2. **Feed it to the dispatcher** — add the objective to the dispatch prompt
   beside this file, and ask for the next concrete step toward it (not merely a
   mechanical follow-on).
3. **Report completion** — extend `DispatchResult` with an `objective_complete`
   judgment (met / not-met + what remains); the loop stops on objective-complete
   rather than waiting for the 3-consecutive-low hard stop to trip.

Acceptance: a session given one build prompt, then left idle, receives
successive high-confidence steps toward that objective (not "waiting for
direction"), and the loop reports objective-complete — and stops — when the
artifact is built, with no safety regression.

Deferred to later slices: the confidence-bias retune (piece 3) as its own
calibrated change; objective revision / multi-objective sessions; objective
inference when the opening prompt is vague.

## What "done" looks like for the next phase

- ~~The dispatch loop runs a multi-session autonomous trial (>= 3
  sequential high-confidence dispatches) without user intervention
  and without safety regression.~~ **DONE** (2026-06-02) on the
  hook-based path: about 60 dispatches, 5 consecutive high-confidence
  on May 31 and 4 consecutive on June 1, no safety regression. This
  is proven for existing trusted sessions. Bootstrapping brand-new
  sessions in untrusted directories is blocked on a Claude Code
  limitation (no non-interactive folder-trust bypass) and is out of
  scope. Do not re-propose proving the loop.
- Calibration hits the 95/95 gate on all three rubric categories.
  (Issue #12 — blocked on ANTHROPIC_API_KEY.)
- ~~The hover panel shows live session cost and flag history (v0.1.7
  expanded panel).~~ **DONE** — v0.1.7 shipped: 480x360 expanded
  panel with recent flags, session metrics, cost, Resume button,
  Dismiss/False-positive buttons, expandable flag rows. v0.8.1 added
  draggable hover.
- The system runs reliably on both Anthropic and DeepSeek providers
  without provider-specific workarounds beyond the translation layer.
- A session given a single objective prompt is driven to completion
  autonomously — successive grounded steps toward that objective, a
  stop on objective-complete, no safety regression. This is the bar for
  the give-it-one-prompt screen-record demo (first slice above).

## What forward does NOT mean

- Expanding beyond macOS. Single-platform depth over multi-platform
  breadth.
- Adding features that don't trace their state transitions. Silent
  state changes are bugs, not features.
- Loosening safety gates for convenience. The rubric is the contract;
  if it's wrong, change it with evidence, don't bypass it.
- Inventing scope that isn't grounded in filed work, known gaps, the
  session's captured objective, or the direction above. (A concrete step
  toward the session's objective IS grounded — that's the whole point of
  the objective anchor; it is not "invented scope.")
