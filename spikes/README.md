# Phase 0 spikes

Pre-Phase-A probes that confirmed (or corrected) two macOS assumptions
embedded in `DESIGN.md`. Both ran in ~30 minutes on a Mac mini M4 running
macOS 26.0 (Darwin 25.3.0), Swift 6.2.4.

The point of these spikes is not the binaries — those rebuild from source
in seconds — but the **findings notes next to each**, so the design
decisions they triggered are traceable. If you read a weird line in a build
script or an onboarding flow and wonder "why does it do this," the answer
should be one click away.

| Spike | File | Question | Verdict |
|---|---|---|---|
| 1 | `kqueue_spike.swift` + [`kqueue-spike-README.md`](kqueue-spike-README.md) | Does `DispatchSourceFileSystemObject` reliably fire on every append to an actively-written JSONL file? | ✅ Works. No polling fallback needed. |
| 2 | `notify_spike.swift` + [`notify-spike-README.md`](notify-spike-README.md) | Does `UNUserNotificationCenter` work for an unsigned, ad-hoc-built dev app? | ⚠️ Works with caveats. Requires explicit `codesign --force --sign -` step with Identifier matching `CFBundleIdentifier`. Onboarding scope extended; build script gained a guard. |

## Re-running the spikes

```bash
# Spike 1: watch one of your own session JSONL files for 75s
cd spikes
swiftc kqueue_spike.swift -o kqueue_spike
./kqueue_spike ~/.claude/projects/-Users-USER/<session-id>.jsonl 75

# Spike 2: build the notification bundle, run, inspect log
cd spikes
./build_notify_app.sh
./NotifySpike.app/Contents/MacOS/NotifySpike   # captures findings to stdout
```

## What Phase A changed because of these

- **Spike 1:** `SessionTail` is implemented on `DispatchSourceFileSystemObject` only. No polling tail.
- **Spike 2:** `Scripts/sign-adhoc.sh` is part of every dev build, not just release. The build script asserts `codesign -dv | grep "Identifier="` matches `CFBundleIdentifier` and fails loudly if not. Onboarding's notification step handles the `denied` state with a deep link to System Settings → Notifications.
