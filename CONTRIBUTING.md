# Contributing to Supervisor

Thanks for considering a contribution. This file covers the practical
shape of contributing — setup, tests, reporting, code style, and how
PRs land. The README's `## Installation` covers the user install path;
this file is for people changing code.

## Setting up locally

Clone, build, run the test suite:

```bash
git clone https://github.com/maximizeGPT/supervisor.git
cd supervisor
swift build
swift test
```

The first `swift build` triggers Xcode Command Line Tools install if
they're missing. `swift test` runs 130 tests; one (`testRealHaikuLiveCall`)
is skipped unless `ANTHROPIC_API_KEY` is exported — that one hits the
real Anthropic API and bills against your key.

For an end-to-end smoke test that builds, signs, and launches all three
`.app` bundles with the brand icons baked in:

```bash
./Scripts/build-app.sh debug
open ./build/Supervisor.app
open ./build/SupervisorStatusBar.app
```

## Filing a useful bug report

Open an issue using the `[BUG]` template. The thing that makes a report
useful — and that I'll ask for if it's missing — is the trace log:

```bash
tail -50 ~/Library/Logs/Supervisor/supervisor.log
```

Paste those 50 lines into the issue, then describe what you were doing
when it happened. The trace log is append-only and tagged per subsystem
(`onboarding`, `app`, `flag`, `statusbar`), which makes it easy to spot
where the surprise originated. Trim or redact any line that contains
something you don't want public — the trace log is local-only and isn't
filtered for sensitive content.

If the bug involves an Anthropic API call going wrong, include the
status code from the trace line (e.g. `requestError(429, ...)`) and
whether your key was rate-limited at the time.

## Code style

Swift code follows the shape of what's already there — small `struct`
types, narrow protocol surfaces, intent verbs on view-model methods
(`submitKey`, `recheckAX`, never `setState`). Multi-line block comments
at the top of each file explain *why* the file exists, not what it does.
The trace-log lines and the design doc together carry most of the
context — when adding a new subsystem, add a trace tag and a brief
paragraph in `DESIGN.md` for the next person.

There's no formatter enforced in CI yet (swift-format pending — see
issues). Match surrounding indentation (4 spaces) and column width
(~95 cols soft, 110 hard).

## Pull request flow

I (Mohammed Wasif, [@maximizeGPT](https://github.com/maximizeGPT)) am
the sole maintainer right now. Expect ~48-hour response time on PRs.
For anything that changes a public API, a permission requirement, the
intervention surface, or the rubric schema, **open an issue first** so
the design discussion happens before the code review. PRs against a
solid issue land in days; PRs that surface design questions in the diff
take weeks because the conversation happens twice.

For everything else — bug fixes, test additions, doc improvements,
small refactors — just open the PR. Include a one-line note in
`CHANGELOG.md` under the `[Unreleased]` section if the change is
user-facing. Tests are required for any code path that handles user
input, runs against the API, or persists to storage.
