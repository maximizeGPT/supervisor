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

## What forward does NOT mean

- Expanding beyond macOS. Single-platform depth over multi-platform
  breadth.
- Adding features that don't trace their state transitions. Silent
  state changes are bugs, not features.
- Loosening safety gates for convenience. The rubric is the contract;
  if it's wrong, change it with evidence, don't bypass it.
- Inventing scope that isn't grounded in filed work, known gaps, or
  the direction above.
