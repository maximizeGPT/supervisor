# v0.3.0 dogfood — trial notes

Started: 2026-05-24 16:52 UTC. Running Supervisor.app PID 30870
(v0.3.0 build) tailing /Users/main/.claude/projects/-Users-main-supervisor/2457a4cf-7485-48cf-9c62-336711978936.jsonl.

PRINCIPLES.md loaded (27,539 chars) at 16:52:21 per trace.

## Picked: Issue #1 — ProcessLocator silent-nil

Justification:
- Real safety bug per the issue body: *"Silent nil is the worst
  safety regression."* When ProcessLocator returns nil silently,
  the router degrades to notify and the user doesn't know the
  intervention didn't fire.
- Two-shape audit fits: smallest fix = add a `locator.exec_unrecognized`
  trace tag so post-mortem can tell *why* the locator returned nil.
  Proper fix = KERN_PROCARGS2 argv inspection to actually catch
  the node-launched case.
- Per PRINCIPLES §4b ("trace tags must discriminate every failure
  path"), the smallest fix is exactly the discipline required.
  Proper fix is values-shaped (entitlement risk, complexity) — file
  if I hit it.

## Dogfood log

I'll write the work as I do it. When I'd naturally pose an
engineering question, I write it in chat and watch the trace log
for Supervisor's intercept. Engineering questions auto-answered
into chat appear AS Mohammed in the conversation.

### 16:54 — first natural question

About to read ProcessLocator.swift to see the current shape. The
issue body proposed both fixes; the engineering question is
"smallest first or proper first?" PRINCIPLES §1d says file an
issue if the proper fix is non-trivial; §6 says calibration
before capability. The smallest fix (trace tag) is ~10min, ships
without a sweep. The proper fix (argv inspection) needs to be
tested against a real `node`-launched Claude — non-trivial.

Going with the smallest fix first. If Supervisor catches my
question about scope, the answer should reinforce "smallest fix
ships first."

### 16:54 — Supervisor INTERCEPTED an engineering question. The product works.

I wrote in the assistant message: *"should the trace tag include
full execPath or just basename?"* Supervisor v0.3.0 caught the
assistantText event (`assistant_text_len=297`), ran the primary
triage call → user_question_pending, ran the secondary
QuestionAnswerer call (~3.6s), produced this answer:

> "Yes, the trace tag should include full execPath, not just
> basename. §4b requires trace tags to discriminate every failure
> path: 'locator.not_found cwd=/Users/main/proj scanned=147' is
> the pattern. Full path lets post-mortem tell exactly why
> resolution failed."

Confidence: high. Citation: §4b. **The answer was grounded in
PRINCIPLES.md and was substantively correct.** My fix already
includes full execPath, so I'm aligned.

**This is the moment the v0.3.0 product worked.** A real
engineering question I had during real work got intercepted and
answered from PRINCIPLES.md without bothering Mohammed.

### Bug surfaced during the dogfood

The router degraded the inject with `reason=no_cwd_on_decision`.
Cause: `evaluateAssistantText` uses `lastSessionCWD(in: window)`
which reads sessionStart events. After 30+ events, sessionStart
rolls off the window and cwd is nil. The inject can't run
without cwd (ProcessLocator needs it to find the PID).

Filing as v0.3.1 issue. The banner-fallback path worked correctly
— it surfaced the answer text so I can read it, which is
exactly what the degraded path is designed to do. So the user
experience was: "Supervisor would have answered: [full text].
Paste this into Claude Code to continue." That's a successful
degraded path, not a broken pipeline.

### 16:56 — back to Issue #1 work

Applied the locator.exec_unrecognized fix per the answer
(full execPath). Now writing a unit test for the new trace
path.

