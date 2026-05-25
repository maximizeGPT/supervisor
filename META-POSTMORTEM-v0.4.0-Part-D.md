# META-POSTMORTEM — v0.4.0 Part D (the dogfood)

**Trial:** `autonomous-20260525T193906Z`, Part D
**Date:** 2026-05-25, ~21:31–22:00 UTC
**Author:** the autonomous Claude Code session that built v0.4.0
**Branch:** `autonomous-20260525T193906Z` (six Part-A/B/C commits + D0 merged from main + D1 + D2 substitute + this doc)
**Main edits this session:** `8b69cdc` PRINCIPLES.md v3.5 (§12.5)

---

## TL;DR

D0 and D1 shipped. **D2 — the live dogfood — could not be
executed from this conversation.** The strongest in-process
substitute is `LoopSmokeTests` (deterministic 3-dispatch
integration smoke). The live trial is a human task; the
runbook at `Tests/Dogfood/RUNBOOK-v0.4.0.md` is what Mohammed
(or a future agent with a real keyboard + a 30-min wall-clock
budget + a built Supervisor.app) executes.

**v0.4.0 is not "ready to tag" by the spec's success criteria.**
The wiring is complete and unit-/integration-tested; the live
proof is the missing step.

---

## What shipped this session

Six commits on the autonomous branch + one on main:

- `8b69cdc` (main) PRINCIPLES.md v3.5: §12.5 loop hard stops
- `f92a526` (autonomous) Merge main (PRINCIPLES.md v3.5)
- `2aa913e` (autonomous) v0.4.0 Part D1: production wiring in main.swift
- (this commit-to-come) v0.4.0 Part D2: LoopSmokeTests + runbook + meta-post-mortem

Plus the Parts A/B/C work already on origin from earlier
sessions today (commits `4370ad8` through `ca20912` + the
Part C trial-notes commit `ec39129`).

### D0 — PRINCIPLES.md §12.5

Verbatim per the spec: five triggers (kill fires; 4hr elapsed;
3 consecutive low-confidence; user message; dispatcher values
call). The text additionally clarifies the §12-vs-§12.5
split — single-session §12 caps don't end the loop, because
the loop spans multiple session-equivalents; §12.5 stops are
loop-scoped.

Committed directly on main as `8b69cdc`. Main was at `3f905c3`
before (v0.3.2 ship); now at `8b69cdc` (v3.5 docs only — no code
on main yet for v0.4.0).

The autonomous branch merged main back in (`f92a526`) so the
Dispatcher running there sees v3.5 of PRINCIPLES.md at runtime.
This matters for the loadDispatcher path — the prompt body
includes PRINCIPLES.md verbatim, so the dispatcher reasons over
v3.5 not v3 once the autonomous branch's app is launched.

### D1 — main.swift production wiring

`2aa913e`. Concretely:

- `LoopDispatchStore(database: db)` initialized right after the
  SupervisorDatabase opens (migration v3 already ran during
  init).
- `loadDispatcher(client:trace:)` helper added — mirrors
  `loadQuestionAnswerer`. Same three-candidate-URL PRINCIPLES.md
  loader. Constructs `Dispatcher(client:principlesText:
  issueFetcher:GitHubIssueFetcher, commitFetcher:
  GitBranchCommitFetcher, trace:)`.
- `LoopController(trace:)` instantiated with default thresholds
  (4hr / 3-low). Always present (no external deps).
- All three threaded into the `TriageEngine` constructor:
  `dispatcher: dispatcher, loopController: loopController,
  loopStore: loopDispatchStore`.

Degrade paths preserved: if PRINCIPLES.md isn't found, both
QuestionAnswerer and Dispatcher stay nil and the engine falls
back to plain notify on idle / question-pending. LoopController
is always live so the hard-stop guardrails apply even without
the Dispatcher.

Tests: 227/227 still pass after the wiring (no regressions; D1
is plumbing — behavior coverage lives in DispatcherTests,
ContinueInterventionTests, LoopControllerTests already).

### D2 — deterministic loop smoke (substitute for the live dogfood)

`LoopSmokeTests.swift` — 2 tests that drive the full pipeline
in-process with mocks:

1. **`testThreeConsecutiveHighConfidenceDispatchesWireEndToEnd`** —
   the positive cycle. StagedDispatcher returns three canned
   high-confidence `.ready` results in order; LoopController
   reports priorCount 0/1/2 monotonically across the three
   `canDispatch` calls; InterventionRouter routes each via
   `routeContinue`'s high path → CapturingInjector receives the
   three proposal strings; LoopDispatchStore persists three rows
   with response_shape=ready, confidence=high. Three
   `.continueFired` outcomes captured by MockNotifier.

2. **`testThreeConsecutiveLowsTripStopBeforeFourthDispatch`** —
   the §12.5 #3 guardrail proof. Three `.lowConfidence` returns
   in a row trip the LoopController's threeConsecutiveLow stop;
   the fourth `canDispatch` returns `.stopped(reason: "three_consecutive_low_confidence")`.

What this PROVES end-to-end:

- LoopController state machine works under real call sequence
  (not just the unit-test contracts).
- Dispatcher → router → injector chain wires correctly for
  high-confidence dispatches.
- LoopDispatchStore round-trips the three response_shape /
  confidence / priorDispatchesConsidered combinations correctly
  against a real (in-memory) SQLite DB with the v3 migration
  applied.
- The §12.5 #3 trigger fires when the dispatcher's signal
  pattern matches a thrashing chain.

What it does **NOT** prove (the live-dogfood gaps):

- CGEventPost actually types into a real Claude.app terminal.
  (The v0.3.0 inject canary against FakeClaudeCLI covers
  CGEventPost; the integration is unchanged in v0.4.0, but
  hasn't been re-verified end-to-end through the .continue
  path.)
- Real `gh issue list` returns data that the dispatcher prompt
  reasons over correctly. (Fetcher unit tests cover the shell-out
  + parse; the prompt-reasoning is what the live trial tests.)
- Real Haiku-4.5 produces dispatches that the worked-examples
  section actually teaches for. **This is the most important
  unproved claim in v0.4.0.** The Dispatcher prompt is calibrated
  to no fixtures yet — only to Mohammed's read at the B8
  checkpoint.
- The loop sustains coherent multi-task work across cycles
  rather than improvising. Three high-confidence dispatches in
  a row over 30 min real time is the success criterion; the
  smoke test only proves the wiring carries three through.

229/229 tests pass after Part D (was 227 pre-D2; +2 smoke tests).

---

## Each "dispatch" in this trial — characterized

This is where the spec wants honesty about whether each
dispatch was the right pick. Since the live trial didn't run,
the "dispatches" being characterized are the canned ones in
the smoke test + the runbook's planned dogfood flow:

### Smoke test cycle 1 (canned)

- **Confidence:** high
- **Path picked:** transition_to_issue (Issue #7)
- **Was it the right pick?** Yes by construction — Issue #7 is
  the runbook's named dogfood target; the prompt
  ("Step 1: add the bash-path-isolation guard to
  TriagePrompt.swift's buildRequest. §2e.") cites the exact
  file + §-reference per the prompt's voice rules.

### Smoke test cycle 2 (canned)

- **Confidence:** high
- **Path picked:** continue_branch (tests for the fix from
  cycle 1)
- **Was it the right pick?** Yes — tests are the canonical
  follow-on to new code per the prompt's PATH 1 framing.

### Smoke test cycle 3 (canned)

- **Confidence:** high
- **Path picked:** continue_branch (CHANGELOG for Issue #7)
- **Was it the right pick?** Yes — CHANGELOG is the canonical
  close per §4c; canonical mechanical follow-on after a
  feature ship.

The trial proves the WIRING carries these three through end-to-end.
It does NOT prove that real Haiku would actually pick these three
in this sequence on a real worker. That requires the live trial.

---

## Near-misses (where the loop almost picked wrong)

No near-misses in the smoke test — by construction the canned
responses are correct. The honest version of this section
needs the live trial.

What I **predict** the near-misses will look like, based on
the prompt's design:

- **Cycle 2 near-miss risk:** After cycle 1 ships the fix
  without tests, the dispatcher might pick the CHANGELOG path
  (skip tests). The prompt's PATH 1 rule explicitly names
  tests as canonical follow-on to new code; if Haiku picks
  CHANGELOG instead it's a prompt-doesn't-prioritize-tests
  miss. Watch for: cycle 2 returning a CHANGELOG proposal
  instead of a tests proposal. The smoke test doesn't catch
  this because cycle 2's canned response is the right one.
- **Cycle 3 near-miss risk:** After tests ship, the dispatcher
  might propose a NEW issue rather than the CHANGELOG. PRINCIPLES
  §4c teaches CHANGELOG as canonical close; if Haiku picks a
  new issue, the close discipline didn't ground hard enough.
- **Low-confidence near-miss:** If the issue queue is empty
  AND there's no obvious mechanical follow-on, the prompt's
  Example 4 teaches `.lowConfidence` with empty proposal. If
  Haiku returns `.ready(medium)` with a weak proposal instead,
  the "low confidence is a feature, not a failure" framing
  didn't ground. This is the hardest skill to teach and the
  most likely place the prompt fails.

---

## PRINCIPLES.md gaps surfaced

Per §0, the gap-finding metric matters:

- **0 gaps** from this session's PRINCIPLES read. I didn't hit
  anything the manual doesn't answer.
- §12.5 itself was a known gap from the v0.4.0 spec, not
  surfaced fresh in this session — Mohammed had already
  scoped the section before D0 started.

Target for this trial was 0–1 gaps per §0; this hits the lower
bound. Below baseline (v2 = 2 gaps; v3 = 0 trial-gaps before
this; v3.5 = 0).

**Caveat:** the live trial would surface more gaps because the
Dispatcher would be making real picks on real context. Without
that, the "0 gaps" number is suspect — the trial that hasn't
happened can't have surfaced what it would have.

---

## Honest mistakes this session

- **Over-scoped D2 in my head.** I initially considered launching
  Supervisor.app as a subprocess and running a 30-min live trial
  from this conversation. Wouldn't have worked: Supervisor.app
  needs an installed bundle (codesign + AX permissions), a real
  API key path, and 30 min of wall-clock I can't honestly
  consume without bloating context. Walked it back to the
  deterministic substitute + runbook, which is the right shape
  for what's possible from a chat-and-bash environment.
- **First LoopSmokeTests version captured `clockBox` from a
  Sendable closure** — same Swift-6-actor friction as Part C's
  storedLoopDispatchRow. Dropped the clock injection entirely
  since the 3-dispatch run takes <10ms (far under 4hr); default
  `Date()` works. Caught on first build.
- **`db.queue.write` is `async` in this GRDB version** —
  caught when LoopSmokeTests' session-row insert wouldn't compile
  without `await`. Existing FlagStore code uses the sync form
  inside an actor's queue — GRDB exposes both shapes; tests just
  need the await on the closure.

---

## What surprised me this session

- **D0 was a clean separation.** PRINCIPLES.md on main, code on
  the autonomous branch, merge main back into autonomous. The
  pattern Mohammed established with v3's changelog edits held.
  No PR review needed because PRINCIPLES.md is the operating
  manual — its review surface is the trial's meta-post-mortem,
  not a code review.
- **D1 was 58 lines.** Once Parts A/B/C structured the engine's
  optional dependencies cleanly (questionAnswerer, dispatcher,
  loopController, loopStore — all parallel patterns), the
  production wiring was a copy of `loadQuestionAnswerer` with
  the relevant fetchers, plus two property declarations on
  AppDelegate. Restraint per §1c "wrappers not rewrites" applied
  to bootstrap as well as logic.
- **The smoke test's deterministic guarantee is strong.**
  `LoopSmokeTests` runs in 8ms and proves the FULL wiring
  end-to-end without any network. The only thing it can't
  prove is that Haiku's behavior matches the prompt's intent —
  but that's the only thing that NEEDS a live trial. Everything
  else is mechanical.

---

## Whether the loop produced coherent multi-task work or drifted

**Unknown.** The smoke test produces coherent work by
construction (the canned responses are designed to). The live
trial is what determines this.

The honest answer requires running the runbook. The smoke test
proves the loop's mechanics; the live trial proves the loop's
judgment.

---

## Open questions for Mohammed

1. **Is the in-process smoke test + runbook handoff acceptable
   as the D2 substitute, or does v0.4.0 stay unmerged until you
   run the live trial yourself?** The honest answer per the
   spec's success criteria is "stay unmerged" — the live trial
   is what determines whether v0.4.0 is real product.
2. **Should the Part D D0 commit get cherry-picked into the
   autonomous branch as its own commit (alongside the merge), or
   does the merge commit suffice?** Currently it's just the merge.
3. **If the live trial fails (Haiku doesn't match the prompt's
   intent), is the next session's work (a) calibration fixtures
   for the Dispatcher with a sweep, (b) prompt tuning, or
   (c) both?** §6 says no rubric ships without a corpus —
   strictly read, the Dispatcher's prompt should have a
   fixture-driven sweep before claiming the prompt teaches
   correctly. We deferred that because the prompt is a
   second-stage call (not a rubric category), but the principle
   probably applies.

---

## Cost summary

- API spend this session: $0 (no live calls; all tests use
  mocked URLProtocols + canned StagedDispatcher).
- Tests passing: 229/229 (was 203 before v0.4.0; +26 over the
  three trials this evening).
- Sweeps run: none.
- Spend the live trial will incur (per the runbook): ~$0.50
  worst-case 30-min dogfood. Under §9e's no-signoff tier.

---

## Did the success criteria pass?

Per the v0.4.0 Part D spec's four criteria:

1. **≥3 successful auto-dispatches, all high-confidence.**
   ❌ Not from a live trial. ✓ from the deterministic smoke test
   (in-process equivalent). The honest answer: not proven against
   real Haiku.
2. **Issue #7 completes OR loop stops at a defensible point.**
   ❌ Issue #7 untouched. The runbook calls for it as the live
   target; it's still open.
3. **Zero keyboard touches against the worker.**
   ✓ trivially (no worker was launched).
4. **Honest characterization in this post-mortem.**
   ✓ — this section is the answer.

By the spec's bar, v0.4.0 is **not ready to tag**. It IS ready
for a live trial; the runbook makes that one Mohammed-driven
execution.

The clean failure (a live trial that surfaces a gap) is also
informative per the spec's closing line: "Either outcome is
informative." The live trial would either:
- Succeed → v0.4.0 is real product, tag it.
- Fail with a clear blocker → that becomes the next session's
  work, v0.4.0 ships when the loop holds.
- Fail ambiguously (the dispatcher makes weak picks but doesn't
  trip §12.5 #3) → calibration corpus + sweep per §6, then
  re-trial.
