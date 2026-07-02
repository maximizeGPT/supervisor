# Release checklist

How to cut a reproducible Supervisor release from a tag. Every step is a
command you run on a Mac with the Swift toolchain and the Developer ID
signing identity set up (see `Scripts/notarize.sh` for the one-time
signing prereqs). The goal is that two people building the same tag get
byte-identical dependencies and a bundle that reports its own version —
neither was true before v0.3.0.

Work top to bottom. Don't skip the calibration sweep: it is the trust
contract, and the ratchet only means something if it actually ran.

## 0. Pick the version

Decide `X.Y.Z` (semantic versioning). The rest of this doc uses
`0.3.0` as the worked example — substitute your number.

## 1. Land the changelog

- [ ] Move `CHANGELOG.md`'s `## [Unreleased]` section to `## [0.3.0] -
      YYYY-MM-DD` with today's date. Leave a fresh empty `## [Unreleased]`
      above it for the next cycle.
- [ ] Read the new section as a stranger: every claim must be something
      the shipped code actually does (per `docs/V0.3.0-PLAN.md`: "no claim
      in README/INSTALL that the code doesn't keep").

## 2. Pin dependencies (reproducible builds)

`Package.resolved` is committed as of v0.3.0 (it used to be gitignored, so
GRDB/KeychainAccess floated and two builds of one tag could differ).
Regenerate and commit it so the tag pins exact revisions:

```bash
swift package resolve
git add Package.resolved
git status Package.resolved   # confirm it's staged, not ignored
```

- [ ] `Package.resolved` regenerated and committed.
- [ ] `git check-ignore Package.resolved` prints nothing (it must NOT be
      ignored).

## 3. Commit and tag

- [ ] Commit the changelog + `Package.resolved` on `main` (or the release
      branch) and push. Wait for CI (`ci` workflow) to go green.
- [ ] Tag the release commit and push the tag:

```bash
git tag v0.3.0
git push origin v0.3.0
```

The tag is what `Scripts/build-app.sh` reads via `git describe --tags`, so
tag BEFORE building — an untagged build falls back to the `VERSION_FALLBACK`
constant in the script.

## 4. Build the version-stamped bundles

```bash
Scripts/build-app.sh release
```

- [ ] Output reads `[build-app] version: 0.3.0 (build <N>; describe: v0.3.0)`
      — NOT `0.1.0`. `build-app.sh` derives `CFBundleShortVersionString`
      from `git describe` and `CFBundleVersion` from the commit count.
- [ ] Confirm the installed bundle reports the version:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    build/Supervisor.app/Contents/Info.plist   # -> 0.3.0
```

## 5. Run the calibration sweep and confirm the ratchet gates pass

The nightly `calibration` workflow runs this automatically, but a release
should confirm it against the tagged code with a real key. The sweep is
live-gated, so it needs both env vars:

```bash
SUPERVISOR_LIVE_API=1 ANTHROPIC_API_KEY=sk-... \
    swift test --filter RubricCalibrationTests/testCalibrateFullCorpus
SUPERVISOR_LIVE_API=1 ANTHROPIC_API_KEY=sk-... \
    swift test --filter RubricCalibrationTests/testCalibrateQuestionFixtures
```

- [ ] Both sweeps pass — the per-category ratchet floors in
      `RubricCalibrationTests.swift` (`ratchetThresholds`) held. A failure
      here means the rubric regressed below its floor; do NOT ship, and do
      NOT lower the floor to make it pass (see the ratchet-discipline
      comment in that file).
- [ ] Reports written under `Tests/Calibration/runs/<timestamp>/`; skim
      `summary.md` for the per-category pass rates. If the numbers rose,
      consider RAISING the floors in a follow-up commit — that is how the
      95/95 gap closes.

## 6. Notarize and package both DMGs

The DMG is built, signed, notarized and stapled by `Scripts/notarize.sh`,
which names the DMG via the `DMG_NAME` env var. Produce a versioned DMG,
then keep a stable `Supervisor.dmg` copy — the README's install link points
at `releases/latest/download/Supervisor.dmg`, so that exact name must exist:

```bash
DMG_NAME="Supervisor-0.3.0" Scripts/notarize.sh
cp dist/Supervisor-0.3.0.dmg dist/Supervisor.dmg
```

- [ ] `dist/Supervisor-0.3.0.dmg` produced, notarized, and stapled
      (`xcrun stapler validate` prints "The validate action worked!").
- [ ] `dist/Supervisor.dmg` copy exists (the stable download URL).
- [ ] Both DMGs open with no Gatekeeper warning on a clean Mac and contain
      `Supervisor.app` + `SupervisorStatusBar.app`.

## 7. Create the GitHub release

- [ ] Draft a release on tag `v0.3.0`; title `Supervisor 0.3.0`.
- [ ] Paste the `CHANGELOG.md` `[0.3.0]` section as the release notes.
- [ ] Attach BOTH `dist/Supervisor-0.3.0.dmg` and `dist/Supervisor.dmg`.
- [ ] Mark it "latest" so `releases/latest/download/Supervisor.dmg`
      resolves to this build.
- [ ] Publish, then download `Supervisor.dmg` from the release page on a
      different Mac and confirm it launches (final Gatekeeper check on a
      real download, not the local build).

## 8. Post-release

- [ ] `CHANGELOG.md` has a fresh empty `## [Unreleased]` for the next cycle.
- [ ] The nightly `calibration` workflow is green against the released
      code (or manually dispatch it once to confirm).
