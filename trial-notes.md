# Trial notes — autonomous-20260525T193906Z

Started: 2026-05-25 19:39 UTC. Building v0.4.0 (continuous
autonomous loop). Operating under PRINCIPLES.md v3 + opener v2.
Mohammed in chat but spec says "Start with A1" — engineering
decisions are mine per §5.

## Reads complete

- PRINCIPLES.md v3 (gap-metric §0 + §2e + §5a-prime + budget §9e)
- AUTONOMOUS_SESSION_PROMPT.md v2

## Scope reality + plan

The v0.4.0 spec is **four parts** (A detection / B dispatch /
C loop control / D dogfood). Realistic per-session ship under
the 75-min opener cap is **Part A only**. Trying to fit A+B+C
into one session would violate §1a (*"fewer features that meet
the spec beats more features that half-meet it"*).

**This session's scope: Part A (idle detection)** — A1 rubric
category, A2 schema additions, A3 timer-driven check, A4
FakeClaudeCLI tests. End-to-end testable, no live dogfood.

**Filed for v0.4.0 Session 2**: Part B (dispatcher).
**Filed for v0.4.0 Session 3**: Part C (loop control + SQLite).
**Filed for v0.4.0 Session 4**: Part D (dogfood ≥30 min).

Hard stop: 20:54 UTC (75 min from branch creation) or any §12
trigger.

## Pre-flight engineering decisions (journaled, not asked)

Per §5 "engineering questions are yours." These are decisions
I'll commit to upfront and document so they're reviewable:

**ED-1. `continue` action placement in `FlagAction` enum ladder.**
PRINCIPLES §3d names the ladder notify → inject → pause → kill.
`continue` types a NEW TASK PROMPT (multi-paragraph; triggers
hours of follow-on work) — strictly heavier than `inject`
(types ≤200 chars of answer; doesn't change the worker's task).
Placing `continue` between `inject` and `pause` preserves the
"lightest action that fits" framing — pause is more intrusive
(stops the session) but continue is closer to a structured
nudge than a stop signal. Ladder becomes:
notify → inject → continue → pause → kill.

**ED-2. Per-session idle state machine.** Idle detection is
per-session (each tailed JSONL). State: `{lastEventTs, lastStopShapedTs,
lastUserMsgTs, isOnAutonomousBranch}`. Polling at 1Hz per active
session is cheap. Storing the state in TriageEngine alongside
sessionCwd (the §6 cache from v0.3.1) keeps the persistence
shape consistent.

**ED-3. "Stop-shaped event" detection.** Looking at the JSONL,
Claude Code emits assistant text + tool calls + sometimes a
`stop_reason: end_turn` annotation. The cheap heuristic: an
assistant text whose body contains any of {"done", "complete",
"ready for next", "what's next", "let me know if", "ship it"}
OR a JSONL line whose top-level `type` includes a `stop_reason`
of "end_turn" with no follow-up tool_use within the same turn.
Substring search for the phrase list per §11b (specific
signatures over abstract behavior).

**ED-4. Don't-fire conditions** are codified in the rubric
body, not in code. The rubric is the contract per §5 "safety
defers to the rubric." The code-level idle check is timer-driven
(per A3) and ONLY emits the candidate events for triage — the
rubric body decides whether to fire.

## Plan

### Session proposal — 2026-05-25 19:39 UTC

#### Candidate 1 — Part A (idle detection) — picked

- **Source**: Mohammed's v0.4.0 spec, Part A. Pre-committed.
- **Smallest fix**: rubric category + verdict-schema additions
  + timer trigger + 5 FakeClaudeCLI tests. ~250 LOC.
- **Proper fix**: same. The smallest fix IS the fix (per the
  spec's enumerated A1-A4 acceptance criteria).
- **Estimated scope**: 60-70 min.
- **Dependencies**: None (no API budget for the build; tests
  use FakeClaudeCLI which is already in the repo).
- **Why now**: The whole v0.4.0 product chain (B, C, D) gates
  on A. Without idle detection there's no signal to dispatch
  on, nothing to journal, nothing to dogfood. A is the
  blocking-prerequisite step.

#### Candidate 2 (deferred to next session) — Part B (dispatch)

Would build the second-stage Haiku call that proposes the next
task. Depends on A being shipped + a calibration corpus for
worker_idle_post_completion (§6a requires ~40+40+20 fixtures).
Estimated scope: 90+ minutes including the corpus. Out of
75-min budget.

#### Pick

**Going with Candidate 1.** Part A blocks all other parts;
deferring it doesn't unlock parallel work. Per §1a, ship the
vertical slice that's complete (A) rather than four half-built
slices.

Hard stop at 20:54 UTC (75 min from branch creation) or any
§12 trigger.

## Log

### A1 — rubric category (done)

- Added `FlagAction.continue` to StorageModels.swift, placed
  between `.inject` and `.pause` per ED-1. Backticked because
  `continue` is a Swift reserved word.
- Added `workerIdlePostCompletion` RubricCategory in
  HardcodedRubric.swift with full body covering fire / don't-fire
  conditions, severity rule (always medium), action rule
  (HIGH→continue, MEDIUM→notify propose-and-wait, LOW→notify
  surface) per §7d.
- Updated `categories` array to include the new category.
- Router fix: added `.continue` case to InterventionRouter — for
  v0.4.0 Part A it degrades to `notify` with trace tag
  `intervention.continue.degraded reason=dispatcher_not_wired_in_part_a`
  since Part B (the actual dispatcher) is a future session.
- HoverView icon switch updated for exhaustiveness (`.continue`
  groups with `.inject`/`.notify` — no overlay icon).

### A2 — schema additions (done)

- Added `next_task_proposal` (string) and `confidence`
  (enum high/medium/low) to `record_triage` schema in
  TriagePrompt.swift.
- Added `continue` to `recommended_action` enum + updated its
  description to mention the worker_idle_post_completion path.
- Extended TriageCandidate struct with `nextTaskProposal: String?`
  and `confidence: String?` fields + init params.
- Extended `parseCandidate` in TriageEngine: required-for-category
  pattern (parallel to questionType). `confidence` defaults to "low"
  if missing/invalid (safer-fallback rule: low → no auto-dispatch).
  `next_task_proposal` stays nil if missing — Part A intentionally
  ships without the dispatcher; Part B populates it.
- Updated `reconfigure` helper to preserve the new fields.

### A3 — timer-driven idle check (done)

- Added `SessionIdleState` struct + `idleStates` per-session map
  to TriageEngine. Tracks lastEventTs, lastStopShapedTs,
  lastStopShapedPhrase, lastUserMsgTs, lastIdleTriageTs.
- Added `sessionBranch` cache alongside the existing `sessionCwd`
  cache (v0.3.1 Issue #6 shape) — branch is read on sessionStart
  and consulted by the idle evaluation so the rubric body can
  apply the non-autonomous-branch don't-fire condition.
- Added `now` injected clock + `idleThresholdSeconds` (15s),
  `idleReTriageIntervalSeconds` (60s), `idleCheckIntervalSeconds`
  (1s) constructor params.
- Added `detectStopShape(in:)` static helper with the ED-3 phrase
  list (case-insensitive substring match).
- Added `updateIdleState(for:)` — mutates idle state per event:
  userPrompt clears stop-shape, bashToolCall clears stop-shape,
  assistantText with stop-phrase sets it, any event resets the
  re-triage gate.
- Added `startIdleCheckLoop()` — a @MainActor Task with
  `try? await Task.sleep` loop calling `checkIdleStates()` at 1Hz.
  Cancelled by `stop()`.
- Added `checkIdleStates()` (internal-visible so tests can drive
  ticks): walks idleStates, applies silence-gate + re-triage gate,
  dispatches `evaluateIdle(sessionId:)`.
- Added `evaluateIdle(sessionId:)` — parallel to evaluateAssistantText.
  Builds buildIdleEvaluationRequest, calls Haiku, emits flag via
  the synthetic-trigger bridge so existing TriageDecision plumbing
  works unchanged.
- Added `buildIdleEvaluationRequest` in TriagePrompt.swift — passes
  cwd, branch, user prompt, stop-phrase, silence-seconds, recent
  events to Haiku and scopes evaluation to worker_idle_post_completion.

### A4 — tests (done)

New file: `Tests/SupervisorCoreTests/IdleDetectionTests.swift` —
6 tests, all green:

1. `testIdleDetectionFiresAfterStopShapePlusFifteenSeconds` —
   positive happy path. canned Haiku returns flag; engine emits
   decision with category=worker_idle_post_completion,
   action=continue, confidence=high, next_task_proposal populated.
2. `testIdleDetectionDoesNotFireWhileEventsStillFlowing` —
   silence-gate negative: keep emitting non-stop assistantText
   events so lastEventTs advances; idle check stays gated.
3. `testUserPromptClearsStopShape` — engine state machine:
   userPrompt resets lastStopShapedTs → idle check stays gated.
4. `testToolUseClearsStopShape` — engine state machine:
   bashToolCall resets lastStopShapedTs → idle check stays gated.
5. `testIdleDetectionRespectsRubricNoFire` — rubric deference (ED-4):
   canned all-clear → engine emits no decision even though all
   engine-level conditions hold. Validates the dispatch DID happen
   (rubric got to vote) but no flag fired.
6. `testDetectStopShapeMatchesEachED3Phrase` — unit coverage of
   the substring matcher on every ED-3 phrase, plus negatives.

### Test isolation gotcha

First run: testIdleDetectionRespectsRubricNoFire got requestCount=2.
Cause: unstructured `Task { await evaluateIdle(...) }` from the
PREVIOUS test's `checkIdleStates()` outlives the test and its HTTP
call fires during the NEXT test, bleeding requestCount across the
shared static counter. Fix: make `setUp`/`tearDown` async and
`try await Task.sleep(200ms)` to drain in-flight Tasks. Production
isn't affected — the same Task structure is correct for the live
engine; the test harness just needs an explicit settle point.

### Build / tests

- `swift build` — clean.
- `swift test` — 203 / 203 pass (5 skipped: LIVE_API canaries
  that need real keys, unrelated to Part A).
- Total diff: 7 files, +678 / -134.

### What's deferred (per session plan)

- Part B (dispatcher): builds the second Haiku call that
  constructs the next-task prompt body + CGEventPosts it.
  Currently the router's `.continue` case degrades to notify.
- Part C (loop control + SQLite persistence + §12 hard-stops).
- Part D (≥30 min dogfood loop on Issue #7).
- v0.4.0 CHANGELOG entry — wait until B/C ship; Part A is half
  the product surface, not a full release.

### Cardinal-rule check

- No commits yet. No push. Branch `autonomous-20260525T193906Z`
  has unstaged changes only.
- Per Mohlt PROTOCOL, awaiting explicit "commit" / "ship it" in
  chat before any send.

## Part A summary — for the next session

**Status:** shipped to branch `autonomous-20260525T193906Z`. Not
merged to main. v0.4.0 is half-built; Parts B/C/D remain.

**What the next session inherits:**

- `FlagAction.continue` exists in the enum + is plumbed through
  `InterventionRouter` (currently degrades to `notify` — the
  hand-off point for Part B's dispatcher is the `.continue` case
  with trace tag `intervention.continue.degraded
  reason=dispatcher_not_wired_in_part_a`).
- `record_triage` schema accepts `next_task_proposal` + `confidence`.
  `TriageCandidate` carries those fields end-to-end. In Part A the
  primary call is the only thing populating them; Part B adds a
  secondary "dispatcher" call that reads `next_task_proposal` as
  the seed and writes back the full multi-paragraph prompt body.
- `TriageEngine` has per-session idle state + a 1Hz timer that
  fires `evaluateIdle(sessionId:)` when stop-shape + 15s of silence
  hold. Re-triage gated by `idleReTriageIntervalSeconds` (60s) so
  non-firing sessions ping once a minute, not 60 times.
- The rubric body in `HardcodedRubric.workerIdlePostCompletion`
  owns all don't-fire conditions per ED-4 — branch-name, pending
  user_question_pending, recent user message, hard-stop preconditions.
  Engine emits the candidate; rubric decides.

**Four engineering decisions journaled (re-read before changing):**

- **ED-1.** Ladder is `notify → inject → continue → pause → kill`.
  Continue is heavier than inject (multi-paragraph new task vs.
  ≤200 chars of answer) and lighter than pause (structured nudge
  vs. stop signal).
- **ED-2.** Idle state is per-session, stored in `TriageEngine`
  alongside the existing `sessionCwd` cache. 1Hz polling via a
  @MainActor Task loop (not Timer.scheduledTimer) so it integrates
  with structured concurrency.
- **ED-3.** Stop-shape via case-insensitive substring match on a
  short phrase list (`ready for next`, `what's next`, `let me know
  if`, `let me know`, `ship it`, `all done`, `complete`, `done`).
  Specific signatures over abstract behavior, per §11b.
- **ED-4.** Don't-fire conditions live in the rubric body, not in
  code. Engine emits the candidate event; rubric decides. The cheap
  engine-side gate is just stop-shape + silence threshold — to
  keep API spend bounded, not to make safety judgments.

**Test-isolation gotcha (don't repeat):**

`Task { await self.evaluateIdle(...) }` in `checkIdleStates` is
unstructured — its HTTP call can outlive the test that scheduled
it. Without an async drain in `setUp`/`tearDown`, the static
`requestCount` in the URLProtocol mock bleeds across tests.
`IdleDetectionTests` solves this with a 200ms sleep in both
`setUp` and `tearDown`. Production isn't affected.

**Parts B/C/D scope (filed for follow-up sessions):**

- **Part B — Dispatch.** Second Haiku call that reads
  `next_task_proposal` + session context + open issues + STATUS.md
  + PRINCIPLES.md and writes a multi-paragraph prompt body, then
  CGEventPosts it into Claude.app. Wire this into the
  `.continue` case in InterventionRouter (replace the degrade
  branch). Acceptance: 4 tests for continue-current-branch,
  transition-to-next-issue, low-confidence-no-pick, dispatcher
  meta-prompt schema.
- **Part C — Loop control.** Extend §12 hard-stops (4hr elapsed,
  3 consecutive low-confidence dispatches, task requires user
  input, user message → loop pauses). Continuous trace log with
  every dispatch + confidence. New SQLite table `loop_dispatches`.
- **Part D — Dogfood.** Set the loop running on Issue #7 (bash
  cross-category bleed). Run ≥30 min uninterrupted. Success metric:
  ≥3 sequential high-confidence dispatches, no user copy-paste.
  If it completes Issue #7 without user input, that's the moment
  v0.4.0 is the product.

**Pre-commit state:**

- 7 files modified, 1 new test file. +678 / -134 lines.
- `swift build` clean. `swift test` 203 / 203 (5 LIVE_API canaries
  skipped — they need real keys, unrelated to Part A).
- About to commit per Mohammed's chat instruction: 2 commits
  (impl + tests separated; impl interleaved across schema +
  timer too tightly to split cleanly per §1e judgment call).

---

# Part B — dispatch (continuing on the same branch)

Started: 2026-05-25 20:44 UTC. Continuing v0.4.0 build on
branch `autonomous-20260525T193906Z` per Mohammed's "extend
Part A" instruction. Hard stop: 21:59 UTC (75 min from now)
or any §12 trigger.

## Reads (this session)

- PRINCIPLES.md v3 (re-read — still §1e, §2c, §3a, §6, §9e
  govern the plan).
- AUTONOMOUS_SESSION_PROMPT.md v2.
- QuestionAnswerer.swift (the pattern to mirror — same
  Sendable + tool-forced shape).
- InterventionRouter.swift (the .continue case to replace).
- Notifier.swift (the InterventionOutcome cases to extend).
- TriageEngine.swift evaluateIdle (where the Dispatcher hooks in).

## STATUS-vs-reality diff

- STATUS docs aren't relevant here — Mohammed's chat spec IS
  the STATUS for v0.4.0. Part A shipped; Part B is the next
  filed unit.

## Pre-flight engineering decisions

- **ED-5. Dispatcher REPLACES candidate fields, not augments.**
  The primary triage call (record_triage) may populate
  next_task_proposal/confidence, but Part A intentionally
  left them nil/low; the rubric body's job is "is this idle"
  (yes/no), not "what should we dispatch." The Dispatcher's
  job is the latter. After the Dispatcher returns, the engine
  builds a NEW TriageCandidate via reconfigure() with the
  authoritative values + action set per confidence (high →
  .continue, medium/low → .notify). One source of truth: the
  Dispatcher.
- **ED-6. gh + git fetchers degrade silently to empty arrays.**
  10s timeout each, in-memory caches (60s for issues, 30s for
  commits — issues change rarely, commits per-session-burst).
  If either fails (gh not installed, network down, not in a
  repo), Dispatcher still runs — with empty arrays as
  context. The Dispatcher prompt is taught to lower confidence
  when context is thin, so degradation surfaces as
  medium/low rather than wrong dispatches.
- **ED-7. Inject path for .continue reuses the .inject
  pattern in InterventionRouter** (locator → CGEventPost →
  Injector). Same error surface (InjectError → discriminating
  trace tags). Banner shape differs: .inject succeeded says
  "Supervisor answered"; .continue says "Supervisor
  dispatched: <first 80 chars>...". New InterventionOutcome
  cases.
- **ED-8. Two-call cost.** Dispatcher adds a second Haiku
  call per idle-fire. Estimated 4-6k tokens input (PRINCIPLES
  + session window + issues + commits) + ~500 tokens output
  → ~$0.005-0.008 per dispatch at Haiku 4.5 rates. Comfortably
  under §9e's $0.50 autonomous envelope; logged via the
  existing CostStore.recordHaiku path.

## Plan

### Candidate 1 — Part B (dispatcher) — picked

- **Source**: Mohammed's chat spec (this session).
- **Smallest fix**: Dispatcher.swift + IssueFetcher + BranchFetcher
  + router wiring + 6 tests. ~700 LOC.
- **Proper fix**: same as smallest. The smallest fix IS the fix.
- **Estimated scope**: 55-65 min (B1-B7); STOP at B8.
- **Dependencies**: gh CLI + git on PATH (degrade if absent).
  PRINCIPLES.md (already loaded via loadQuestionAnswerer pattern).
- **Why now**: Part A is half-product; Part B is the dispatch
  layer that closes the loop. Without it .continue degrades
  to notify, which is what we already have today via plain
  notify on idle. Part B is what makes v0.4.0 a product.

#### Pick

Going with Candidate 1. No alternatives — Mohammed scoped
this session as Part B.

## Log

### B1 — Dispatcher module (done)

- `Sources/SupervisorCore/Triage/Dispatcher.swift`. Mirrors
  QuestionAnswerer's shape: takes LLMClient + principlesText +
  optional fetchers; exposes `dispatch(context:)` (pure) and
  `dispatchForIdleSession(...)` (does its own concurrent fetches).
- Result types: `DispatchResult.ready(prompt, just, conf, path,
  issueN?) | .lowConfidence(reason) | .error(reason)`.
- `Dispatching` protocol on top so the engine can take a mock in
  tests.
- Defensive normalization in dispatch(context:) — Haiku-returned
  confidence=.low OR selected_path=low_confidence_no_action both
  collapse to `.lowConfidence` regardless of prompt text. The
  router never sees a half-confidence proposal.

### B2 — issue/commit fetchers (done)

- `Sources/SupervisorCore/Triage/DispatchFetchers.swift`.
- `IssueFetching` + `BranchCommitFetching` protocols.
- `GitHubIssueFetcher` actor: shells out to `gh issue list --json
  ... --limit 50 --state open`, parses JSON, 60s cache per cwd.
- `GitBranchCommitFetcher` actor: shells out to `git log
  main..<branch> --pretty=format:%H%x00%s%x00%b%x1E --no-merges`,
  parses, 30s cache per (cwd, branch).
- Shared `runProcess` helper: 10s hard timeout via TaskGroup
  race; subprocess terminated on timeout; FetcherError discriminates
  toolNotInstalled / nonZeroExit / timedOut / parseFailure.
- Trace tags per spec: `dispatch gh issues fetched count=... latency=...ms`,
  `dispatch git commits fetched count=... latency=...ms`.

### B3 / B4 — prompt + schema (done)

- System prompt explicitly enumerates PATH 1 (continue_branch),
  PATH 2 (transition_to_issue), low_confidence_no_action;
  hard-constraints (§1d "file an issue, don't build the feature
  now"); the next_task_proposal voice rules (autonomous opener
  shape, §11 voice, §12 hard-stop reminder, 200-600 words).
- record_dispatch tool schema forced via tool_choice. Fields:
  next_task_proposal, justification, confidence (enum), selected_path
  (enum), selected_issue_number (required when path=transition).
- Parser defensive: missing required → nil → engine maps to .error.

### B5 — router wiring (done)

- `Sources/SupervisorCore/Intervention/InterventionRouter.swift`.
- Replaced the Part A "degrade to notify" with `routeContinue` +
  `continueHighInjectOrDegrade` + `continueDegradeToMedium`.
- New InterventionOutcome cases in Notifier.swift:
  - `.continueFired(pid, bytes, promptHead)` — high-confidence
    inject succeeded; banner shows first 80 chars.
  - `.continueProposedMedium(proposal, justification)` —
    medium-confidence or high+locator-fail; banner shows full
    proposal so user pastes.
  - `.continueLowConfidence(reasoning)` — low-confidence banner
    with dispatcher's reason.
- Banner bodies wired in Notifier.body(for:outcome:).
- High-confidence with locator failure degrades to .continueProposedMedium
  (NOT .continueLowConfidence — we still have the proposal text).
- High-confidence with empty proposal degrades to .continueLowConfidence
  (defensive — Dispatcher contract guarantees prompt-on-high but
  belt-and-suspenders).

### B6 — engine wiring (done)

- `TriageEngine` takes `dispatcher: (any Dispatching)?` constructor
  param (parallel to questionAnswerer).
- `evaluateIdle` calls `dispatchAndRemap` AFTER the rubric fires
  a worker_idle_post_completion candidate. The Dispatcher's
  result REPLACES the candidate's nextTaskProposal + confidence
  + asymmetryNote (carries the dispatcher justification); action
  is set to .continue for ready/lowConfidence (router branches
  on confidence) and .notify on .error (fall back to plain idle
  notify).
- `reconfigure` extended with `Optional<...>?` sentinel pattern
  so callers can distinguish "leave alone" from "blank out the
  field" — needed because low-confidence dispatches must blank
  any rubric-set proposal text.

### B7 — tests (done)

- `Tests/SupervisorCoreTests/DispatcherTests.swift` (6 tests):
  - testDispatcherReturnsReadyOnHighConfidence — spec test 1
    prerequisite.
  - testDispatcherNormalizesLowConfidenceToLowConfidenceResult —
    spec test 2 prerequisite.
  - testDispatcherProceedsWithEmptyIssuesWhenFetcherThrows —
    spec test 4 (gh failure).
  - testDispatcherTransitionPathPopulatesIssueNumber — spec test 6.
  - testDispatcherReturnsErrorOnMalformedResponse — defensive.
  - testSystemPromptCarriesCoreConstraints — §2c "prompt is code"
    snapshot test catches drift on key voice/content invariants.
- `Tests/SupervisorCoreTests/ContinueInterventionTests.swift`
  (7 tests):
  - testContinueHighConfidenceInjectsProposal — spec test 1.
  - testContinueMediumConfidenceProposesViaBanner — spec test 3.
  - testContinueLowConfidenceShowsReasoningBanner — spec test 2.
  - testContinueHighConfidenceDegradesToMediumOnLocatorFailure —
    spec test 5.
  - testContinueHighConfidenceWithoutProposalDegradesToLowConfidence
    — defensive (Dispatcher contract violation).
  - testContinueHighConfidenceTruncatesBannerHeadButInjectsFullProposal
    — banner-head truncation while preserving full inject payload.

### Build / tests

- `swift build` — clean.
- `swift test` — 215 / 215 pass (was 203 in Part A; +12 from
  Part B). 5 LIVE_API canaries still skipped, unrelated.

### B8 checkpoint pending

- Holding before commits / push / Part C+D.
- Surface the system prompt + record_dispatch schema + example
  next-prompts to Mohammed for approval.
- Per the spec: "the prompt IS the product" (§2c) — same
  checkpoint pattern as the v0.1.2 OnboardingScene review.

