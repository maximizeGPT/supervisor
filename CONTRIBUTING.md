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
they're missing. `swift test` runs roughly 1,350 tests in about five
minutes; a few dozen live suites (e.g. `LLMEvalTests`) are skipped
unless `SUPERVISOR_LIVE_API=1` plus an API key (`ANTHROPIC_API_KEY` or
`DEEPSEEK_API_KEY`) are exported — those hit the real provider APIs and
bill against your key.

For an end-to-end smoke test that builds, signs, and launches both
`.app` bundles with the brand icons baked in:

```bash
./Scripts/build-app.sh debug
open ./build/Supervisor.app
```

## Filing a useful bug report

Open an issue using the `[BUG]` template. The thing that makes a report
useful — and that I'll ask for if it's missing — is the trace log:

```bash
tail -50 ~/Library/Logs/Supervisor/supervisor.log
```

Paste those 50 lines into the issue, then describe what you were doing
when it happened. The trace log is append-only and tagged per subsystem
(`onboarding`, `app`, `flag`), which makes it easy to spot
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

## Cutting a release

Maintainer path. Supervisor develops in a private repo and publishes a
squashed export to this one, so the order below matters: the public tag
has to land on the export commit, not on the private commit it came
from.

**1. Merge the release PR** into `main` on the private repo. Note the
merge commit; every step below refers to it.

**2. Build the release bundle.**

```bash
Scripts/build-app.sh release
```

**3. Sign, notarize, staple.**

```bash
Scripts/make-dmg.sh
```

The script checks the notary credential before it signs anything, fails
unless Apple returns `Accepted`, and refuses to report success unless
both `xcrun stapler validate` and `spctl` pass on the finished dmg. The
0.4.0 release shipped an unstapled dmg because none of that was
enforced. If the stored profile is unavailable, pass the credentials
inline for one run:

```bash
SUPERVISOR_NOTARY_ARGS="--apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" \
  Scripts/make-dmg.sh
```

**4. Tag the private repo at the merge commit.**

```bash
git tag v0.4.0 <merge-commit>
git push origin v0.4.0
```

**5. Export to the public repo.** Dry run first. It stages the tree in a
temp dir, prints every file it excluded, and runs the secret scan over
the whole exported tree without touching anything.

```bash
Scripts/export-public.sh <merge-commit> v0.4.0
Scripts/export-public.sh <merge-commit> v0.4.0 --apply
```

**6. The public tag lands on the export tip.** `export-public.sh` tags
the commit it just created and verifies the tag resolved there before it
exits, and it takes no tag target from you. This is worth the fuss:
v0.3.2's public tag landed one commit short of its export, so anyone who
ran `git checkout v0.3.2` got the commit before the fix that release was
named for.

**7. Push.** The export script never pushes. It prints these:

```bash
git -C "$SUPERVISOR_PUBLIC_WORKTREE" push public HEAD:main
git -C "$SUPERVISOR_PUBLIC_WORKTREE" push --force public v0.4.0
git -C "$SUPERVISOR_PUBLIC_WORKTREE" ls-remote --tags public v0.4.0
```

The last line is the check that step 6 actually held on the remote.

**8. Cut the GitHub release** with the notarized dmg attached.

```bash
gh release create v0.4.0 dist/Supervisor.dmg -R maximizeGPT/supervisor \
  --latest --title "Supervisor v0.4.0" --notes-file <release-notes>
```

**9. Deploy the landing page.** It lives in its own checkout, not in this
repo. The `site/` directory that used to sit here was a stale waitlist
layout that nothing deployed from, and it was deleted so nobody would
publish from it by mistake.

**10. Deploy locally** and confirm the build users are downloading is the
one running on your own machine.

```bash
Scripts/deploy.sh v0.4.0
```

Its smoke test reads the app's own trace and exits non-zero when the
Keychain read threw (1) or Accessibility is missing (2).

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
