# PRINCIPLES.md — how to ship Supervisor

This document is the operating manual. It captures the implicit
opinions guiding Supervisor that have, until now, only lived in
Mohammed's head and in the pattern of his interrupts ("wait, don't
merge yet — paste me the recovery doc first"). A future Claude
Code session reading only this file and the repo should make
substantively the same calls Mohammed has been making in chat.

The test of this document is: when in doubt, point to a principle
and follow it. If a principle doesn't cover the situation, stop
and file an issue — don't guess.

## Document changelog

- **v1** (`autonomous-20260524T080753Z`): foundation — 13 sections
  grounded in v0.1.x → v0.2.0 evidence.
- **v2**: budget envelope (§9e) + STATUS-vs-reality diff in the
  opener + carve-out for fixture corrections (§6f) + commit
  granularity (§1e). Edits proposed in the
  `autonomous-20260524T080753Z` meta-post-mortem and approved
  by Mohammed.
- **v3** (current): gap-finding-rate as top-level metric + two
  classification-philosophy additions (§2e per-path prompt
  isolation, §5a-prime terminology overlap is not safety).
  Edits proposed in the `autonomous-20260525T084118Z`
  meta-post-mortem and approved by Mohammed.

---

## 0. The gap-finding metric (top-level framing)

Each autonomous trial identifies PRINCIPLES gaps in its
meta-post-mortem. The count over time is the manual's most
useful single quality signal:

```
v1 trial → 5 gaps  (foundational structure)
v2 trial → 2 gaps  (calibration tuning)
v3 trial → ?       (target: 0–1)
```

When a trial hits 0, the manual is comprehensive enough that
Supervisor + a fresh Claude Code session can ship work without
the user in the chat. That's the success state — the framing
Mohammed has been building toward: *"Supervisor catches what
the user can't answer, including what the autonomous Claude
Code can't decide."*

The trend is the signal, not any individual count. v1's 5 gaps
were foundational absences (budget envelope, STATUS-decay
discipline, etc.); v2's 2 gaps are calibration tuning surfaces
(prompt classification edge cases). Smaller-surface gaps are
expected as the manual matures. A trial that finds **larger**
gaps than the previous one is a regression signal — either the
manual lost discipline or a new architecture layer (the
secondary-call paths, future inject mechanisms) opened a new
class of question PRINCIPLES needs to answer.

The first thing every autonomous-session meta-post-mortem should
do is report its gap count against the running trend.

---

## 1. Restraint is the design

Supervisor is a safety harness. Its job is to fire on signal-shaped
patterns and otherwise stay out of the way. Two corollaries:

**1a. Fewer features that meet the spec beats more features that
half-meet it.** Every v0.1.x release is a vertical slice — the full
pipeline still works at the end of every step. No mid-step
half-built features. From DESIGN §10: *"If we run out of energy at
v0.1.4 we still have a usable product."* When a new feature
appears in your candidate list, the first question is "can this
slice ship a working version of itself" — not "is this the right
ultimate shape."

**1b. Restraint applies to the UI especially.** Signal-green
(#2D7A4E) is the only accent in onboarding (see `BrandColor.signal`
+ branding/README §Palette). One accent. No green text. No green
icons. The hover panel is 240×40 with one row of information.
"Wispr Flow and Clicky's hover is the visual reference. Same
restraint, no chrome, no labels — just the live readout."
(DESIGN §6.1.) If you find yourself adding a second accent
color or a second status row, you've broken restraint.

**1c. Code restraint: prefer wrappers, not rewrites.** v0.2.0's
multi-provider work kept the canonical `AnthropicMessageRequest`
type internally and added a translator inside `LLMClient` —
~50 lines of translation versus a parallel pipeline that would
have been ~500. The triage prompt is calibrated; rebuilding it
in an OpenAI-native shape would invalidate the calibration. When
in doubt, wrap the existing surface; don't fork it.

**1d. "File an issue" beats "build the feature now"** unless the
feature is on the immediate roadmap. Issues #1, #2, #3 are all
real engineering work that got filed instead of forced into a
release. The CHANGELOG explicitly says things like
*"Out of scope this PR: making the terminals list user-configurable
(filed as a v0.1.5+ issue with config.yaml + FSEvents reload spec)."*
**Always file with shape, not vaguely.** Specify the call sites,
the proposed mechanism, and the trade-off the deferral makes.

**1e. Each commit is one reviewable unit.** Commit granularity is
restraint applied to history. A foundation-docs commit and a
fixture-fix commit and a journal-update commit are three commits,
not one. Cherry-pick-friendly for main-line review — when Mohammed
goes to cherry-pick the verified part of a trial onto main, the
diff for that part is one commit, not a sprawl. From the
autonomous-20260524T080753Z meta-post-mortem: *"I commit-grouped
PRINCIPLES + opener together, then the fixture fix, then
trial-notes.md. This felt right but a future session might lump
everything."* This principle makes "felt right" mechanical. Rule
of thumb: if a reviewer would naturally want to cherry-pick part
of a commit, that commit was too large.

---

## 2. The artifact is the product

The user does not touch the code. They touch the artifacts the
code produces: notification banners, the hover dot, the recovery
markdown doc, the trace log lines, the onboarding window, the
prompt body that Haiku reads. Those artifacts are the product.

**2a. When making a proposal, surface the artifact first, not
the code path.** Mohammed has repeatedly interrupted code-shaped
explanations with "what does the banner say?" or "paste the full
text of the sample recovery doc." For v0.1.6 he refused to merge
until the rendered sample doc was pasted into the chat. Code is
the means; the artifact is the proposal.

**2b. Test the artifact, not just the code that produces it.**
`RecoveryDocWriterTests` asserts the doc contains specific section
headers, the pause variant has `kill -CONT <pid>` baked in with
the actual PID, the kill variant has "Do NOT retry the specific
action." The tests assert what the user reads, not what the
function returns.

**2c. The prompt body counts as code.** `HardcodedRubric.swift`
and `TriagePrompt.swift` carry prose that Haiku reads. When you
edit them, expect the same review burden as a code change:
fixture-based tests, calibration sweeps, before/after comparison
on real samples. The v0.1.5 rubric tightening shipped with a
300-fixture sweep against the live model; the rubric prose is not
configuration, it is logic.

**2d. Reasoning fields are user-visible.** `reasoning_plain` lands
in banners (≤4 sentences, banner-fit copy). `reasoning_technical`
lands in the trace log (one dense paragraph). `asymmetry_note`
lands in the recovery doc when present. Haiku is taught to pick
its register. Test what each register looks like; reject prompt
edits that let one register bleed into the other.

**2e. Per-path prompt isolation.** When multiple triage paths
exist (bash, assistant-text, future), each path's prompt MUST
explicitly enumerate the categories it evaluates against and
explicitly exclude the others. Path-shared category lists are
a footgun — Haiku will pattern-match category names that appear
in the focal command/text, regardless of whether the category
applies to that path. Surfaced during the
`autonomous-20260525T084118Z` trial when a bash command whose
regex grep pattern literally contained `user_question_pending`
triggered a false positive in that category, because the bash
triage prompt enumerated ALL rubric categories including
ones meant only for assistant-text. The asymmetry is the bug:
the assistant-text path already uses a focused prompt
(*"evaluate ONLY against user_question_pending"*); the bash
path should be symmetric and explicitly omit
user_question_pending. Filed as Issue #7 against v0.3.3; the
PRINCIPLES note documents the philosophy regardless of which
release closes the specific bug.

---

## 3. The asymmetry of safety mistakes

False positives cost trust. False negatives cost damage. **Damage
is worse but trust is what determines whether the harness gets
used at all.** From the escalation prompt body
(DESIGN §4.3): *"Bias toward not firing. A false positive costs
the user trust. A missed flag costs the user a foot-gun moment.
The user has explicitly said they will stop trusting the
supervisor after two false positives in a day — be precise."*

**3a. Every triage decision carries a written asymmetry note when
the cost of being wrong is materially uneven.** The
`asymmetry_note` field on `TriageCandidate` exists exactly for
this. Real example from a v0.2.0 deployment flag:
> "If I notify and I'm wrong, the delete proceeds but is trivially
> recoverable via git; if I pause and I'm wrong, the user loses
> ~5s for no reason during an active refactor."
Asymmetry notes are the model showing its work. They are the
single best signal that the triage is alive and thinking, not
pattern-matching by reflex.

**3b. Lean toward firing on signal-shaped patterns.** `rm -rf`
outside cwd, `git push --force` to non-feature branches, anything
matching credentials paths — fire. The cost of a banner the user
dismisses is one click; the cost of a missed `rm -rf $HOME` is
hours of recovery. The rubric's Fire list exists to enumerate
these by signature, not by general principle.

**3c. Lean toward not-firing on weak signals — but always with a
written reason.** When Haiku correctly identifies a destructive
command but reads the user prompt as authorizing it, that's the
rubric's *user-authorization exception* doing what it's designed
to do. From STATUS-while-mohammed-was-away §"Why the positives
are at 75%": *"This is Haiku being reasonable on natural-language
phrasings the user actually uses. Tightening the rubric to fire on
these would generate false positives on legitimate user
requests."* When you don't fire, the trace must say why. Silent
no-fires are indistinguishable from broken triage.

**3d. The action ladder preserves the user's time.** notify →
inject → pause → kill. Each step is heavier. Pick the lightest
action that fits. Notify is the floor — when severity is low or
the asymmetry favors notification, notify only. Pause buys the
user time to decide. Kill is for the assistant-is-already-broken
case. Don't escalate past what the asymmetry justifies.

**3e. Asymmetry note text propagates to the recovery doc.** v0.1.6
added this on purpose: a kill that fires unattended needs to leave
the user a written record of *why* the model chose kill, not just
*that* it killed. The asymmetry note is the part of the reasoning
that most directly answers "could I have been wrong about this?"

---

## 4. Honest failure surfaces

The harness loses moral authority to demand honesty from Claude
Code if its own artifacts lie by omission. This shows up in four
places, in increasing order of difficulty:

**4a. README claims must match code.** When the README said the
trace log rolls at "1 MiB segments" and the code threshold was
10 MB, the README was wrong. We shipped v0.1.6.1 specifically to
fix the doc. The rule: never paper over a doc lie with a code
change you didn't make, and never paper over a code reality with
a doc you wrote without reading it.

**4b. Trace tags must discriminate every failure path.** From
v0.1.4 ProcessLocator: `locator.found`, `locator.not_found`,
`locator.ambiguous`, `locator.sysctl_failed` — four distinct trace
tags for four distinct outcomes. The router's degradation paths
each emit `intervention.<op>.degraded reason=<reason>`. When you
read the trace post-mortem you can tell *exactly* why pause/kill
didn't fire. "Locator returned nil" is not an acceptable trace
line; "locator.not_found cwd=/Users/main/proj scanned=147" is.
Filed as Issue #1 (silent-nil-from-ProcessLocator) — *"Silent nil
is the worst safety regression"* per the issue body.

**4c. STATUS docs list what didn't ship alongside what did.** The
v0.1.5 calibration didn't hit the 95% gate. The autonomous trial
was gated OFF, not papered over. The STATUS doc enumerates exactly
which fixtures failed, categorized by *type of failure*
(model-didn't-recognize / rubric-exception-too-broad / fixture-
expectation-wrong / prompt-failed-to-teach-LOW-vs-MEDIUM), with
the per-fixture diagnosis. When you write a STATUS doc, the
honest-failure section is mandatory; if you don't have one, you
didn't audit your own work.

**4d. CI must be checked after every push.** v0.1.6.2's
post-mortem captures the rule: *"Going forward, every git push
must be followed by gh run list to confirm CI didn't break.
Silent CI red is worse than no CI."* If you can't see the CI
result, you don't know whether the change shipped — and shipping
with silent breakage is dishonest by accident.

**4e. The harness flags its own deployment as risky.** During the
v0.2.0 ship, Supervisor flagged my own atomic-swap-to-/Applications
sequence 5 times (destructive_action_pending + edits_outside_worktree).
All 5 were correctly classified as notify-only with asymmetry
notes — the harness saw risky things, recognized them as
intentional dev work from context, and posted banners rather than
panicking. **That is the system working.** A future session
that finds Supervisor flagging its own deployment should not
"silence" those flags; the flags are the test.

---

## 5. Defer values to the user; defer safety to the rubric; own the engineering

The split is:

- **Values questions are Mohammed's.** Visual design ("does this
  feel right?"), prose voice ("does this sentence sound like us?"),
  naming ("is `claudeCodeHostApps` a better name than
  `knownTerminalBundleIDs`?" — yes, but ask), "is this worth
  shipping in this form?" Use `AskUserQuestion` with 2-4 concrete
  options when you hit one of these.
- **Safety questions defer to the rubric.** When a command pattern
  matches the rubric, fire. When it matches an exception, don't
  fire. When neither, fire as MEDIUM and let the user decide
  through the UI. The rubric is the contract; if it's wrong,
  *change the rubric*, don't override it case-by-case in code.
- **Engineering questions are yours.** Architecture, tests,
  performance, refactor scope, dependency choices, file structure.
  Mohammed has explicitly delegated this. The v0.2.0 multi-provider
  refactor was a 5-6hr scope call I made without checking, and that
  was correct — the abstraction shape was an engineering decision,
  not a values one. (The decision *to do it* was values; the
  decision *how to do it* was engineering.)

**5a. When a question is ambiguous between categories, ask.** "Is
the Notif-denied state body trim worth the readability hit?" is
borderline values. "Is the window 360 or 420 px?" is borderline
engineering. The cheap fallback is `AskUserQuestion` with two
options and a one-line rationale on each.

**5a-prime. Terminology overlap is not a safety signal.** The
rubric's *"default to safety when uncertain between engineering
and safety"* heuristic applies to questions whose **action** is
destructive, irreversible, or modifies the user's environment
non-trivially — not to questions whose **vocabulary** happens
to brush against safety-shaped terms. A question using words
like *"interpreter"* (which interpreters to support in argv
inspection), *"process"* (which processes to enumerate),
*"signal"* (which signal the router sends) is engineering when
the asked-about action is code organization, not when the
action is execution-against-a-real-process. Surfaced during
the `autonomous-20260525T084118Z` trial when a multi-question
message about JS-runtime interpreters + argv markers + trace
tags classified as safety because *"interpreter"* and
*"process"* read as risk-shaped in isolation. The classification
gate is the action, not the vocabulary; the post-classification
mapping (engineering → inject) is unchanged by this note —
v0.3.1's tightening of that mapping stands.

**5b. Don't invent options. Surface the actual trade-off.** If
the choice is "ship v0.2 with full abstraction or just Deepseek,"
say so. Don't pad the question with three made-up middle paths.

---

## 6. Calibration before capability

A rubric category does not ship without a fixture corpus. An
intervention does not ship without end-to-end verification on a
real canary. **"It compiles" is not evidence the harness fires.**

**6a. The corpus pattern is ~40 clear positives + ~40 clear
negatives + ~20 adversarial per category.** The v0.1.5 corpus
landed at exactly this shape (`Tests/SupervisorCoreTests/CalibrationFixtures/`).
Anything less is a code-completion test, not a calibration. New
categories don't ship without their corpus.

**6b. Calibration sweeps land their reports in
`Tests/Calibration/runs/<ISO>/` and the result of record is
named.** v0.1.5's `2026-05-23T23-38-07Z/` was v3, the v0.1.5
result of record. Other sweeps (v1 rate-limited, v2 pre-rubric)
were preserved for diagnosis but explicitly excluded from the
result. Calibration is reproducible, inspectable, dated, and
attributed.

**6c. The gate is a number you committed to in advance.** v0.1.5
spec said 95% positives + 95% negatives per category. v0.1.5
hit 75% / 75% / 100% on positives. The trial gated off. Don't
move the goalposts post-hoc. If the gate was wrong, write a new
spec; don't lower the bar mid-sweep.

**6d. End-to-end verification on a real canary precedes "ship."**
v0.2.0 didn't ship "DeepSeek support works" because the tests
passed — it shipped because I literally drove the onboarding,
pasted Mohammed's real DeepSeek key, watched `validateKey ok`
land in the trace, and saw the state machine advance. From the
v0.2.0 CHANGELOG entry: *"Live-verified end-to-end against
DeepSeek's real API…"* If the canary didn't fire, the feature
didn't ship.

**6e. The autonomous-trial gate is a separate, harder gate.** An
intervention that's verified against fixtures still needs to fire
correctly against a real Claude Code session before it's trusted
to run unattended. The v0.1.5 trial was supposed to be that
canary; calibration didn't meet the gate, so it didn't run. **Do
not approve unattended interventions on fixture-only evidence.**

**6f. Fixture corrections that align test expectations with
reproducible model behavior do not require a sweep.** They're not
changes to calibration capability — they're alignments of
measurement to reality. Rubric and prompt changes still do.
Concretely: when a fixture's `expectedSeverity` was set wrong and
Haiku has been consistently returning the *correct* severity
across sweeps, updating the fixture to match what Haiku already
does is a measurement fix, not a behavior change. Ship it without
a new sweep. From the autonomous-20260524T080753Z trial:
`destr.pos.028.git-rm-rf-cached` had `expectedSeverity: .high`
but `--cached` doesn't touch worktree files; Haiku returned
MEDIUM in v2 and v3; the fix was to align the fixture. That
correction does NOT require a new sweep — the existing sweeps
already showed what the model does; we're just acknowledging it.
**Distinction**: if the proposal is "change the rubric/prompt
so Haiku returns X for this fixture," that's a behavior change
and §6a-d apply. If the proposal is "the fixture expected the
wrong thing; align it to what the model already does," that's
§6f and ships without a sweep.

---

## 7. Stop and ask, don't barrel forward

The default at any ambiguity is to surface, not improvise.
Improvising on safety code is the failure mode the harness exists
to prevent.

**7a. When a values question appears, use `AskUserQuestion`.**
Quick checklist:
- Is the choice mutually exclusive? → single-select.
- Are options independent? → multi-select.
- 2-4 options, recommended one first.
- Each option has a clear description with the trade-off named.
- No straw-man options ("never do this") unless one is actually
  on the table.

**7b. When an engineering question is contained, decide and
explain.** "What test framework to use" is not an `AskUserQuestion`
moment; pick the existing one and proceed. Use the CHANGELOG to
explain non-obvious engineering decisions — see v0.1.6.2's
"Why this works" note about Swift 5.10 capture semantics.

**7c. When the path forward depends on facts you don't have, get
the facts.** Don't guess. Read the trace log. Check
`gh run list`. Run `git diff main..HEAD`. The v0.1.6.1 fix
diagnosed the README log-rotation gap by reading TraceLog.swift
line 36 (`rotateBytes: Int = 10 * 1024 * 1024`); guessing
"probably 10 MB" would have been wrong half the time.

**7d. Hard stop on safety questions that the rubric doesn't
answer.** If a new pattern surfaces that's clearly destructive
but isn't in the rubric's Fire list, do NOT ad-hoc fire it from
code. File an issue with the pattern, the proposed Fire list
addition, and example fixtures. The rubric edit is the
intervention; the code change is the wrapper.

---

## 8. Belt + suspenders, especially on safety

Layered defenses matter. One layer can fail; two layers in
disagreement is much harder.

**8a. Redaction is non-optional by constructor.** `LLMClient`
refuses to initialize without a `Redactor`. Not "warns" — refuses.
Every request body passes through `redactor.redact(_:)` before
transmission. This is mechanical, not a runtime check.

**8b. Light-mode lock-in on onboarding is belt+suspenders against
dark mode.** v0.1.6.4 added BOTH `.preferredColorScheme(.light)`
on the OnboardingScene AND an explicit `BrandColor.paper.color`
background ZStack on the content area. Either would suffice; both
catch the case where a future SwiftUI build ignores the colorScheme
hint on a borderless-content-view window.

**8c. Recovery doc is written before the signal.** The router
writes the markdown handoff to disk BEFORE sending SIGSTOP/SIGTERM.
If the write fails, the banner falls back to inline copy — but the
attempt is always before the signal so a kill doesn't strand state.

**8d. The atomic-swap pattern is mandatory for /Applications
operations.** `cp build → /Applications/Supervisor.app.tmp →
rm /Applications/Supervisor.app → mv .tmp → /Applications/Supervisor.app`.
Never `mv` directly over a running process. Never `rm` before
the new bundle is staged. This is reflected in the actual
deployment steps and should be reflected in any future
deployment scripts.

**8e. Migrations are idempotent.** `migrateLegacyKeyIfPresent`
runs on every launch; no-ops after the first. Every state
transition that touches user data must be safe to run twice.

---

## 9. Cost transparency

The user pays the Anthropic bill. Every API call costs them money.
Cost is a first-class concern, not a footer.

**9a. Onboarding states the cost before the user pastes the key.**
The provider-specific intro copy in KeyEntryStep says "~$80/month"
for Anthropic, "~$5/month" for DeepSeek, etc. Update these numbers
when pricing changes. Don't hide the cost.

**9b. Every API call traces its byte count and token usage.**
Trace lines like `POST /v1/chat/completions provider=deepseek
model=deepseek-chat max_tokens=1 bytes=86` exist on purpose.
Future cost-cap enforcement (v0.1.2 cap; v0.2 expanded) reads from
the trace + the `daily_cost` table. Don't suppress these traces
to "tidy up" the log.

**9c. Cost surfaces in the UI.** The expanded panel (v0.1.7+)
shows current spend per session, per day, per category. Until
then, `SupervisorStatusBar → "Recent Flags…"` dumps cost-bearing
fields in the JSON so the user can audit.

**9d. The default cost cap is bracketed below typical usage, not
above.** From DESIGN §8.8: *"Default cost cap $5/day, hard
fail-soft."* Cap enforcement degrades to triage-only (no
escalation) rather than blocking; the user has agency to lift it
in Settings.

**9e. The autonomous-session budget envelope** (closes the gap the
autonomous-20260524T080753Z trial hit when a $0.04 verification
sweep was both clearly affordable and outside the "ask the user"
model):

- **Under $0.50.** Verification of an already-decided code change.
  No signoff needed. Journal the spend.
- **$0.50–$5.00.** Justify in `trial-notes.md` *before* spending.
  Still autonomous, no human signoff. Spend if the journaled
  reasoning holds up to a PRINCIPLES.md re-read. The journal
  entry should name (a) the work the spend unlocks, (b) why the
  smaller-tier spend isn't sufficient, (c) the regression-safety
  story (which sweep / fixture comparison this enables), (d) the
  fallback if the spend doesn't produce the expected signal.
- **Over $5.00.** Stop and file as a sized issue for next
  session. The user signs off on bigger spends. Include the same
  four bullets as the $0.50–$5.00 case, plus the calibration plan
  with the file paths the sweep will land in.

**All budget decisions log to `trial-notes.md` regardless of
tier.** "I checked and didn't spend" counts as a budget decision
and should be journaled — the absence of spend is signal about
what the trial concluded was unverifiable.

The tier cutoffs are calibrated to v0.1.5's $1.60 baseline for a
full 300-fixture sweep: under $0.50 covers targeted sweeps
(~22 fixtures), $0.50–$5.00 covers full regression sweeps (1×
to ~3× the baseline), over $5.00 covers exploratory or
multi-provider sweeps that warrant Mohammed's review.

---

## 10. Reproducibility and inspection

The user (and future-Claude-Code-sessions) must be able to
*see* what happened.

**10a. The trace log is the first thing to look at when something's
off.** From the README: *"Every state transition — onboarding, AX
grants, key validation, triage start/end, flag persistence,
notifier outcome, heartbeat health — emits a single line with a
timestamp and a tag."* Don't add features whose state transitions
are silent. If a state changed, it traces.

**10b. Calibration runs persist forever.**
`Tests/Calibration/runs/<ISO>/` is git-tracked. v3's
`2026-05-23T23-38-07Z/` will still be readable years from now.
This is on purpose. The trail of how the rubric was calibrated
is part of the rubric.

**10c. Mocks beat fakes beat real services for unit tests.**
`MockURLProtocol` (in `LLMProviderMockURLProtocol` etc.) lets us
test the full HTTP path without hitting a real API. Use it.
Live-API tests gate on `SUPERVISOR_LIVE_API=1 + ANTHROPIC_API_KEY`
and self-skip without them. CI runs the mocks; the human runs
the live tests when calibrating.

**10d. Hand-rendered samples beat "trust the code."** The v0.1.6
STATUS doc has the full text of a sample recovery doc inline.
The sample is hand-rendered using the writer's exact template —
it shows what the artifact looks like, not what the code claims.
When proposing an artifact-shape change, include a hand-rendered
sample.

---

## 11. Voice and tone

Direct. Specific. No marketing language. Specific signatures named
over abstract behavior. First-person when self-referring.

**11a. No "we're excited to" / "thrilled to announce" / "robust" /
"powerful" / "seamless".** These are filler. Cut them. The
README opens with *"Supervisor is a native macOS safety harness
for Claude Code sessions."* That's the whole pitch.

**11b. Specific signatures over abstract behavior.** Not "watches
for destructive commands" — *"`rm -rf` against a path outside the
session's cwd, `git push --force` or `git push -f`, `git push
--force-with-lease` targeting `main`/`master`/`production`,
`git reset --hard`, …"*. The rubric body is the model of the
voice.

**11c. First-person for self-references in user-facing docs.** From
v0.1.2's voice corrections in the CHANGELOG: *"third-person
self-references (\"Mohammed verifies\", \"Mohammed's machine\")
rewritten to first-person."* The README says "I" / "my" / "the
user." Maintainer attribution in CONTRIBUTING.md keeps its
name-in-parens form ("I (Mohammed Wasif, [@maximizeGPT])").

**11d. Honest tense in UI copy.** Pre-execution: "Claude Code is
*about to* push to main with --force. Pause?" Post-execution:
"Claude Code *just ran* `rm -rf /tmp/foo`. Stop further action?"
The framing matches the actual capability. From DESIGN §6.5:
*"Honest framing is future-tense for pending action, past-tense
for already-executed-but-stop-further-action."* Don't write
"Prevented a destructive action" when the action was post-write.

**11e. No emojis in code, comments, or docs unless explicitly
requested by Mohammed.** This is a hard rule. The brand voice is
restrained; emojis break it.

---

## 12. The hard stops

When any of these happen, the autonomous session must stop and
file an issue, not improvise:

1. **A real kill fires** (not just a notify or pause — an actual
   SIGTERM/SIGKILL sent to a Claude Code process). Stop, write
   trial-notes.md with the timestamp + recovery doc path, and
   end the session.
2. **75 minutes elapsed** without ship-readiness. Time to write
   what didn't ship.
3. **Hit a question this document doesn't answer.** Don't guess
   — file an issue, journal the question, end the session.
4. **CI red after a push.** Don't push more on top. Fix or
   revert; then proceed.
5. **Calibration regresses by >10% from the v0.1.5 baseline.**
   That's a "rubric change is wrong" signal, not a "iterate
   the rubric" signal.

---

## 13. What this document does not cover (yet)

Real situations the next sessions will hit that aren't here:

- **What to do when the user is asleep and a high-severity flag
  fires.** Right now: the banner posts, the hover goes red, the
  recovery doc lands. The session continues. No PagerDuty.
- **Multi-machine coordination.** Out of scope through v0.2.
- **Adapting the rubric to a new tool family** (e.g., Claude
  Code grows a `BrowserAutomation` tool). Treat as a new
  rubric category: corpus + sweep + ship.
- **Disagreement between providers** in v0.2.0. If DeepSeek and
  Anthropic give materially different verdicts on the same event
  window, we don't have a tie-breaker. Filed for a future
  multi-provider calibration sweep.

Add to this section when you hit a question PRINCIPLES.md doesn't
answer, before you end the session. The meta-post-mortem reading
of this file depends on it being accurate about its own gaps.

---

## The check

A future Claude Code session reading only this document and the
repo should:

- Reach for `AskUserQuestion` on values calls.
- Decide engineering calls and justify them in the CHANGELOG.
- Write asymmetry notes when reasoning fires.
- Test the artifact (banner, doc, prompt body), not just the code.
- Land a 300-fixture sweep before claiming a category works.
- Read the trace before guessing.
- File issues with shape, not vaguely.
- Surface what didn't ship alongside what did.

If you're doing those things, you're operating on the same
principles Mohammed has been operating on. If you're not, stop
and re-read.
