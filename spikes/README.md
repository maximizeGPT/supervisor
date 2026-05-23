# Phase 0 spikes

**What these are.** Small, throwaway-grade experiments run before any
production code in `Sources/`. The job of a spike is to answer one
risky assumption embedded in `DESIGN.md` with the fastest viable
test — usually a single-file Swift program, a build script, and a
findings note. If the assumption holds, the spike informs an
architectural decision; if it breaks, the design adjusts before
real code commits to the wrong shape. Both spikes here ran in
roughly 30 minutes apiece on a Mac mini M4 / macOS 26 / Swift 6.2.4.

**Why they're preserved.** They're a provenance record. The build
script's ad-hoc-signing guard, `SessionTail`'s commitment to a
single kqueue path with no polling fallback, the onboarding flow's
notification-permission handling — each is the way it is because a
spike either confirmed the assumption or surfaced a sharp edge that
forced an adjustment. Keeping the binaries plus the findings notes
together means anyone reading a "why does it do this?" line in
production code can follow the reasoning back to where the question
was actually answered, rather than guessing from the design doc
alone.

## The spikes

- **`kqueue_spike`** — *Does `DispatchSourceFileSystemObject` reliably
  fire on every append to an actively-written JSONL session log?*
  **✅ Yes.** Every append was caught within the 75-second window
  against a real Claude Code session. Outcome: `SessionTail` ships on
  kqueue only, no polling fallback wired. Findings note:
  [`kqueue-spike-README.md`](kqueue-spike-README.md). Source:
  `kqueue_spike.swift`.

- **`notify_spike`** — *Does `UNUserNotificationCenter` work for an
  unsigned, ad-hoc-built dev app — i.e. without an Apple Developer
  ID?* **⚠️ Works, with a sharp edge.** It works only when the bundle
  is `codesign --force --sign -`'d with a `CodeDirectory Identifier`
  that matches `CFBundleIdentifier` exactly. Outcome:
  `Scripts/sign-adhoc.sh` became a required pre-launch step on every
  dev build (not just release), and the build script asserts the
  Identifier match and fails loudly if not. Onboarding's notification
  step also handles the `denied` state with a deep link to System
  Settings. Findings note:
  [`notify-spike-README.md`](notify-spike-README.md). Source:
  `notify_spike.swift` + `build_notify_app.sh` +
  `entitlements.plist`.

## Re-running

```bash
# Spike 1 — watch one of your own session JSONL files for 75s.
cd spikes
swiftc kqueue_spike.swift -o kqueue_spike
./kqueue_spike ~/.claude/projects/-Users-USER/<session-id>.jsonl 75

# Spike 2 — build the notification bundle, run, inspect captured log.
cd spikes
./build_notify_app.sh
./NotifySpike.app/Contents/MacOS/NotifySpike
```

## What Phase A locked in because of these

- **kqueue spike:** `Sources/SupervisorCore/Observation/SessionTail.swift`
  uses `DispatchSourceFileSystemObject` directly with no polling
  fallback. The polling code path was never written.
- **notify spike:** `Scripts/sign-adhoc.sh` exists as a required
  pre-launch step on every dev build, with an assertion that the
  signed Identifier matches `CFBundleIdentifier`. `Scripts/build-app.sh`
  fails the build on mismatch. The onboarding flow's notification
  step renders a "Open System Settings" deep link when status is
  `denied`.
