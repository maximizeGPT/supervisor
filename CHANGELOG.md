# Changelog

All notable changes to Supervisor are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] — 2026-05-23

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

### Added
- `spikes/README.md` rewritten to a what-spikes-are / why-preserved /
  bulleted-spike-list shape, with each spike's outcome surfaced
  on a single line and the supplementary "Re-running" and "What
  Phase A locked in" sections kept as appendices.

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

[Unreleased]: https://github.com/maximizeGPT/supervisor/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.2
[0.1.1]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.1
[0.1.0]: https://github.com/maximizeGPT/supervisor/releases/tag/v0.1.0
