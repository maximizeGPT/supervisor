# Changelog

All notable changes to Supervisor are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] — 2026-05-23 (Part A — router + locator; Part B in flight)

### Added
- **Pause / kill router lands.** `InterventionRouter` dispatches every
  triage decision by `flag.action`:
    - `.notify` → existing `Notifier.post` (banner only)
    - `.pause`  → `ProcessLocator` → `SignalSender(SIGSTOP)`
    - `.kill`   → `ProcessLocator` → `SignalSender(SIGTERM)`
    - `.inject` → routed to notify; the keystroke executor is queued
      in `spikes/cgevent-bypass-ax-spike-README.md` (research note from
      the v0.1.3 audit) and lands in a follow-up PR.
  Every failure path (locator returns nil, missing cwd on the decision,
  `kill(2)` throws EPERM / ESRCH / other) degrades to `Notifier.post`,
  never crashes. Each degradation emits a discriminating trace tag
  (`intervention.<op>.degraded reason=<reason>`) so postmortems can
  trace exactly why a recommended pause / kill didn't fire.
- `ProcessLocator` (Sources/SupervisorCore/Intervention/ProcessLocator.swift)
  resolves a target cwd → the unique matching Claude Code PID via
  `proc_listallpids` + `proc_pidpath` + `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
  No entitlements needed for same-user processes. Trace tags discriminate
  every outcome: `locator.found`, `locator.not_found`, `locator.ambiguous`,
  `locator.sysctl_failed`. Supervisor's own PID is filtered out of every
  candidate set — Supervisor holds Claude Code's JSONL files open and
  would otherwise self-match.
- `SignalSender` protocol + `DarwinSignalSender` (POSIX `kill(2)` wrapper)
  + `SignalError` with `isProcessGone` / `isPermissionDenied` predicates.
  The router talks to the sender through the protocol so tests can inject
  a capturing mock; production wires `DarwinSignalSender` directly.
- `Notifying` protocol on `Notifier` — same shape, lets `InterventionRouter`
  take a mockable notifier in tests (the real `Notifier.init` crashes the
  xctest harness because `UNUserNotificationCenter.current()` aborts on
  missing CFBundleIdentifier — same Spike 2 finding).
- `FakeClaudeCLI` (Sources/FakeClaudeCLI/main.swift) — Foundation-only
  test harness that writes realistic-shaped JSONL events on a configurable
  cadence, holds the fd open between writes (or `--no-fd-hold` to simulate
  the bad case), and records its PID to a sidecar file. `--multi-instance`
  self-spawns a sibling FakeClaudeCLI in `/tmp` so the locator's filter-by-cwd
  path can be exercised against multiple "Claude" processes. The harness
  is what unblocked PID-discovery verification — see the v0.1.2 Phase 1
  task notes for the blocker rationale.

### Changed
- `TriageDecision` gains a `cwd: String?` field — the router needs the
  session's cwd to ask the locator for a PID. The cwd was already
  computed in `TriageEngine.evaluate` (via `lastSessionCWD(in: window)`);
  this PR just plumbs it onto the decision so downstream consumers
  don't have to re-derive it.
- `main.swift`'s flag-handler now dispatches through the router instead
  of calling `Notifier.post` directly. The router internally handles
  every failure path; `handle(decision:)` collapses to a single
  `router.dispatch(decision:)` call inside the task block.

### Tests
- +5 `ProcessLocatorTests` against live FakeClaudeCLI subprocesses
  (happy path, filter-by-cwd, ambiguous, not-found, exec-name filter
  excludes non-matching processes).
- +10 `InterventionRouterTests` with mocked Notifier / Locator /
  SignalSender (notify, pause-success, kill-success, locator-nil
  degrades, EPERM degrades, ESRCH degrades, missing-cwd degrades,
  double-pause is a no-op, kill-after-pause sequence, inject routes
  to notify).
- Total: 148 tests pass (1 skipped — live API), up from 133 at v0.1.3.

### Carried — not yet in v0.1.4 (Part B + checkpoint)
- Rubric expansion: `edits_outside_worktree` and `prompt_injection_signature`
  categories. Calibration testing (5 positives × 5 negatives per category)
  blocks the Part B release entry. This Part A tag-cut is the clean
  revertable point before that work starts.

## [0.1.3] — 2026-05-23

### Added
- **Onboarding window is now branded.** The 480×360 onboarding window
  picks up the brand kit: a Paper-warm 80pt header band carrying the
  wordmark, a 56pt Paper footer with a 1pt Paper-warm top border, and
  Signal-green as the single accent across the three steps (primary
  button background; focus border is the system default since
  `SecureField` doesn't expose a custom-color focus ring on macOS 13).
  The previous Divider-separated layout with system-default everything
  is gone. Step views now read as: "Step X of 3" indicator (Mute,
  Inter 500 12pt, all-caps with 1pt tracking) → step title (Ink, Inter
  600 18pt) → body copy (Ink-deep, Inter 400 13pt with 1.5× line-height
  via `.lineSpacing(6)`).
- `BrandColor` enum in `Sources/SupervisorUI/Branding/BrandColor.swift`
  exposing the six palette roles from `branding/README.md` (`.ink`,
  `.paper`, `.inkDeep`, `.paperWarm`, `.signal`, `.mute`) as SwiftUI
  `Color` values. Every brand color in onboarding goes through this
  enum — call sites never spell out hex. Future brand surfaces (the
  expanded panel in v0.1.7+) reuse it.
- `BrandFont` enum exposing the type-system roles (`.indicator`,
  `.title`, `.body`, `.button`, `.note`) as SwiftUI `Font` values.
  Inter / JetBrains Mono are not bundled as runtime resources in this
  PR — no `.ttf` lives under `/branding` — so every BrandFont resolves
  to a `.system(size:weight:)` fallback today. If a future PR bundles
  Inter, the switch happens entirely in `BrandFont.swift` and call
  sites stay the same.
- `BrandPrimaryButton` SwiftUI view (Signal background, Paper text,
  Inter 500 13pt, 5pt corner radius). Reads `\.isEnabled` from the
  environment and dims the Signal background to 40% opacity when
  disabled — `.buttonStyle(.plain)` defeats macOS's automatic disabled
  rendering, so the styling does it explicitly.
- `OnboardingWordmark.svg` bundled under `Sources/SupervisorUI/Resources/`
  (copied from `branding/supervisor-wordmark.svg`, the `#lockup-horizontal`
  lockup — Inter Medium outlined to paths, zero runtime font dependency).
  Loaded via `Bundle.module.image(forResource:)` with a text-wordmark
  fallback so the header never goes empty if asset resolution fails.

### Changed
- **Onboarding window chrome.** The system title bar is hidden via
  `[.titled, .closable, .fullSizeContentView]` + `titleVisibility = .hidden`
  + `titlebarAppearsTransparent = true` (the path chosen over literally
  dropping `.titled` — that would have removed the close button and made
  the window un-draggable; over `.titled` with an empty title string —
  that would have left a visible empty gray strip above the header).
  Traffic-light controls now float over the wordmark band's top-left;
  drag works through the (invisible) title bar region.
- **Step views shed their buttons.** The primary action moved to the
  footer for every step. `KeyEntryStep`'s `key` text lifts up to
  `OnboardingScene` as a `Binding<String>` so the footer button can
  gate its disabled state on emptiness without coupling draft state
  into the view model. `AXCheckStep`'s "Re-check now" button is dropped
  entirely — `vm.tick()` already polls every 1.5s and advances the
  moment AX is granted, the button never had a use case the polling
  didn't already cover. `NotifCheckStep`'s "Skip" button is dropped
  per the spec ("Skip only on AX"); the user in the `.notDetermined`
  substate now must click "Request permission" before they can advance,
  but they can still deny in the macOS prompt and proceed via the
  `.denied` substate's "Continue anyway" footer button.
- `CompleteStep` (post-onboarding "All set" screen) checkmark goes from
  system `.green` to `BrandColor.signal` for consistency with the rest
  of the screen, even though the spec's three explicit Signal uses
  don't enumerate this one. The redundant inline "All set." text is
  removed since `OnboardingScene`'s `stepTitle` already surfaces it
  for the `.complete` state.
- `Package.swift`: SupervisorUI target gains
  `resources: [.process("Resources")]` so `Bundle.module` resolves.
- fix: NotifCheckStep "Notifications enabled." inherited
  `foregroundStyle` across icon and text, putting text in Signal
  green and violating spec rule 6 ("no green text"). Split into
  HStack with independent icon (Signal) and text (Mute) styling.

### Deliberately skipped
- `supervisor-appicon-1024.png` was on the asset-copy list but has no
  use site in this PR — the `CompleteStep` checkmark remains an SF
  Symbol per the spec, and no other surface needs the 1024 icon yet.
  Honors the "Keep the dir minimal" guidance. Will land alongside the
  expanded panel work in v0.1.7+ that needs a larger brand presence.
- Error red (`KeyEntryStep`'s inline validation message) and warning
  orange (`NotifCheckStep`'s `.denied` warning) stay as system semantic
  colors. The palette has no error/warning roles, and macOS users read
  system semantic colors faster than any custom red/amber would.
- Inter / JetBrains Mono font bundling. SF Pro fallback is the v0.1.x
  reality; revisit when a brand-design pass decides it's worth the
  resource bytes.

## [0.1.2] — 2026-05-23

### Added
- **Haiku triage now recommends the action and explains it in plain
  English.** The `record_triage` schema gained three required fields —
  `recommended_action` (one of `notify` / `pause` / `kill`),
  `reasoning_plain` (2–4 sentences fit for a notification banner),
  `reasoning_technical` (one dense paragraph for the trace log) — plus
  an optional `asymmetry_note` for cases where the cost of being wrong
  is materially asymmetric. The system prompt now teaches Haiku to pick
  the lightest action that fits and to write its banner copy with the
  right tense based on whether the tool has already executed.
- Banner composition is now a tiny composer: `Notifier.bannerPrefix`
  (a fixed `"Supervisor: "` so tests and callers cannot drift) plus
  `reasoning_plain` verbatim. The pre/post tense branching that used
  to live in `Notifier.body(for:)` moved into the prompt — Haiku knows
  from the "Has the command already executed?" section of the user
  message which tense to write in.
- Malformed-verdict fallback. If Haiku's tool call is missing a
  required field, the engine still fires the flag but with
  `recommendedAction = .notify` and `reasoningPlain =
  TriagePrompt.malformedVerdictBannerText` (a fixed
  `"Supervisor flagged a potentially destructive action. Open the
  panel for details."`, deliberately not derived from any LLM output —
  the whole point of the split is that the technical paragraph is
  unfit for a banner). A `triage.schema.malformed` trace line carries
  the raw verdict for debugging.
- Inbound redactor pass. `TriageEngine` now takes a `Redactor`
  dependency (defaults to `DefaultRedactor()`) and every reasoning
  string from Haiku — plain, technical, asymmetry — is redacted
  before it lands on the in-memory `TriageCandidate`, the database,
  the banner, or the trace log. Defense in depth — Haiku shouldn't
  see real secrets thanks to the outbound redactor, but if it ever
  invents a secret-shaped string, we strip it before it reaches a
  user surface.
- `spikes/README.md` rewritten to a what-spikes-are / why-preserved /
  bulleted-spike-list shape, with each spike's outcome surfaced
  on a single line and the supplementary "Re-running" and "What
  Phase A locked in" sections kept as appendices.

### Changed
- Database schema v2 migration: `flags.reasoning` renamed to
  `flags.reasoning_technical`; added `flags.reasoning_plain` (NOT
  NULL, defaulted to empty) and `flags.asymmetry_note` (nullable).
  Old rows backfill `reasoning_plain` from the existing
  `reasoning_technical` text in the same migration pass — dense but
  non-empty, so historical flags still surface a banner if they ever
  re-render.
- `StoredFlag` constructor renamed `reasoning:` → `reasoningPlain:`
  + `reasoningTechnical:` (+ optional `asymmetryNote:`).
  `TriageCandidate` follows the same shape and renames `reasoning`
  accordingly.
- `flag.action` now carries Haiku's `recommended_action` instead of
  the v0.1.0 hardcoded `.notify`. The pause and kill *executors* are
  still deferred to a follow-up — the router that physically issues
  SIGSTOP/SIGTERM ships next, after a verified process-locator harness
  lands (see task notes). Until then, every flag — including
  pause/kill recommendations — surfaces as a notify banner; the
  difference shows up in `reasoning_plain` and on the persisted
  `flag.action` column for later cost-view / panel reads.
- Trace line for a fired flag now carries the recommended action and
  both reasonings (truncated): `FLAG session=... severity=...
  action=... plain="..." tech="..."`. A separate `FLAG.asymmetry`
  line surfaces the asymmetry note when present.

### Fixed
- README install snippet now points at `github.com/maximizeGPT/supervisor.git`
  (was `<owner>/supervisor.git` placeholder).
- README Architecture section no longer attributes the two-stage triage
  pattern to a specific internal eval harness; rephrased as "modeled on
  the cheap-model-triage / strong-model-escalation pattern common in
  production eval pipelines."
- Voice corrections across `README.md`, `DESIGN.md`, code comments, and
  test files: third-person self-references ("Mohammed verifies",
  "Mohammed's machine", "Mohammed-scale") rewritten to first-person
  ("I verify", "my machine", "my workload") or user-flow voice
  ("the user grants permissions") depending on context. Maintainer
  attribution in `CONTRIBUTING.md` keeps its name-in-parens form
  ("I (Mohammed Wasif, [@maximizeGPT])"), which is the standard
  open-source pattern.

## [0.1.1] — *(retroactive)*

### Added
- Polish-pass infrastructure files (CONTRIBUTING, SECURITY,
  CODE_OF_CONDUCT, ISSUE/PR templates), GitHub Actions CI workflow,
  README badges row, architecture diagram in `docs/architecture.svg`.
  No code changes — scaffolding only. Tagged v0.1.1 directly without
  a backfilled changelog entry; recorded here for completeness.

## [0.1.0] — 2026-05-22

First public ship — minimum vertical that proves the observation +
triage + flag pipeline against real Claude Code sessions, end to end.

### Added
- JSONL tailing via `kqueue` (`DispatchSourceFileSystemObject`) with
  per-session byte-offset checkpoints in SQLite so a restart resumes
  exactly where it left off.
- Two-stage triage pipeline: Claude Haiku 4.5 against a small structured
  rubric (`destructive_action_pending` covers `rm -rf`/`Trash`/`git
  reset --hard` against non-temp paths).
- Forced `record_triage` tool call returns severity + category + evidence
  UUIDs + free-text reasoning. Verified against real Haiku in checkpoint
  C smoke.
- `Redactor.swift` covers nine pattern families (Anthropic keys, GitHub
  tokens in three formats, AWS access-key + secret pairs, JWTs, URLs
  with embedded credentials, shell-export lines). The Anthropic client
  refuses to send a request without a redactor wired in — fail-closed.
- macOS banner notifications via `UNUserNotificationCenter` with §6.5
  honest pre/post-action copy.
- Two-process companion architecture: `SupervisorHeartbeat` writes a
  heartbeat file every 5s; `SupervisorStatusBar` reads it every 2s and
  reports green/amber/red based on freshness.
- Three signed `.app` bundles (`Supervisor.app`,
  `SupervisorHeartbeat.app`, `SupervisorStatusBar.app`) via
  `Scripts/build-app.sh` with the V1 brand icon baked into each via
  `Scripts/make-icns.sh`.
- Three-step onboarding window: API key entry with live `validateKey`
  call, AX permission walkthrough (skippable in v0.1.0), notification
  permission prompt.
- Hover window in the top-right corner of the active screen — 240×40,
  green dot when watching, amber/red on flag, badge for flag count.
- 130 unit tests across `SupervisorCore` (1 skipped — live API).

### Known limitations
- **Post-write timing.** Supervisor catches the *next* destructive action,
  not the one in flight. For fast tools that finish before triage
  returns, the flag arrives after the action has already executed. v0.2's
  hook channel closes this gap.
- **Main-app SIGTERM orphan.** Main-app death is detected via a
  30-second heartbeat freshness window. SIGTERM (vs. clean Quit) orphans
  the heartbeat child; detection fails until v0.1.1's mach-port
  liveness check.
- **Unsigned MVP.** No Apple Developer ID, no notarization. Gatekeeper
  warns on first launch; right-click → Open through the "unidentified
  developer" warning.

[Unreleased]: https://github.com/maximizeGPT/supervisor/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.3
[0.1.2]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.2
[0.1.1]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.1
[0.1.0]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.0
